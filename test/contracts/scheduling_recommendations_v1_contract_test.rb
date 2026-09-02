# frozen_string_literal: true

require 'test_helper'
require 'bigdecimal'
require 'date'
require 'json'
require 'pathname'
require 'set'
require 'time'
require 'tmpdir'
require 'uri'
require 'tzinfo'

# json_schemer 2.5.0 is installed in the local Ruby runtime but intentionally
# is not added to the application bundle for this contract-only task. Load its
# already-installed runtime dependencies without changing Gemfile.lock.
begin
  require 'json_schemer'
rescue LoadError
  %w[hana regexp_parser simpleidn json_schemer].each do |gem_name|
    library = Dir[File.join(Gem.default_dir, 'gems', "#{gem_name}-*", 'lib')].max
    $LOAD_PATH.unshift(library) if library
  end
  require 'json_schemer'
end

# This deliberately small validator is test-only. It implements exactly the
# Draft 2020-12 keywords used by the scheduling recommendation v1 contracts and
# rejects every other assertion keyword. That makes an accidentally unsupported
# schema change fail closed instead of silently weakening the contract tests.
class SchedulingRecommendationsV1SubsetValidator
  class ContractValidationError < StandardError
    attr_reader :code, :path, :document, :causes

    def initialize(message, code:, path: nil, document: nil, causes: [])
      super(message)
      @code = code.to_s
      @path = path
      @document = document&.to_s
      @causes = causes.freeze
    end

    def flattened
      [self] + causes.flat_map(&:flattened)
    end
  end

  Resource = Struct.new(:uri, :document, :schema, keyword_init: true)

  DRAFT_2020_12 = 'https://json-schema.org/draft/2020-12/schema'
  ANNOTATION_KEYWORDS = Set.new(%w[$schema $id title description examples default]).freeze
  ASSERTION_KEYWORDS = Set.new(
    %w[
      $ref $defs type const enum required properties additionalProperties
      items minItems maxItems uniqueItems minLength maxLength pattern format
      minimum maximum oneOf
    ]
  ).freeze
  ALLOWED_KEYWORDS = (ANNOTATION_KEYWORDS | ASSERTION_KEYWORDS).freeze
  INSTANCE_TYPES = Set.new(%w[object array string number integer boolean null]).freeze

  attr_reader :schema_root

  def initialize(schema_root, schema_names: nil)
    @schema_root = Pathname.new(schema_root).expand_path.cleanpath
    @schema_names = schema_names&.map(&:to_s)&.freeze
  end

  def audit!(schema_name)
    with_fresh_session do
      document = schema_path(schema_name)
      audit_document!(document)
      true
    end
  end

  def valid?(schema_name, instance)
    validate!(schema_name, instance)
    true
  rescue ContractValidationError
    false
  end

  def validate!(schema_name, instance)
    with_fresh_session do
      document = schema_path(schema_name)
      audit_document!(document)
      ensure_utf8_tree!(instance, '$', document: document, instance: true)
      schema = document_for(document)
      validate_schema!(instance, schema, document, '$', Set.new, active_base_for(schema, document, nil))
      true
    end
  end

  def valid_ref?(schema_name, ref, instance)
    validate_ref!(schema_name, ref, instance)
    true
  rescue ContractValidationError
    false
  end

  def validate_ref!(schema_name, ref, instance)
    with_fresh_session do
      document = schema_path(schema_name)
      audit_document!(document)
      source = document_for(document)
      source_base = active_base_for(source, document, nil)
      target_document, target_schema, target_base, = resolve_ref(ref, document, source_base)
      ensure_utf8_tree!(instance, '$', document: target_document, instance: true)
      validate_schema!(instance, target_schema, target_document, '$', Set.new, target_base)
      true
    end
  end

  private

  def with_fresh_session
    @documents = {}
    @documents_by_name = {}
    @resource_registry = {}
    @node_bases = {}
    @resolution_cache = {}
    @audit_state = {}
    @active_audit_refs = Set.new
    @schema_root_real = schema_root.realpath
    build_registry!
    yield
  ensure
    @documents = nil
    @documents_by_name = nil
    @resource_registry = nil
    @node_bases = nil
    @resolution_cache = nil
    @audit_state = nil
    @active_audit_refs = nil
    @schema_root_real = nil
  end

  def build_registry!
    names = @schema_names || Dir.children(schema_root).grep(/\.json\z/).sort
    unless names.uniq == names
      schema_failure!(schema_root, 'schema registry contains duplicate file names', code: :duplicate_schema_file)
    end

    names.each do |name|
      path = safe_existing_path(name)
      @documents_by_name[name] = path
      @documents[path.to_s] = parse_schema_document(path)
    end

    @documents_by_name.each_value do |path|
      schema = document_for(path)
      unless schema.key?('$id')
        schema_failure!(path, 'schema document root must declare $id', code: :missing_id)
      end
      register_schema_resources!(schema, path, nil, '$')
      deep_freeze(schema)
    end
  end

  def safe_existing_path(name)
    candidate = schema_root.join(name.to_s).expand_path.cleanpath
    ensure_inside_schema_root!(candidate)
    real = candidate.realpath
    ensure_inside_schema_root!(real, realpath: true)
    real
  rescue Errno::ENOENT
    schema_failure!(candidate || schema_root, 'registered schema file does not exist', code: :missing_document)
  end

  def schema_path(schema_name)
    @documents_by_name.fetch(schema_name.to_s) do
      schema_failure!(schema_root.join(schema_name.to_s), 'schema is not in the local registry', code: :unregistered_document)
    end
  end

  def ensure_inside_schema_root!(candidate, realpath: false)
    root = (realpath ? @schema_root_real : schema_root).to_s
    path = candidate.to_s
    return if path == root || path.start_with?(root + File::SEPARATOR)

    schema_failure!(candidate, 'path escapes the scheduling contract directory', code: :path_traversal)
  end

  def parse_schema_document(path)
    bytes = File.binread(path)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    unless text.valid_encoding?
      schema_failure!(path, 'schema bytes are not valid UTF-8', code: :invalid_utf8)
    end

    parsed = JSON.parse(text, decimal_class: BigDecimal)
    unless parsed.is_a?(Hash)
      schema_failure!(path, 'schema document root must be an object', code: :invalid_schema_root)
    end
    ensure_utf8_tree!(parsed, '$', document: path, instance: false)
    parsed
  rescue JSON::ParserError => error
    schema_failure!(path, "schema is not JSON: #{error.message}", code: :invalid_json)
  end

  def document_for(path)
    @documents.fetch(Pathname.new(path).realpath.to_s) do
      schema_failure!(path, 'document is not in the local registry', code: :unregistered_document)
    end
  end

  def register_schema_resources!(schema, document, inherited_base, location)
    return unless schema.is_a?(Hash)

    base = inherited_base
    if schema.key?('$id')
      base = canonical_absolute_id(schema.fetch('$id'), document, location)
      if @resource_registry.key?(base)
        previous = @resource_registry.fetch(base)
        schema_failure!(
          document,
          "duplicate $id #{base.inspect}; already registered by #{previous.document}",
          code: :duplicate_id,
          path: "#{location}/$id"
        )
      end
      @resource_registry[base] = Resource.new(uri: base, document: document, schema: schema)
    end
    unless base
      schema_failure!(document, "#{location} has no active absolute $id base", code: :missing_id, path: location)
    end
    @node_bases[[document.to_s, schema.object_id]] = base

    schema_children(schema).each_with_index do |child, index|
      register_schema_resources!(child, document, base, "#{location}/children/#{index}")
    end
  end

  def schema_children(schema)
    children = []
    children.concat(schema.fetch('$defs', {}).values) if schema['$defs'].is_a?(Hash)
    children.concat(schema.fetch('properties', {}).values) if schema['properties'].is_a?(Hash)
    children.concat(schema.fetch('oneOf', [])) if schema['oneOf'].is_a?(Array)
    children << schema['items'] if schema['items'].is_a?(Hash)
    children << schema['additionalProperties'] if schema['additionalProperties'].is_a?(Hash)
    children
  end

  def canonical_absolute_id(value, document, location)
    unless value.is_a?(String) && !value.empty?
      schema_failure!(document, "#{location}/$id must be a non-empty string", code: :invalid_id, path: "#{location}/$id")
    end
    uri = URI.parse(value)
    unless uri.absolute?
      schema_failure!(document, "#{location}/$id must be an absolute URI", code: :relative_id, path: "#{location}/$id")
    end
    if uri.fragment && !uri.fragment.empty?
      schema_failure!(document, "#{location}/$id must not have a non-empty fragment", code: :fragmented_id, path: "#{location}/$id")
    end
    uri.fragment = nil
    uri.normalize.to_s
  rescue URI::InvalidURIError => error
    schema_failure!(document, "#{location}/$id is not a valid URI: #{error.message}", code: :invalid_id, path: "#{location}/$id")
  end

  def active_base_for(schema, document, inherited_base)
    @node_bases.fetch([document.to_s, schema.object_id], inherited_base)
  end

  def audit_document!(path)
    clean_path = Pathname.new(path).expand_path.cleanpath
    state = @audit_state[clean_path.to_s]
    return if state == :complete || state == :active

    @audit_state[clean_path.to_s] = :active
    schema = document_for(clean_path)
    audit_schema!(schema, clean_path, '$', active_base_for(schema, clean_path, nil))
    @audit_state[clean_path.to_s] = :complete
  rescue StandardError
    @audit_state.delete(clean_path.to_s)
    raise
  end

  def audit_schema!(schema, document, location, inherited_base)
    unless schema.is_a?(Hash)
      schema_failure!(document, "#{location} must be a schema object", code: :invalid_schema, path: location)
    end

    unknown = schema.keys.reject { |keyword| ALLOWED_KEYWORDS.include?(keyword) }
    unless unknown.empty?
      schema_failure!(document, "#{location} uses unsupported keyword(s): #{unknown.sort.join(', ')}", code: :unknown_keyword, path: location)
    end

    active_base = active_base_for(schema, document, inherited_base)

    audit_annotations!(schema, document, location)
    audit_type!(schema['type'], document, location) if schema.key?('type')
    audit_ref!(schema['$ref'], document, location, active_base) if schema.key?('$ref')
    audit_defs!(schema['$defs'], document, location, active_base) if schema.key?('$defs')
    audit_required!(schema['required'], document, location) if schema.key?('required')
    audit_properties!(schema['properties'], document, location, active_base) if schema.key?('properties')
    audit_additional_properties!(schema['additionalProperties'], document, location, active_base) if schema.key?('additionalProperties')
    audit_schema!(schema['items'], document, "#{location}/items", active_base) if schema.key?('items')
    audit_non_negative_integer!(schema, 'minItems', document, location)
    audit_non_negative_integer!(schema, 'maxItems', document, location)
    audit_boolean!(schema, 'uniqueItems', document, location)
    audit_non_negative_integer!(schema, 'minLength', document, location)
    audit_non_negative_integer!(schema, 'maxLength', document, location)
    audit_pattern!(schema['pattern'], document, location) if schema.key?('pattern')
    audit_format!(schema['format'], document, location) if schema.key?('format')
    audit_number!(schema, 'minimum', document, location)
    audit_number!(schema, 'maximum', document, location)
    audit_enum!(schema['enum'], document, location) if schema.key?('enum')
    audit_one_of!(schema['oneOf'], document, location, active_base) if schema.key?('oneOf')
    audit_bounds!(schema, document, location)
  end

  def audit_annotations!(schema, document, location)
    %w[$schema $id title description].each do |keyword|
      next unless schema.key?(keyword)
      next if schema[keyword].is_a?(String)

      schema_failure!(document, "#{location}/#{keyword} must be a string")
    end

    if schema.key?('$schema') && schema['$schema'] != DRAFT_2020_12
      schema_failure!(document, "#{location}/$schema must select Draft 2020-12")
    end

    return unless schema.key?('examples') && !schema['examples'].is_a?(Array)

    schema_failure!(document, "#{location}/examples must be an array")
  end

  def audit_type!(value, document, location)
    types = value.is_a?(Array) ? value : [value]
    unless !types.empty? && types.all? { |type| type.is_a?(String) && INSTANCE_TYPES.include?(type) } && types.uniq == types
      schema_failure!(document, "#{location}/type is not a supported unique JSON type or type array")
    end
  end

  def audit_ref!(ref, document, location, active_base)
    unless ref.is_a?(String) && !ref.empty?
      schema_failure!(document, "#{location}/$ref must be a non-empty string", code: :invalid_ref, path: "#{location}/$ref")
    end

    target_document, target_schema, target_base, reference_uri = resolve_ref(ref, document, active_base)
    unless target_schema.is_a?(Hash)
      schema_failure!(document, "#{location}/$ref must resolve to a schema object", code: :invalid_ref_target, path: "#{location}/$ref")
    end

    target_key = reference_uri
    return if @active_audit_refs.include?(target_key)

    @active_audit_refs.add(target_key)
    begin
      audit_schema!(target_schema, target_document, "#{location}/$ref", target_base)
    ensure
      @active_audit_refs.delete(target_key)
    end
  end

  def audit_defs!(defs, document, location, active_base)
    unless defs.is_a?(Hash) && defs.keys.all? { |name| name.is_a?(String) && !name.empty? }
      schema_failure!(document, "#{location}/$defs must be an object with non-empty names")
    end

    defs.each do |name, definition|
      audit_schema!(definition, document, "#{location}/$defs/#{escape_pointer(name)}", active_base)
    end
  end

  def audit_required!(required, document, location)
    unless required.is_a?(Array) && required.all? { |name| name.is_a?(String) } && required.uniq == required
      schema_failure!(document, "#{location}/required must contain unique property names")
    end
  end

  def audit_properties!(properties, document, location, active_base)
    unless properties.is_a?(Hash) && properties.keys.all? { |name| name.is_a?(String) }
      schema_failure!(document, "#{location}/properties must be an object")
    end

    properties.each do |name, subschema|
      audit_schema!(subschema, document, "#{location}/properties/#{escape_pointer(name)}", active_base)
    end
  end

  def audit_additional_properties!(value, document, location, active_base)
    return if value == true || value == false

    audit_schema!(value, document, "#{location}/additionalProperties", active_base)
  end

  def audit_non_negative_integer!(schema, keyword, document, location)
    return unless schema.key?(keyword)
    value = schema[keyword]
    return if value.is_a?(Integer) && value >= 0

    schema_failure!(document, "#{location}/#{keyword} must be a non-negative integer")
  end

  def audit_boolean!(schema, keyword, document, location)
    return unless schema.key?(keyword)
    return if schema[keyword] == true || schema[keyword] == false

    schema_failure!(document, "#{location}/#{keyword} must be boolean")
  end

  def audit_pattern!(pattern, document, location)
    unless pattern.is_a?(String)
      schema_failure!(document, "#{location}/pattern must be a string")
    end
    compile_json_pattern(pattern)
  rescue RegexpError => error
    schema_failure!(document, "#{location}/pattern is invalid: #{error.message}")
  end

  def audit_format!(format, document, location)
    return if format == 'date-time'

    schema_failure!(document, "#{location}/format is unsupported: #{format.inspect}")
  end

  def audit_number!(schema, keyword, document, location)
    return unless schema.key?(keyword)
    return if json_number?(schema[keyword])

    schema_failure!(document, "#{location}/#{keyword} must be a finite JSON number")
  end

  def audit_enum!(values, document, location)
    unless values.is_a?(Array) && !values.empty? && values.each_index.none? do |index|
             values.first(index).any? { |earlier| json_equal?(earlier, values[index]) }
           end
      schema_failure!(document, "#{location}/enum must contain unique values")
    end
  end

  def audit_one_of!(branches, document, location, active_base)
    unless branches.is_a?(Array) && !branches.empty?
      schema_failure!(document, "#{location}/oneOf must contain at least one schema")
    end

    branches.each_with_index do |branch, index|
      audit_schema!(branch, document, "#{location}/oneOf/#{index}", active_base)
    end
  end

  def audit_bounds!(schema, document, location)
    if schema.key?('minItems') && schema.key?('maxItems') && schema['minItems'] > schema['maxItems']
      schema_failure!(document, "#{location} has minItems greater than maxItems")
    end
    if schema.key?('minLength') && schema.key?('maxLength') && schema['minLength'] > schema['maxLength']
      schema_failure!(document, "#{location} has minLength greater than maxLength")
    end
    if schema.key?('minimum') && schema.key?('maximum') && schema['minimum'] > schema['maximum']
      schema_failure!(document, "#{location} has minimum greater than maximum")
    end
  end

  def resolve_ref(ref, source_document, active_base)
    begin
      resolved = URI.join(active_base, ref).normalize
    rescue URI::InvalidURIError, ArgumentError => error
      schema_failure!(source_document, "invalid $ref URI #{ref.inspect}: #{error.message}", code: :invalid_ref)
    end

    fragment = resolved.fragment
    fragment = nil if fragment == ''
    resource_uri = resolved.dup
    resource_uri.fragment = nil
    resource_key = resource_uri.normalize.to_s
    resource = @resource_registry[resource_key]
    unless resource
      schema_failure!(source_document, "unregistered local $ref resource: #{resource_key}", code: :unregistered_ref)
    end

    cache_key = [resource_key, fragment]
    target = @resolution_cache[cache_key] ||= resolve_fragment(resource.schema, fragment, resource.document)
    target_base = active_base_for(target, resource.document, resource_key)
    reference_uri = fragment ? "#{resource_key}##{fragment}" : resource_key
    [resource.document, target, target_base, reference_uri]
  end

  def resolve_fragment(document, fragment, document_path)
    return document if fragment.nil? || fragment.empty?

    if fragment.match?(/%(?![0-9A-Fa-f]{2})/)
      schema_failure!(document_path, "malformed percent escape in fragment: ##{fragment}", code: :malformed_pointer)
    end

    decoded = URI::DEFAULT_PARSER.unescape(fragment).dup.force_encoding(Encoding::UTF_8)
    unless decoded.valid_encoding? && decoded.start_with?('/')
      schema_failure!(document_path, "only valid UTF-8 JSON Pointer fragments are supported: ##{fragment}", code: :malformed_pointer)
    end

    decoded.split('/', -1).drop(1).reduce(document) do |current, raw_token|
      if raw_token.match?(/~(?:[^01]|\z)/)
        schema_failure!(document_path, "malformed JSON Pointer escaping: ##{fragment}", code: :malformed_pointer)
      end
      token = raw_token.gsub('~1', '/').gsub('~0', '~')
      case current
      when Hash
        unless current.key?(token)
          schema_failure!(document_path, "unresolvable JSON Pointer fragment: ##{fragment}", code: :missing_pointer)
        end
        current.fetch(token)
      when Array
        unless token.match?(/\A(?:0|[1-9][0-9]*)\z/) && token.to_i < current.length
          schema_failure!(document_path, "unresolvable JSON Pointer array index: ##{fragment}", code: :missing_pointer)
        end
        current.fetch(token.to_i)
      else
        schema_failure!(document_path, "JSON Pointer traverses a scalar: ##{fragment}", code: :missing_pointer)
      end
    end
  end

  def validate_schema!(instance, schema, document, path, active_refs, inherited_base)
    active_base = active_base_for(schema, document, inherited_base)
    if schema.key?('$ref')
      target_document, target_schema, target_base, reference_uri = resolve_ref(schema.fetch('$ref'), document, active_base)
      reference_key = [reference_uri, path]
      if active_refs.include?(reference_key)
        validation_failure!(path, 'non-progressing recursive $ref', code: :recursive_ref)
      end

      next_refs = active_refs.dup.add(reference_key)
      validate_schema!(instance, target_schema, target_document, path, next_refs, target_base)
    end

    if schema.key?('oneOf')
      matches = 0
      causes = []
      schema.fetch('oneOf').each do |branch|
        begin
          validate_schema!(instance, branch, document, path, active_refs.dup, active_base)
          matches += 1
        rescue ContractValidationError => error
          causes << error
        end
      end
      unless matches == 1
        code = matches.zero? ? :one_of_no_match : :one_of_multiple_matches
        validation_failure!(path, "oneOf matched #{matches} branches", code: code, causes: causes)
      end
    end

    if schema.key?('const') && !json_equal?(instance, schema.fetch('const'))
      validation_failure!(path, 'does not match const', code: :const)
    end
    if schema.key?('enum') && schema.fetch('enum').none? { |entry| json_equal?(instance, entry) }
      validation_failure!(path, 'is not in enum', code: :enum)
    end

    validate_type!(instance, schema.fetch('type'), path) if schema.key?('type')
    validate_object!(instance, schema, document, path, active_refs, active_base) if instance.is_a?(Hash)
    validate_array!(instance, schema, document, path, active_refs, active_base) if instance.is_a?(Array)
    validate_string!(instance, schema, path) if instance.is_a?(String)
    validate_number!(instance, schema, path) if json_number?(instance)
  end

  def validate_type!(instance, declared, path)
    types = declared.is_a?(Array) ? declared : [declared]
    return if types.any? { |type| type_match?(instance, type) }

    validation_failure!(path, "does not match type #{types.join(' or ')}", code: :type)
  end

  def type_match?(instance, type)
    case type
    when 'object' then instance.is_a?(Hash)
    when 'array' then instance.is_a?(Array)
    when 'string' then instance.is_a?(String)
    when 'number' then json_number?(instance)
    when 'integer' then json_integer?(instance)
    when 'boolean' then instance == true || instance == false
    when 'null' then instance.nil?
    else false
    end
  end

  def validate_object!(instance, schema, document, path, active_refs, active_base)
    required = schema.fetch('required', [])
    required.each do |name|
      validation_failure!(property_path(path, name), "is missing required property #{name}", code: :required) unless instance.key?(name)
    end

    properties = schema.fetch('properties', {})
    instance.each do |name, value|
      if properties.key?(name)
        validate_schema!(value, properties.fetch(name), document, property_path(path, name), active_refs.dup, active_base)
      elsif schema.key?('additionalProperties')
        additional = schema.fetch('additionalProperties')
        validation_failure!(property_path(path, name), 'is an additional property', code: :additional_property) if additional == false
        if additional.is_a?(Hash)
          validate_schema!(value, additional, document, property_path(path, name), active_refs.dup, active_base)
        end
      end
    end
  end

  def validate_array!(instance, schema, document, path, active_refs, active_base)
    if schema.key?('minItems') && instance.length < schema.fetch('minItems')
      validation_failure!(path, 'contains too few items', code: :min_items)
    end
    if schema.key?('maxItems') && instance.length > schema.fetch('maxItems')
      validation_failure!(path, 'contains too many items', code: :max_items)
    end
    if schema['uniqueItems'] && duplicate_json_item?(instance)
      validation_failure!(path, 'contains duplicate items', code: :unique_items)
    end
    return unless schema.key?('items')

    instance.each_with_index do |item, index|
      validate_schema!(item, schema.fetch('items'), document, "#{path}[#{index}]", active_refs.dup, active_base)
    end
  end

  def validate_string!(instance, schema, path)
    length = instance.each_char.count
    if schema.key?('minLength') && length < schema.fetch('minLength')
      validation_failure!(path, 'is shorter than minLength', code: :min_length)
    end
    if schema.key?('maxLength') && length > schema.fetch('maxLength')
      validation_failure!(path, 'is longer than maxLength', code: :max_length)
    end
    if schema.key?('pattern') && !compile_json_pattern(schema.fetch('pattern')).match?(instance)
      validation_failure!(path, 'does not match pattern', code: :pattern)
    end
    if schema['format'] == 'date-time' && !rfc3339_with_offset?(instance)
      validation_failure!(
        path,
        'is not valid under the ChronoFlow v1.0 RFC 3339 application profile',
        code: :format
      )
    end
  end

  def validate_number!(instance, schema, path)
    if schema.key?('minimum') && instance < schema.fetch('minimum')
      validation_failure!(path, 'is less than minimum', code: :minimum)
    end
    if schema.key?('maximum') && instance > schema.fetch('maximum')
      validation_failure!(path, 'is greater than maximum', code: :maximum)
    end
  end

  def rfc3339_with_offset?(value)
    match = value.match(
      /\A(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})T(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})(?:\.\d+)?(?<offset>Z|[+-](?<offset_hour>\d{2}):(?<offset_minute>\d{2}))\z/
    )
    return false unless match
    return false unless Date.valid_date?(match[:year].to_i, match[:month].to_i, match[:day].to_i)
    return false unless (0..23).cover?(match[:hour].to_i)
    return false unless (0..59).cover?(match[:minute].to_i)
    return false unless (0..59).cover?(match[:second].to_i)
    return true if match[:offset] == 'Z'

    (0..23).cover?(match[:offset_hour].to_i) && (0..59).cover?(match[:offset_minute].to_i)
  end

  def duplicate_json_item?(items)
    items.each_with_index.any? do |item, index|
      items.first(index).any? { |earlier| json_equal?(earlier, item) }
    end
  end

  def json_equal?(left, right)
    if json_numeric_candidate?(left) || json_numeric_candidate?(right)
      left_decimal = exact_json_decimal(left)
      right_decimal = exact_json_decimal(right)
      !left_decimal.nil? && !right_decimal.nil? && left_decimal == right_decimal
    elsif left.is_a?(Array) && right.is_a?(Array)
      left.length == right.length && left.zip(right).all? { |a, b| json_equal?(a, b) }
    elsif left.is_a?(Hash) && right.is_a?(Hash)
      left.keys.sort == right.keys.sort && left.all? { |key, value| json_equal?(value, right.fetch(key)) }
    else
      left.class == right.class && left == right
    end
  end

  def json_number?(value)
    !exact_json_decimal(value).nil?
  end

  def json_integer?(value)
    decimal = exact_json_decimal(value)
    !decimal.nil? && decimal == decimal.to_i
  end

  def json_numeric_candidate?(value)
    value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal)
  end

  def exact_json_decimal(value)
    case value
    when Integer
      BigDecimal(value.to_s)
    when Float
      return nil unless value.finite?

      BigDecimal(value.to_s)
    when BigDecimal
      value if value.finite?
    end
  end

  def property_path(path, name)
    "#{path}.#{name}"
  end

  def compile_json_pattern(pattern)
    Regexp.new(pattern)
  end

  def escape_pointer(value)
    value.gsub('~', '~0').gsub('/', '~1')
  end

  def ensure_utf8_tree!(value, path, document:, instance:)
    case value
    when String
      bytes = value.dup.force_encoding(Encoding::UTF_8)
      return if bytes.valid_encoding?

      if instance
        validation_failure!(path, 'is not valid UTF-8', code: :invalid_utf8)
      else
        schema_failure!(document, "#{path} contains invalid UTF-8", code: :invalid_utf8, path: path)
      end
    when Hash
      value.each do |key, child|
        unless key.is_a?(String)
          if instance
            validation_failure!(path, 'contains a non-string object key', code: :non_json_key)
          else
            schema_failure!(document, "#{path} contains a non-string object key", code: :non_json_key, path: path)
          end
        end
        ensure_utf8_tree!(key, "#{path}.<key>", document: document, instance: instance)
        ensure_utf8_tree!(child, property_path(path, key), document: document, instance: instance)
      end
    when Array
      value.each_with_index do |child, index|
        ensure_utf8_tree!(child, "#{path}[#{index}]", document: document, instance: instance)
      end
    end
  end

  def deep_freeze(value)
    case value
    when Hash
      value.each { |key, child| deep_freeze(key); deep_freeze(child) }
    when Array
      value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  def validation_failure!(path, message, code: :validation, causes: [])
    raise ContractValidationError.new(
      "#{path} #{message}", code: code, path: path, causes: causes
    )
  end

  def schema_failure!(document, message, code: :schema, path: nil)
    raise ContractValidationError.new(
      "#{document}: #{message}", code: code, path: path, document: document
    )
  end
end

class SchedulingRecommendationsV1SemanticValidator
  Failure = Struct.new(:invariant_id, :path, :message, :error_code, keyword_init: true)

  INVARIANT_IDS = (1..18).map { |number| format('SR-SEM-%03d', number) }.freeze
  MISSING_CONTEXT = Object.new.freeze

  def initialize(invariants)
    @invariants = invariants.to_h { |entry| [entry.fetch('id'), entry] }.freeze
    raise ArgumentError, 'semantic invariant registry mismatch' unless @invariants.keys == INVARIANT_IDS
  end

  def validate_required_context(invariant_id, context)
    failures = []
    context_ready?(failures, invariant_id, context)
    failures
  end

  def validate_payload(payload)
    failures = []
    operation = payload['operation']
    status = payload['status']
    role = payload.key?('status') ? 'response' : 'request'
    context = { role => payload, 'payload' => payload }

    if operation == 'recommend_time_slots' && !payload.key?('status')
      if context_ready?(failures, 'SR-SEM-001', context)
        ordered_pair(failures, 'SR-SEM-001', payload['search_window'], '$.search_window')
      end
      validate_timezone_offset_alignment(failures, payload) if context_ready?(failures, 'SR-SEM-018', context)
    end
    if operation == 'recommend_time_slots' && status == 'success'
      if context_ready?(failures, 'SR-SEM-002', context)
        ordered_values(
          failures, 'SR-SEM-002', payload['generated_at'], payload['expires_at'], '$.generated_at', '$.expires_at'
        )
      end
      validate_recommendation_candidates(failures, payload, context)
    end

    if context_ready?(failures, 'SR-SEM-003', context) && context_ready?(failures, 'SR-SEM-004', context)
      each_hash(payload) do |object, path|
        next unless %w[start_at end_at duration_minutes].all? { |key| object.key?(key) }

        ordered_pair(failures, 'SR-SEM-003', object, path)
        validate_duration(failures, object, path)
      end
    end

    if operation == 'revise_time_slot' && status == 'success'
      revised = payload['revised_candidate']
      if context_ready?(failures, 'SR-SEM-008', context)
        compare_exact(failures, 'SR-SEM-008', revised['recommendation_id'], payload['recommendation_id'],
                      '$.revised_candidate.recommendation_id')
      end
      if context_ready?(failures, 'SR-SEM-009', context)
        compare_exact(failures, 'SR-SEM-009', revised['candidate_id'], payload['candidate_id'],
                      '$.revised_candidate.candidate_id')
      end
      if context_ready?(failures, 'SR-SEM-010', context)
        compare_exact(failures, 'SR-SEM-010', revised['revision_id'], payload['revision_id'],
                      '$.revised_candidate.revision_id')
      end
    end

    failures
  end

  def validate_exchange(request:, response:, recommendation: MISSING_CONTEXT, revision: MISSING_CONTEXT)
    failures = validate_payload(request) + validate_payload(response)
    context = { 'request' => request, 'response' => response }
    context['recommendation'] = recommendation unless recommendation.equal?(MISSING_CONTEXT)
    context['revision'] = revision unless revision.equal?(MISSING_CONTEXT)
    if context_ready?(failures, 'SR-SEM-011', context)
      %w[request_id trace_id].each do |field|
        compare_exact(failures, 'SR-SEM-011', response[field], request[field], "$.response.#{field}")
      end
    end

    operation = request['operation']
    if operation == 'revise_time_slot' && response['status'] == 'success' &&
       context_ready?(failures, 'SR-SEM-012', context)
      response_expiry = parse_time(response['expires_at'])
      recommendation_expiry = parse_time(recommendation['expires_at'])
      unless response_expiry && recommendation_expiry && response_expiry == recommendation_expiry
        add_failure(failures, 'SR-SEM-012', '$.response.expires_at',
                    'must equal the valid original recommendation expiry')
      end
    end

    if operation == 'confirm_schedule_candidate' && response['status'] == 'committed'
      validate_confirm_exchange(failures, request, response, recommendation, revision, context)
    elsif operation == 'reject_schedule_recommendation' && response['status'] == 'recorded'
      if context_ready?(failures, 'SR-SEM-016', context)
        %w[recommendation_id action].each do |field|
          compare_exact(failures, 'SR-SEM-016', response[field], request[field], "$.response.#{field}")
        end
      end
    end

    if response['status'] == 'error' && context_ready?(failures, 'SR-SEM-017', context)
      %w[request_id trace_id].each do |field|
        compare_exact(failures, 'SR-SEM-017', response[field], request[field], "$.response.#{field}")
      end
    end
    failures
  end

  private

  def validate_recommendation_candidates(failures, payload, context)
    candidates = payload['candidates']
    ready = %w[SR-SEM-005 SR-SEM-006 SR-SEM-007].to_h do |invariant_id|
      [invariant_id, context_ready?(failures, invariant_id, context)]
    end
    return unless ready.values.any? && candidates.is_a?(Array)

    ids = candidates.map { |candidate| candidate['candidate_id'] }
    if ready['SR-SEM-005'] && ids.uniq.length != ids.length
      add_failure(failures, 'SR-SEM-005', '$.candidates', 'candidate_id values must be unique')
    end

    ranks = candidates.map { |candidate| candidate['rank'] }
    expected_ranks = (1..candidates.length).to_a
    if ready['SR-SEM-006'] && !(ranks.uniq.length == ranks.length && ranks.sort == expected_ranks)
      add_failure(failures, 'SR-SEM-006', '$.candidates', 'ranks must be unique and exactly 1..candidate_count')
    end

    return unless ready['SR-SEM-007']

    candidates.each_with_index do |candidate, index|
      compare_exact(
        failures, 'SR-SEM-007', candidate['recommendation_id'], payload['recommendation_id'],
        "$.candidates[#{index}].recommendation_id"
      )
    end
  end

  def validate_confirm_exchange(failures, request, response, recommendation, revision, context)
    if context_ready?(failures, 'SR-SEM-013', context)
      %w[recommendation_id candidate_id].each do |field|
        compare_exact(failures, 'SR-SEM-013', response[field], request[field], "$.response.#{field}")
      end
      if request.key?('revision_id')
        compare_exact(failures, 'SR-SEM-013', response['revision_id'], request['revision_id'], '$.response.revision_id')
      elsif response.key?('revision_id')
        add_failure(failures, 'SR-SEM-013', '$.response.revision_id', 'must be absent when request has no revision_id')
      end
    end

    if context_ready?(failures, 'SR-SEM-014', context) &&
       response['schedule_snapshot_version'] == request['schedule_snapshot_version']
      add_failure(
        failures, 'SR-SEM-014', '$.response.schedule_snapshot_version',
        'committed snapshot must differ from the pre-commit request snapshot'
      )
    end

    return unless context_ready?(failures, 'SR-SEM-015', context)

    selected_slot = selected_slot_for(request, recommendation, revision)
    if selected_slot.nil? || !json_equal?(response['final_slot'], selected_slot)
      add_failure(
        failures, 'SR-SEM-015', '$.response.final_slot',
        'final_slot must equal the selected candidate or accepted revision slot'
      )
    end
  end

  def selected_slot_for(request, recommendation, revision)
    if request.key?('revision_id')
      return unless revision.is_a?(Hash)
      revised = revision['revised_candidate']
      return unless revised.is_a?(Hash)
      return unless revision['revision_id'] == request['revision_id']
      return unless revised['candidate_id'] == request['candidate_id']

      revised['slot']
    else
      return unless recommendation.is_a?(Hash) && recommendation['candidates'].is_a?(Array)

      recommendation['candidates'].find { |candidate| candidate['candidate_id'] == request['candidate_id'] }&.fetch('slot', nil)
    end
  end

  def context_ready?(failures, invariant_id, context)
    invariant = @invariants.fetch(invariant_id)
    missing_path = invariant.fetch('required_context_paths').find do |path|
      !valid_context_path?(context, path)
    end
    return true unless missing_path

    add_failure(
      failures, invariant_id, invariant.fetch('failure_path'),
      "required semantic context is missing or malformed: #{missing_path}"
    )
    false
  end

  def valid_context_path?(context, json_path)
    parts = json_path.delete_prefix('$.').split('.')
    value = context
    parts.each_with_index do |part, index|
      return false unless value.is_a?(Hash) && value.key?(part)

      value = value.fetch(part)
      return false if value.nil?
      next unless index < parts.length - 1
      return false unless value.is_a?(Hash)
    end

    object_leaf = %w[
      request response recommendation revision payload search_window revised_candidate final_slot
    ].include?(parts.last)
    array_leaf = parts.last == 'candidates'
    return value.is_a?(Hash) if object_leaf
    return value.is_a?(Array) if array_leaf

    value.is_a?(String) && !value.empty?
  end

  def validate_timezone_offset_alignment(failures, request)
    zone = TZInfo::Timezone.get(request.fetch('time_zone'))
    request.fetch('search_window').slice('start_at', 'end_at').each do |field, value|
      instant = parse_time(value)
      expected_offset = instant && zone.period_for_utc(instant.getutc).utc_total_offset
      next if instant && instant.utc_offset == expected_offset

      add_failure(
        failures, 'SR-SEM-018', "$.search_window.#{field}",
        'RFC 3339 offset must equal the IANA zone offset at this instant',
        error_code: 'INVALID_TIME_WINDOW'
      )
    end
  rescue KeyError, TZInfo::InvalidTimezoneIdentifier, TZInfo::PeriodNotFound, TZInfo::AmbiguousTime
    add_failure(
      failures, 'SR-SEM-018', '$.search_window',
      'timezone alignment context is invalid', error_code: 'INVALID_TIME_WINDOW'
    )
  end

  def validate_duration(failures, slot, path)
    start_time = parse_time(slot['start_at'])
    end_time = parse_time(slot['end_at'])
    expected_seconds = slot['duration_minutes'].to_i * 60
    return if start_time && end_time && (end_time - start_time) == expected_seconds

    add_failure(failures, 'SR-SEM-004', "#{path}.duration_minutes", 'duration must equal elapsed slot minutes')
  end

  def ordered_pair(failures, invariant_id, object, path)
    return unless object.is_a?(Hash)

    ordered_values(failures, invariant_id, object['start_at'], object['end_at'],
                   "#{path}.start_at", "#{path}.end_at")
  end

  def ordered_values(failures, invariant_id, first, second, first_path, second_path)
    first_time = parse_time(first)
    second_time = parse_time(second)
    return if first_time && second_time && first_time < second_time

    add_failure(failures, invariant_id, second_path, "#{first_path} must be earlier than #{second_path}")
  end

  def parse_time(value)
    Time.iso8601(value)
  rescue ArgumentError, TypeError
    nil
  end

  def compare_exact(failures, invariant_id, actual, expected, path)
    return if json_equal?(actual, expected)

    add_failure(failures, invariant_id, path, 'does not match its bound value')
  end

  def json_equal?(left, right)
    if left.is_a?(Numeric) && right.is_a?(Numeric) && left != true && right != true
      BigDecimal(left.to_s) == BigDecimal(right.to_s)
    elsif left.is_a?(Array) && right.is_a?(Array)
      left.length == right.length && left.zip(right).all? { |a, b| json_equal?(a, b) }
    elsif left.is_a?(Hash) && right.is_a?(Hash)
      left.keys.sort == right.keys.sort && left.all? { |key, value| json_equal?(value, right.fetch(key)) }
    else
      left.class == right.class && left == right
    end
  end

  def each_hash(value, path = '$', &block)
    case value
    when Hash
      yield value, path
      value.each do |key, child|
        each_hash(child, "#{path}.#{key}", &block)
      end
    when Array
      value.each_with_index { |child, index| each_hash(child, "#{path}[#{index}]", &block) }
    end
  end

  def add_failure(failures, invariant_id, path, message, error_code: nil)
    failures << Failure.new(
      invariant_id: invariant_id, path: path, message: message, error_code: error_code
    )
  end
end

class SchedulingConfirmationEvidenceReference
  Result = Struct.new(:outcome, :error_code, :evidence_id, keyword_init: true)

  attr_reader :token_lookup_count, :idempotency_allocation_count, :event_side_effect_count,
              :evidence_creation_count

  def initialize(now:)
    @now = now
    @token_lookup_count = 0
    @idempotency_allocation_count = 0
    @event_side_effect_count = 0
    @evidence_creation_count = 0
    @evidence_by_user_action = {}
  end

  def create_for_authenticated_action(user_action_id, evidence)
    @evidence_by_user_action[user_action_id] ||= begin
      @evidence_creation_count += 1
      evidence
    end
  end

  def authorize(evidence:, request_context:, authenticated_tenant:, model_only: false)
    return rejected unless evidence.is_a?(Hash) && !model_only
    return rejected unless evidence['status'] == 'active'
    return rejected unless evidence_matches?(evidence, request_context, authenticated_tenant)
    return rejected unless unexpired?(evidence)

    @idempotency_allocation_count += 1
    @token_lookup_count += 1
    Result.new(outcome: 'AUTHORIZED_TO_CONTINUE', evidence_id: evidence['evidence_id'])
  end

  private

  def rejected
    Result.new(outcome: 'REJECTED', error_code: 'CONFIRMATION_REQUIRED')
  end

  def evidence_matches?(evidence, request, tenant)
    return false unless request.is_a?(Hash) && tenant.is_a?(Hash)
    return false unless present_string?(evidence['evidence_id'])
    return false unless %w[
      authenticated_user_id authenticated_workspace_id recommendation_id candidate_id
      final_slot_canonical_fingerprint pre_commit_schedule_snapshot_version recommendation_expires_at
    ].all? { |field| present_string?(evidence[field]) }
    return false unless %w[
      recommendation_id candidate_id final_slot_canonical_fingerprint
      pre_commit_schedule_snapshot_version recommendation_expires_at
    ].all? { |field| present_string?(request[field]) }
    return false unless %w[authenticated_user_id authenticated_workspace_id].all? do |field|
      present_string?(tenant[field])
    end
    return false unless evidence['authenticated_user_id'] == tenant['authenticated_user_id']
    return false unless evidence['authenticated_workspace_id'] == tenant['authenticated_workspace_id']

    %w[recommendation_id candidate_id final_slot_canonical_fingerprint
       pre_commit_schedule_snapshot_version recommendation_expires_at].all? do |field|
      evidence[field] == request[field]
    end && revision_exact_or_absent?(evidence, request)
  end

  def revision_exact_or_absent?(evidence, request)
    evidence_has_revision = evidence.key?('revision_id')
    request_has_revision = request.key?('revision_id')
    return false unless evidence_has_revision == request_has_revision
    return true unless evidence_has_revision
    return false unless present_string?(evidence['revision_id']) && present_string?(request['revision_id'])

    evidence['revision_id'] == request['revision_id']
  end

  def present_string?(value)
    value.is_a?(String) && !value.empty?
  end

  def unexpired?(evidence)
    @now < Time.iso8601(evidence.fetch('recommendation_expires_at'))
  rescue ArgumentError, KeyError, TypeError
    false
  end
end

class SchedulingIdempotencyLifecycleReference
  Attempt = Struct.new(
    :attempt_id, :evidence_id, :idempotency_key, :state, :allocated_at, :result,
    :terminal_stored_at,
    keyword_init: true
  )
  AuthoritativeResult = Struct.new(:state, :result, :stored_at, keyword_init: true)

  ALLOWED_TRANSITIONS = Set.new([
    %w[allocated in_progress],
    %w[in_progress committed],
    %w[in_progress failed_terminal],
    %w[in_progress outcome_unknown],
    %w[outcome_unknown in_progress],
    %w[outcome_unknown committed],
    %w[outcome_unknown failed_terminal]
  ]).freeze
  TERMINAL_STATES = Set.new(%w[committed failed_terminal]).freeze
  RETRY_WINDOW_SECONDS = 86_400
  RETENTION_MINIMUM_SECONDS = 86_400

  attr_reader :allocation_count, :event_side_effect_count, :feedback_side_effect_count,
              :authoritative_lookup_count, :dispatch_count, :atomic_commit_count,
              :operation_log

  def initialize(retention_seconds: RETENTION_MINIMUM_SECONDS)
    raise ArgumentError, 'retention below contract minimum' if retention_seconds < RETENTION_MINIMUM_SECONDS

    @mutex = Mutex.new
    @attempts = {}
    @allocation_count = 0
    @event_side_effect_count = 0
    @feedback_side_effect_count = 0
    @authoritative_lookup_count = 0
    @dispatch_count = 0
    @atomic_commit_count = 0
    @retention_seconds = retention_seconds
    @authoritative_results = {}
    @operation_log = []
  end

  def acquire(evidence_id:, now:, evidence_status: 'active', model_invocation_id: nil)
    @mutex.synchronize do
      existing = @attempts[evidence_id]
      return existing if existing
      raise ArgumentError, 'only active evidence can allocate' unless evidence_status == 'active'

      @allocation_count += 1
      index = @allocation_count
      @attempts[evidence_id] = Attempt.new(
        attempt_id: format('attempt_fixed_%04d', index),
        evidence_id: evidence_id,
        idempotency_key: format('idem_fixed_%08d', index),
        state: 'allocated',
        allocated_at: now
      )
    end
  end

  def transition!(attempt, next_state)
    @mutex.synchronize do
      pair = [attempt.state, next_state]
      raise ArgumentError, 'terminal or forbidden transition' unless ALLOWED_TRANSITIONS.include?(pair)

      attempt.state = next_state
      attempt
    end
  end

  def execute_or_replay!(attempt, now:, outcome: :committed, evidence_status: 'active')
    @mutex.synchronize do
      authoritative = authoritative_result_without_lock(attempt, now)
      return reconcile_terminal_without_lock(attempt, authoritative) if authoritative

      raise ArgumentError, 'terminal result unavailable; retry fails closed' if TERMINAL_STATES.include?(attempt.state)
      raise ArgumentError, 'consumed evidence has no committed result' unless evidence_status == 'active'
      raise ArgumentError, 'logical confirmation retry window closed' unless retry_window_open?(attempt, now)

      pair = [attempt.state, 'in_progress']
      if attempt.state != 'in_progress'
        raise ArgumentError, 'cannot dispatch from current state' unless ALLOWED_TRANSITIONS.include?(pair)

        attempt.state = 'in_progress'
      end
      @dispatch_count += 1
      @operation_log << 'dispatch_with_existing_idempotency_key'

      case outcome
      when :committed
        staged = stage_terminal_result_without_lock('committed')
        atomic_store_terminal_without_lock(attempt, staged, now)
      when :failed_terminal
        staged = stage_terminal_result_without_lock('failed_terminal')
        atomic_store_terminal_without_lock(attempt, staged, now)
      when :outcome_unknown
        attempt.state = 'outcome_unknown'
        {
          'status' => 'outcome_unknown',
          'logical_attempt_id' => attempt.attempt_id,
          'same_idempotency_key_required' => true
        }.freeze
      else
        raise ArgumentError, 'unknown simulated outcome'
      end
    end
  end

  def record_authoritative_terminal_after_lost_response!(attempt, state:, now:)
    @mutex.synchronize do
      raise ArgumentError, 'only an unresolved attempt can be reconciled' unless attempt.state == 'outcome_unknown'
      raise ArgumentError, 'authoritative result already exists' if @authoritative_results.key?(attempt.idempotency_key)

      staged = stage_terminal_result_without_lock(state)
      atomic_store_terminal_without_lock(attempt, staged, now, update_local: false)
    end
  end

  def stage_terminal_result_for_atomic_commit(attempt, state:)
    @mutex.synchronize do
      raise ArgumentError, 'attempt must be in progress' unless attempt.state == 'in_progress'
      raise ArgumentError, 'authoritative result already exists' if @authoritative_results.key?(attempt.idempotency_key)

      stage_terminal_result_without_lock(state)
    end
  end

  def commit!(attempt, now: attempt.allocated_at)
    execute_or_replay!(attempt, now: now, outcome: :committed)
  end

  def replay_committed(evidence_id, now:)
    attempt = @mutex.synchronize { @attempts.fetch(evidence_id) }
    result = execute_or_replay!(attempt, now: now, evidence_status: 'consumed')
    raise ArgumentError, 'not committed' unless attempt.state == 'committed'

    result
  end

  def retry_window_open?(attempt, now)
    now < attempt.allocated_at + RETRY_WINDOW_SECONDS
  end

  def force_second_key!(evidence_id)
    @mutex.synchronize do
      raise ArgumentError, 'one evidence already owns one key' if @attempts.key?(evidence_id)
    end
  end

  private

  def authoritative_result_without_lock(attempt, now)
    @authoritative_lookup_count += 1
    @operation_log << 'authoritative_idempotency_state_lookup'
    authoritative = @authoritative_results[attempt.idempotency_key]
    return unless authoritative
    return unless now < authoritative.stored_at + @retention_seconds

    authoritative
  end

  def reconcile_terminal_without_lock(attempt, authoritative)
    unless attempt.state == authoritative.state
      pair = [attempt.state, authoritative.state]
      raise ArgumentError, 'authoritative terminal state conflicts with local state' unless ALLOWED_TRANSITIONS.include?(pair)

      attempt.state = authoritative.state
    end
    attempt.result = authoritative.result
    attempt.terminal_stored_at = authoritative.stored_at
    authoritative.result
  end

  def stage_terminal_result_without_lock(state)
    raise ArgumentError, 'terminal state required' unless TERMINAL_STATES.include?(state)

    @operation_log << 'stage_terminal_result_for_atomic_commit'
    { 'terminal_state' => state, 'durable' => false }.freeze
  end

  def atomic_store_terminal_without_lock(attempt, staged, now, update_local: true)
    state = staged.fetch('terminal_state')
    raise ArgumentError, 'only a non-durable staged result may commit' unless staged['durable'] == false
    raise ArgumentError, 'terminal result already exists' if @authoritative_results.key?(attempt.idempotency_key)

    result = if state == 'committed'
               @event_side_effect_count += 1
               @feedback_side_effect_count += 1
               {
                 'status' => 'committed',
                 'event_id' => format('evt_fixed_%08d', @event_side_effect_count),
                 'feedback_event_id' => format('fb_fixed_%08d', @feedback_side_effect_count)
               }.freeze
             else
               {
                 'status' => 'failed_terminal',
                 'code' => 'SPECIALIST_TIMEOUT',
                 'retryable' => false
               }.freeze
             end

    authoritative = AuthoritativeResult.new(state: state, result: result, stored_at: now).freeze
    @authoritative_results[attempt.idempotency_key] = authoritative
    @atomic_commit_count += 1
    @operation_log << 'atomically_store_result_event_feedback_snapshot_and_consume_token_evidence'
    if update_local
      attempt.state = state
      attempt.result = result
      attempt.terminal_stored_at = now
    end
    result
  end
end

class SchedulingRecommendationsV1ContractTest < ActiveSupport::TestCase
  SCHEMA_ROOT = Rails.root.join('contracts', 'scheduling_recommendations', 'v1')
  FIXTURE_ROOT = Rails.root.join('test', 'fixtures', 'scheduling_recommendations', 'v1')
  DOC_ROOT = Rails.root.join('docs', 'scheduling_recommendations', 'v1')

  SCHEMA_FILES = %w[
    common.schema.json
    recommend_time_slots.request.schema.json
    recommend_time_slots.response.schema.json
    revise_time_slot.request.schema.json
    revise_time_slot.response.schema.json
    confirm_schedule_candidate.request.schema.json
    confirm_schedule_candidate.response.schema.json
    reject_schedule_recommendation.request.schema.json
    reject_schedule_recommendation.response.schema.json
    error.schema.json
    model_tool.schema.json
    contract_data.schema.json
    reason_codes.json
    penalty_codes.json
    error_codes.json
  ].freeze

  CONTRACT_DATA_FILES = %w[
    operation_error_matrix.json
    recommend_input_ownership.json
    semantic_invariants.json
    tool_manifest.json
    confirmation_evidence_contract.json
    idempotency_lifecycle.json
    contract_invalid_field_matrix.json
  ].freeze

  CONTRACT_DATA_DEFS = {
    'operation_error_matrix.json' => 'operationErrorMatrix',
    'recommend_input_ownership.json' => 'recommendInputOwnership',
    'semantic_invariants.json' => 'semanticInvariants',
    'tool_manifest.json' => 'toolManifest',
    'confirmation_evidence_contract.json' => 'confirmationEvidence',
    'idempotency_lifecycle.json' => 'idempotencyLifecycle',
    'contract_invalid_field_matrix.json' => 'contractInvalidFieldMatrix'
  }.freeze

  CONTRACT_INVALID_SAFE_FIELDS = {
    'recommend_time_slots' => %w[
      schema_version operation request_id trace_id title duration_minutes search_window
      search_window.start_at search_window.end_at time_zone
    ],
    'revise_time_slot' => %w[
      schema_version operation request_id trace_id recommendation_id candidate_id proposed_slot
      proposed_slot.start_at proposed_slot.end_at proposed_slot.duration_minutes optional_change_reason
    ],
    'confirm_schedule_candidate' => %w[
      schema_version operation request_id trace_id recommendation_id candidate_id revision_id
    ],
    'reject_schedule_recommendation' => %w[
      schema_version operation request_id trace_id recommendation_id action optional_reason
    ]
  }.transform_values(&:freeze).freeze

  CONTRACT_INVALID_DEFINITION_BY_OPERATION = {
    'recommend_time_slots' => 'CONTRACT_INVALID_RECOMMEND',
    'revise_time_slot' => 'CONTRACT_INVALID_REVISE',
    'confirm_schedule_candidate' => 'CONTRACT_INVALID_CONFIRM',
    'reject_schedule_recommendation' => 'CONTRACT_INVALID_REJECT'
  }.freeze

  ABSOLUTE_STRING_DEFS = %w[
    requestId traceId recommendationId candidateId revisionId confirmationToken idempotencyKey
    eventId feedbackEventId scheduleSnapshotVersion dateTime timeZone
  ].freeze

  CONTROL_MUTATIONS = {
    'trailing_lf' => "\n", 'trailing_cr' => "\r", 'trailing_u2028' => "\u2028",
    'trailing_u2029' => "\u2029", 'leading_lf' => "\n", 'embedded_nul' => "\u0000",
    'embedded_vt' => "\u000B", 'embedded_ff' => "\u000C", 'embedded_nel' => "\u0085",
    'embedded_del' => "\u007F"
  }.freeze

  LEAP_SECOND_INVALID_DATE_TIMES = %w[
    2016-12-31T23:59:60Z
    1990-12-31T23:59:60Z
    1990-12-31T15:59:60-08:00
    2016-12-31T23:59:60.5Z
    2026-06-30T23:59:60Z
    2026-09-02T12:00:60+09:00
    2016-12-31T23:59:61Z
    2016-12-31T23:59:99Z
  ].freeze

  NORMAL_SECOND_VALID_DATE_TIMES = %w[
    2016-12-31T23:59:59Z
    2017-01-01T00:00:00Z
    1990-12-31T15:59:59-08:00
    2016-12-31T23:59:59.999999Z
    2026-09-02T12:00:00+09:00
    2026-09-02T12:00:59+09:00
  ].freeze

  LEAP_SECOND_WIRE_PATHS = [
    ['recommend request start', 'recommend_time_slots.request.json',
     'recommend_time_slots.request.schema.json', ['search_window', 'start_at']],
    ['recommend request end', 'recommend_time_slots.request.json',
     'recommend_time_slots.request.schema.json', ['search_window', 'end_at']],
    ['recommend response generated', 'recommend_time_slots.response.json',
     'recommend_time_slots.response.schema.json', ['generated_at']],
    ['recommend response expiry', 'recommend_time_slots.response.json',
     'recommend_time_slots.response.schema.json', ['expires_at']],
    ['recommend candidate start', 'recommend_time_slots.response.json',
     'recommend_time_slots.response.schema.json', ['candidates', 0, 'slot', 'start_at']],
    ['recommend candidate end', 'recommend_time_slots.response.json',
     'recommend_time_slots.response.schema.json', ['candidates', 0, 'slot', 'end_at']],
    ['revise request start', 'revise_time_slot.request.json',
     'revise_time_slot.request.schema.json', ['proposed_slot', 'start_at']],
    ['revise request end', 'revise_time_slot.request.json',
     'revise_time_slot.request.schema.json', ['proposed_slot', 'end_at']],
    ['revise response expiry', 'revise_time_slot.feasible.response.json',
     'revise_time_slot.response.schema.json', ['expires_at']],
    ['revised candidate start', 'revise_time_slot.feasible.response.json',
     'revise_time_slot.response.schema.json', ['revised_candidate', 'slot', 'start_at']],
    ['revised candidate end', 'revise_time_slot.feasible.response.json',
     'revise_time_slot.response.schema.json', ['revised_candidate', 'slot', 'end_at']],
    ['confirm final slot start', 'confirm_schedule_candidate.committed.response.json',
     'confirm_schedule_candidate.response.schema.json', ['final_slot', 'start_at']],
    ['confirm final slot end', 'confirm_schedule_candidate.committed.response.json',
     'confirm_schedule_candidate.response.schema.json', ['final_slot', 'end_at']],
    ['confirm committed at', 'confirm_schedule_candidate.committed.response.json',
     'confirm_schedule_candidate.response.schema.json', ['committed_at']],
    ['reject recorded at', 'reject_schedule_recommendation.response.json',
     'reject_schedule_recommendation.response.schema.json', ['recorded_at']],
    ['expired error detail', 'confirm_schedule_candidate.expired.response.json',
     'confirm_schedule_candidate.response.schema.json', ['error', 'details', 'expired_at']]
  ].freeze

  LEAP_SECOND_MODEL_PATHS = [
    ['recommend arguments start', :arguments, 'recommend_time_slots', ['search_window', 'start_at']],
    ['recommend arguments end', :arguments, 'recommend_time_slots', ['search_window', 'end_at']],
    ['revise arguments start', :arguments, 'revise_time_slot', ['proposed_slot', 'start_at']],
    ['revise arguments end', :arguments, 'revise_time_slot', ['proposed_slot', 'end_at']],
    ['recommend result expiry', :result, 'recommend_time_slots', ['expires_at']],
    ['recommend result slot start', :result, 'recommend_time_slots', ['candidates', 0, 'slot', 'start_at']],
    ['recommend result slot end', :result, 'recommend_time_slots', ['candidates', 0, 'slot', 'end_at']],
    ['revise result expiry', :result, 'revise_time_slot', ['expires_at']],
    ['revise result slot start', :result, 'revise_time_slot', ['revised_candidate', 'slot', 'start_at']],
    ['revise result slot end', :result, 'revise_time_slot', ['revised_candidate', 'slot', 'end_at']],
    ['confirm result slot start', :result, 'confirm_schedule_candidate', ['final_slot', 'start_at']],
    ['confirm result slot end', :result, 'confirm_schedule_candidate', ['final_slot', 'end_at']]
  ].freeze

  VALID_FIXTURES = {
    'recommend_time_slots.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.no_feasible_slot.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.location_required.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.travel_time_unavailable.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.opening_hours_unavailable.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.profile_not_configured.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.invalid_time_window.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.invalid_duration.response.json' => 'recommend_time_slots.response.schema.json',
    'revise_time_slot.request.json' => 'revise_time_slot.request.schema.json',
    'revise_time_slot.feasible.response.json' => 'revise_time_slot.response.schema.json',
    'revise_time_slot.infeasible.response.json' => 'revise_time_slot.response.schema.json',
    'confirm_schedule_candidate.request.json' => 'confirm_schedule_candidate.request.schema.json',
    'confirm_schedule_candidate.committed.response.json' => 'confirm_schedule_candidate.response.schema.json',
    'confirm_schedule_candidate.expired.response.json' => 'confirm_schedule_candidate.response.schema.json',
    'confirm_schedule_candidate.stale_snapshot.response.json' => 'confirm_schedule_candidate.response.schema.json',
    'reject_schedule_recommendation.request.json' => 'reject_schedule_recommendation.request.schema.json',
    'reject_schedule_recommendation.response.json' => 'reject_schedule_recommendation.response.schema.json',
    'reject_schedule_recommendation.not_found.response.json' => 'reject_schedule_recommendation.response.schema.json'
  }.freeze

  INVALID_FIXTURES = {
    'recommend_time_slots.missing_schema_version.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.unknown_field.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.invalid_operation.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.invalid_datetime.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.leap_second.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.unknown_reason_code.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.unknown_penalty_code.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.error.missing_trace_id.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.error.unknown_status.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.ambiguous_success_error.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.invalid_timezone_trailing_slash.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.invalid_timezone_empty_component.request.json' => 'recommend_time_slots.request.schema.json',
    'revise_time_slot.unknown_error_code.response.json' => 'revise_time_slot.response.schema.json',
    'reject_schedule_recommendation.error.invalid_code.response.json' => 'reject_schedule_recommendation.response.schema.json',
    'error.conflict_with_missing_profile_keys.json' => 'error.schema.json',
    'error.invalid_token_with_conflicting_event_count.json' => 'error.schema.json',
    'error.profile_with_expired_at.json' => 'error.schema.json',
    'error.retryable_mismatch.json' => 'error.schema.json',
    'confirm_schedule_candidate.cross_binding.request.json' => 'confirm_schedule_candidate.request.schema.json',
    'confirm_schedule_candidate.missing_confirmation_token.request.json' => 'confirm_schedule_candidate.request.schema.json',
    'confirm_schedule_candidate.missing_idempotency_key.request.json' => 'confirm_schedule_candidate.request.schema.json'
  }.freeze

  INVALID_FIXTURE_EXPECTATIONS = {
    'recommend_time_slots.missing_schema_version.request.json' => ['$.schema_version', 'required'],
    'recommend_time_slots.unknown_field.request.json' => ['$.maximum_results', 'additional_property'],
    'recommend_time_slots.invalid_operation.request.json' => ['$.operation', 'const'],
    'recommend_time_slots.invalid_datetime.request.json' => ['$.search_window.start_at', 'pattern'],
    'recommend_time_slots.leap_second.request.json' => ['$.search_window.start_at', 'pattern'],
    'recommend_time_slots.unknown_reason_code.response.json' => ['$.candidates[0].reason_codes[0]', 'enum'],
    'recommend_time_slots.unknown_penalty_code.response.json' => ['$.candidates[1].penalty_codes[0]', 'enum'],
    'recommend_time_slots.error.missing_trace_id.response.json' => ['$.trace_id', 'required'],
    'recommend_time_slots.error.unknown_status.response.json' => ['$.status', 'const'],
    'recommend_time_slots.ambiguous_success_error.response.json' => ['$.error', 'additional_property'],
    'recommend_time_slots.invalid_timezone_trailing_slash.request.json' => ['$.time_zone', 'pattern'],
    'recommend_time_slots.invalid_timezone_empty_component.request.json' => ['$.time_zone', 'pattern'],
    'revise_time_slot.unknown_error_code.response.json' => ['$.error.code', 'const'],
    'reject_schedule_recommendation.error.invalid_code.response.json' => ['$.error.code', 'const'],
    'error.conflict_with_missing_profile_keys.json' => ['$.details.missing_profile_keys', 'additional_property'],
    'error.invalid_token_with_conflicting_event_count.json' => ['$.details.conflicting_event_count', 'additional_property'],
    'error.profile_with_expired_at.json' => ['$.details.expired_at', 'additional_property'],
    'error.retryable_mismatch.json' => ['$.retryable', 'const'],
    'confirm_schedule_candidate.cross_binding.request.json' => ['$.user_id', 'additional_property'],
    'confirm_schedule_candidate.missing_confirmation_token.request.json' => ['$.confirmation_token', 'required'],
    'confirm_schedule_candidate.missing_idempotency_key.request.json' => ['$.idempotency_key', 'required']
  }.freeze

  REASON_CODES = %w[
    NO_CONFLICT TRAVEL_BUFFER_OK STORE_OPEN PREFERRED_TIME_WINDOW ON_RETURN_ROUTE
    LOW_SCHEDULE_FRAGMENTATION DAILY_LOAD_ACCEPTABLE EXPLICIT_USER_PREFERENCE
    LEARNED_TIME_WINDOW_MATCH DURATION_FITS WITHIN_SEARCH_WINDOW
  ].freeze

  PENALTY_CODES = %w[
    LUNCH_WINDOW DAY_FRAGMENTATION EXTRA_TRAVEL NON_PREFERRED_TIME HIGH_DAILY_LOAD
    BACK_TO_BACK_EVENT TRAVEL_TIME_UNKNOWN OPENING_HOURS_UNKNOWN LOW_HISTORICAL_ACCEPTANCE
  ].freeze

  ERROR_CODES = %w[
    NO_FEASIBLE_SLOT LOCATION_REQUIRED TRAVEL_TIME_UNAVAILABLE OPENING_HOURS_UNAVAILABLE
    PROFILE_NOT_CONFIGURED INVALID_TIME_WINDOW INVALID_DURATION RECOMMENDATION_NOT_FOUND
    CANDIDATE_NOT_FOUND REVISION_NOT_FOUND RECOMMENDATION_EXPIRED STALE_SCHEDULE_SNAPSHOT
    CANDIDATE_NOT_FEASIBLE CONFLICT_DETECTED CONFIRMATION_REQUIRED INVALID_CONFIRMATION_TOKEN
    IDEMPOTENCY_CONFLICT SPECIALIST_TIMEOUT CONTRACT_INVALID OPERATION_NOT_ALLOWED
  ].freeze

  ERROR_MESSAGE_CODES = {
    'NO_FEASIBLE_SLOT' => 'NO_FEASIBLE_SLOT_AVAILABLE',
    'LOCATION_REQUIRED' => 'LOCATION_REQUIRED',
    'TRAVEL_TIME_UNAVAILABLE' => 'TRAVEL_TIME_UNAVAILABLE',
    'OPENING_HOURS_UNAVAILABLE' => 'OPENING_HOURS_UNAVAILABLE',
    'PROFILE_NOT_CONFIGURED' => 'PROFILE_NOT_CONFIGURED',
    'INVALID_TIME_WINDOW' => 'TIME_WINDOW_INVALID',
    'INVALID_DURATION' => 'DURATION_INVALID',
    'RECOMMENDATION_NOT_FOUND' => 'RECOMMENDATION_NOT_FOUND',
    'CANDIDATE_NOT_FOUND' => 'CANDIDATE_NOT_FOUND',
    'REVISION_NOT_FOUND' => 'REVISION_NOT_FOUND',
    'RECOMMENDATION_EXPIRED' => 'RECOMMENDATION_EXPIRED',
    'STALE_SCHEDULE_SNAPSHOT' => 'SCHEDULE_CHANGED_RETRY_REQUIRED',
    'CANDIDATE_NOT_FEASIBLE' => 'CANDIDATE_NOT_FEASIBLE',
    'CONFLICT_DETECTED' => 'SLOT_NO_LONGER_AVAILABLE',
    'CONFIRMATION_REQUIRED' => 'CONFIRMATION_REQUIRED',
    'INVALID_CONFIRMATION_TOKEN' => 'CONFIRMATION_TOKEN_INVALID',
    'IDEMPOTENCY_CONFLICT' => 'IDEMPOTENCY_KEY_CONFLICT',
    'SPECIALIST_TIMEOUT' => 'SPECIALIST_TIMEOUT',
    'CONTRACT_INVALID' => 'REQUEST_CONTRACT_INVALID',
    'OPERATION_NOT_ALLOWED' => 'OPERATION_NOT_ALLOWED'
  }.freeze

  OPERATION_ERROR_CODES = {
    'recommend_time_slots' => %w[
      NO_FEASIBLE_SLOT LOCATION_REQUIRED TRAVEL_TIME_UNAVAILABLE OPENING_HOURS_UNAVAILABLE
      PROFILE_NOT_CONFIGURED INVALID_TIME_WINDOW INVALID_DURATION SPECIALIST_TIMEOUT
      CONTRACT_INVALID OPERATION_NOT_ALLOWED
    ],
    'revise_time_slot' => %w[
      RECOMMENDATION_NOT_FOUND CANDIDATE_NOT_FOUND RECOMMENDATION_EXPIRED
      STALE_SCHEDULE_SNAPSHOT CANDIDATE_NOT_FEASIBLE CONFLICT_DETECTED LOCATION_REQUIRED
      TRAVEL_TIME_UNAVAILABLE OPENING_HOURS_UNAVAILABLE PROFILE_NOT_CONFIGURED
      INVALID_TIME_WINDOW INVALID_DURATION SPECIALIST_TIMEOUT CONTRACT_INVALID
      OPERATION_NOT_ALLOWED
    ],
    'confirm_schedule_candidate' => %w[
      RECOMMENDATION_NOT_FOUND CANDIDATE_NOT_FOUND REVISION_NOT_FOUND RECOMMENDATION_EXPIRED
      STALE_SCHEDULE_SNAPSHOT CANDIDATE_NOT_FEASIBLE CONFLICT_DETECTED CONFIRMATION_REQUIRED
      INVALID_CONFIRMATION_TOKEN IDEMPOTENCY_CONFLICT SPECIALIST_TIMEOUT CONTRACT_INVALID
      OPERATION_NOT_ALLOWED
    ],
    'reject_schedule_recommendation' => %w[
      RECOMMENDATION_NOT_FOUND RECOMMENDATION_EXPIRED SPECIALIST_TIMEOUT CONTRACT_INVALID
      OPERATION_NOT_ALLOWED
    ]
  }.transform_values(&:freeze).freeze

  RETRYABLE_ERROR_CODES = %w[
    TRAVEL_TIME_UNAVAILABLE OPENING_HOURS_UNAVAILABLE SPECIALIST_TIMEOUT
  ].freeze

  ERROR_DEFINITION_BY_OPERATION_AND_CODE = {
    ['recommend_time_slots', 'INVALID_TIME_WINDOW'] => 'INVALID_TIME_WINDOW_RECOMMEND',
    ['revise_time_slot', 'INVALID_TIME_WINDOW'] => 'INVALID_TIME_WINDOW_REVISE',
    ['recommend_time_slots', 'INVALID_DURATION'] => 'INVALID_DURATION_RECOMMEND',
    ['revise_time_slot', 'INVALID_DURATION'] => 'INVALID_DURATION_REVISE',
    ['recommend_time_slots', 'CONTRACT_INVALID'] => 'CONTRACT_INVALID_RECOMMEND',
    ['revise_time_slot', 'CONTRACT_INVALID'] => 'CONTRACT_INVALID_REVISE',
    ['confirm_schedule_candidate', 'CONTRACT_INVALID'] => 'CONTRACT_INVALID_CONFIRM',
    ['reject_schedule_recommendation', 'CONTRACT_INVALID'] => 'CONTRACT_INVALID_REJECT'
  }.freeze

  ERROR_DETAILS_SAMPLES = {
    'NO_FEASIBLE_SLOT' => { 'candidate_count' => 0 },
    'LOCATION_REQUIRED' => { 'required_reference' => 'location_preference_ref' },
    'TRAVEL_TIME_UNAVAILABLE' => { 'unknown_leg_count' => 1, 'retry_after_seconds' => 30 },
    'OPENING_HOURS_UNAVAILABLE' => { 'required_reference' => 'opening_hours', 'retry_after_seconds' => 30 },
    'PROFILE_NOT_CONFIGURED' => { 'missing_profile_keys' => ['working_hours'] },
    'INVALID_TIME_WINDOW_RECOMMEND' => { 'invalid_field_names' => ['search_window.start_at'] },
    'INVALID_TIME_WINDOW_REVISE' => { 'invalid_field_names' => ['proposed_slot.start_at'] },
    'INVALID_DURATION_RECOMMEND' => { 'invalid_field_names' => ['duration_minutes'] },
    'INVALID_DURATION_REVISE' => { 'invalid_field_names' => ['proposed_slot.duration_minutes'] },
    'RECOMMENDATION_NOT_FOUND' => { 'required_reference' => 'recommendation_id' },
    'CANDIDATE_NOT_FOUND' => { 'required_reference' => 'candidate_id' },
    'REVISION_NOT_FOUND' => { 'required_reference' => 'revision_id' },
    'RECOMMENDATION_EXPIRED' => { 'expired_at' => '2026-08-30T09:15:00+09:00' },
    'STALE_SCHEDULE_SNAPSHOT' => {
      'expected_schedule_snapshot_version' => 'sch_snapshot_0001',
      'current_schedule_snapshot_version' => 'sch_snapshot_0002'
    },
    'CANDIDATE_NOT_FEASIBLE' => { 'required_reference' => 'candidate_id' },
    'CONFLICT_DETECTED' => { 'conflicting_event_count' => 1 },
    'CONFIRMATION_REQUIRED' => { 'required_reference' => 'explicit_confirmation' },
    'INVALID_CONFIRMATION_TOKEN' => { 'required_reference' => 'confirmation_token' },
    'IDEMPOTENCY_CONFLICT' => { 'required_reference' => 'idempotency_key' },
    'SPECIALIST_TIMEOUT' => { 'retry_after_seconds' => 0 },
    'CONTRACT_INVALID' => { 'invalid_field_names' => ['operation'] },
    'CONTRACT_INVALID_RECOMMEND' => { 'invalid_field_names' => ['search_window.start_at'] },
    'CONTRACT_INVALID_REVISE' => { 'invalid_field_names' => ['proposed_slot.start_at'] },
    'CONTRACT_INVALID_CONFIRM' => { 'invalid_field_names' => ['revision_id'] },
    'CONTRACT_INVALID_REJECT' => { 'invalid_field_names' => ['action'] },
    'OPERATION_NOT_ALLOWED' => { 'required_reference' => 'operation' }
  }.freeze

  ERROR_REQUIRED_DETAIL_KEYS = {
    'NO_FEASIBLE_SLOT' => %w[candidate_count],
    'LOCATION_REQUIRED' => %w[required_reference],
    'TRAVEL_TIME_UNAVAILABLE' => %w[unknown_leg_count],
    'OPENING_HOURS_UNAVAILABLE' => %w[required_reference],
    'PROFILE_NOT_CONFIGURED' => %w[missing_profile_keys],
    'INVALID_TIME_WINDOW_RECOMMEND' => %w[invalid_field_names],
    'INVALID_TIME_WINDOW_REVISE' => %w[invalid_field_names],
    'INVALID_DURATION_RECOMMEND' => %w[invalid_field_names],
    'INVALID_DURATION_REVISE' => %w[invalid_field_names],
    'RECOMMENDATION_NOT_FOUND' => %w[required_reference],
    'CANDIDATE_NOT_FOUND' => %w[required_reference],
    'REVISION_NOT_FOUND' => %w[required_reference],
    'RECOMMENDATION_EXPIRED' => %w[expired_at],
    'STALE_SCHEDULE_SNAPSHOT' => %w[expected_schedule_snapshot_version current_schedule_snapshot_version],
    'CANDIDATE_NOT_FEASIBLE' => %w[required_reference],
    'CONFLICT_DETECTED' => %w[conflicting_event_count],
    'CONFIRMATION_REQUIRED' => %w[required_reference],
    'INVALID_CONFIRMATION_TOKEN' => %w[required_reference],
    'IDEMPOTENCY_CONFLICT' => %w[required_reference],
    'SPECIALIST_TIMEOUT' => %w[retry_after_seconds],
    'CONTRACT_INVALID' => %w[invalid_field_names],
    'CONTRACT_INVALID_RECOMMEND' => %w[invalid_field_names],
    'CONTRACT_INVALID_REVISE' => %w[invalid_field_names],
    'CONTRACT_INVALID_CONFIRM' => %w[invalid_field_names],
    'CONTRACT_INVALID_REJECT' => %w[invalid_field_names],
    'OPERATION_NOT_ALLOWED' => %w[required_reference]
  }.transform_values(&:freeze).freeze

  EXPECTED_RECOMMEND_INPUTS = {
    'task_title' => ['MODEL_VISIBLE_USER_DERIVED', true, true, 'title'],
    'task_category' => ['PHASE_1_DEFERRED', false, false, nil],
    'duration' => ['MODEL_VISIBLE_USER_DERIVED', true, true, 'duration_minutes'],
    'location_preference_reference' => ['SERVER_BOUND_PROFILE_CONTEXT', false, false, nil],
    'search_window' => ['MODEL_VISIBLE_USER_DERIVED', true, true, 'search_window'],
    'timezone' => ['SERVER_INJECTED', false, false, 'time_zone'],
    'minimum_buffer' => ['SERVER_BOUND_PROFILE_CONTEXT', false, false, nil],
    'lunch_protection' => ['SERVER_BOUND_PROFILE_CONTEXT', false, false, nil],
    'return_route_preference' => ['SERVER_BOUND_RANKING_CONTEXT', false, false, nil],
    'top_k' => ['SERVER_POLICY', false, false, nil]
  }.freeze

  MODEL_TOOL_REFS = {
    'recommend_time_slots' => %w[recommendTimeSlotsArguments recommendTimeSlotsResult],
    'revise_time_slot' => %w[reviseTimeSlotArguments reviseTimeSlotResult],
    'confirm_schedule_candidate' => %w[confirmScheduleCandidateArguments confirmScheduleCandidateResult],
    'reject_schedule_recommendation' => %w[rejectScheduleRecommendationArguments rejectScheduleRecommendationResult]
  }.freeze

  EXPECTED_TOOL_MANIFEST_FIELDS = {
    'recommend_time_slots' => {
      'model_visible_arguments' => %w[title duration_minutes search_window],
      'adapter_injected_fields' => %w[
        schema_version operation request_id trace_id time_zone schedule_snapshot_version
      ],
      'vault_write_fields' => %w[
        recommendation_id candidates[].candidate_id candidates[].confirmation_token
        schedule_snapshot_version expires_at policy_version user_id workspace_id
      ],
      'vault_only_fields' => %w[
        confirmation_token schedule_snapshot_version policy_version user_id workspace_id
      ],
      'redacted_fields' => %w[
        schema_version operation request_id trace_id candidates[].recommendation_id
        candidates[].feasible candidates[].confirmation_token schedule_snapshot_version
        policy_version generated_at constraint_policy error.details
      ],
      'model_visible_projection' => {
        'success' => %w[
          status recommendation_id expires_at candidates[].candidate_id candidates[].rank
          candidates[].slot candidates[].reason_codes candidates[].penalty_codes candidates[].score
        ],
        'error' => %w[status code message_code retryable]
      }
    },
    'revise_time_slot' => {
      'model_visible_arguments' => %w[
        recommendation_id candidate_id proposed_slot optional_change_reason
      ],
      'adapter_injected_fields' => %w[
        schema_version operation request_id trace_id schedule_snapshot_version
      ],
      'vault_write_fields' => %w[
        recommendation_id candidate_id revision_id confirmation_token schedule_snapshot_version
        expires_at user_id workspace_id
      ],
      'vault_only_fields' => %w[
        confirmation_token schedule_snapshot_version user_id workspace_id
      ],
      'redacted_fields' => %w[
        schema_version operation request_id trace_id confirmation_token schedule_snapshot_version
        constraint_policy error.details
      ],
      'model_visible_projection' => {
        'success' => %w[
          status recommendation_id candidate_id revision_id expires_at
          revised_candidate.recommendation_id revised_candidate.candidate_id
          revised_candidate.revision_id revised_candidate.rank revised_candidate.feasible
          revised_candidate.slot revised_candidate.reason_codes revised_candidate.penalty_codes
          revised_candidate.score requires_confirmation
        ],
        'error' => %w[status code message_code retryable]
      }
    },
    'confirm_schedule_candidate' => {
      'model_visible_arguments' => %w[recommendation_id candidate_id revision_id],
      'adapter_injected_fields' => %w[
        schema_version operation request_id trace_id schedule_snapshot_version confirmation_token idempotency_key
      ],
      'vault_write_fields' => %w[
        confirmation_evidence confirmation_evidence_id confirmation_token_consumption_state
        logical_confirmation_attempt logical_attempt_id idempotency_key schedule_snapshot_version
        idempotency_state event_id feedback_event_id user_id workspace_id
      ],
      'vault_only_fields' => %w[
        confirmation_evidence confirmation_evidence_id confirmation_token logical_confirmation_attempt
        logical_attempt_id schedule_snapshot_version idempotency_key idempotency_state event_id
        feedback_event_id user_id workspace_id
      ],
      'redacted_fields' => %w[
        schema_version operation request_id trace_id confirmation_evidence confirmation_evidence_id
        confirmation_token logical_confirmation_attempt logical_attempt_id schedule_snapshot_version
        idempotency_key idempotency_state event_id feedback_event_id committed_at error.details
      ],
      'model_visible_projection' => {
        'success' => %w[status recommendation_id candidate_id revision_id final_slot],
        'error' => %w[status code message_code retryable]
      },
      'adapter_sequence' => %w[
        validate_model_visible_arguments bind_authenticated_tenant lookup_exact_confirmation_evidence
        verify_evidence_binding_and_status lookup_existing_logical_attempt
        replay_stored_terminal_result_if_present atomic_get_or_create_logical_attempt
        retrieve_existing_idempotency_key lookup_confirmation_token build_specialist_wire_request
        validate_specialist_wire_request dispatch_specialist_request validate_specialist_response
        stage_terminal_result_for_atomic_commit
        atomically_store_result_event_feedback_snapshot_and_consume_token_evidence
        build_token_free_projection validate_model_visible_result
      ]
    },
    'reject_schedule_recommendation' => {
      'model_visible_arguments' => %w[recommendation_id action optional_reason],
      'adapter_injected_fields' => %w[schema_version operation request_id trace_id],
      'vault_write_fields' => %w[feedback_event_id user_id workspace_id],
      'vault_only_fields' => %w[feedback_event_id user_id workspace_id],
      'redacted_fields' => %w[
        schema_version operation request_id trace_id feedback_event_id recorded_at error.details
      ],
      'model_visible_projection' => {
        'success' => %w[status recommendation_id action],
        'error' => %w[status code message_code retryable]
      }
    }
  }.freeze

  FORBIDDEN_MODEL_VISIBLE_FIELDS = %w[
    confirmation_evidence confirmation_evidence_id confirmation_token logical_confirmation_attempt
    logical_attempt_id schedule_snapshot_version idempotency_key idempotency_state user_id workspace_id
    authorization cookie access_token refresh_token api_key secret feedback_event_id event_id
  ].freeze

  VAULT_ONLY_INTERNAL_CONCEPTS = %w[
    confirmation_evidence confirmation_evidence_id logical_confirmation_attempt
    logical_attempt_id idempotency_state
  ].freeze

  SEMANTIC_INVARIANT_IDS = (1..18).map { |number| format('SR-SEM-%03d', number) }.freeze
  SEMANTIC_VALIDATORS = {
    'SR-SEM-001' => 'search_window_order',
    'SR-SEM-002' => 'recommendation_expiry_order',
    'SR-SEM-003' => 'slot_order',
    'SR-SEM-004' => 'slot_duration',
    'SR-SEM-005' => 'candidate_id_uniqueness',
    'SR-SEM-006' => 'candidate_rank_sequence',
    'SR-SEM-007' => 'candidate_recommendation_binding',
    'SR-SEM-008' => 'revised_recommendation_binding',
    'SR-SEM-009' => 'revised_candidate_binding',
    'SR-SEM-010' => 'revised_revision_binding',
    'SR-SEM-011' => 'exchange_correlation_binding',
    'SR-SEM-012' => 'revision_expiry_binding',
    'SR-SEM-013' => 'confirm_identifier_binding',
    'SR-SEM-014' => 'committed_snapshot_transition',
    'SR-SEM-015' => 'confirm_final_slot_binding',
    'SR-SEM-016' => 'reject_response_binding',
    'SR-SEM-017' => 'error_correlation_binding',
    'SR-SEM-018' => 'recommend_timezone_offset_alignment'
  }.freeze

  REQUEST_OPERATIONS = {
    'recommend_time_slots.request.schema.json' => 'recommend_time_slots',
    'revise_time_slot.request.schema.json' => 'revise_time_slot',
    'confirm_schedule_candidate.request.schema.json' => 'confirm_schedule_candidate',
    'reject_schedule_recommendation.request.schema.json' => 'reject_schedule_recommendation'
  }.freeze

  FORBIDDEN_REQUEST_FIELDS = %w[
    user_id workspace_id authorization api_key home_address office_address raw_profile
    database_id cookie access_token refresh_token secret
  ].freeze

  STATES = %w[
    generated presented selected edited revalidated confirmed committed infeasible
    rejected dismissed stale expired
  ].freeze

  TRANSITIONS = [
    %w[generated presented],
    %w[presented selected],
    %w[presented edited],
    %w[presented rejected],
    %w[presented dismissed],
    %w[presented stale],
    %w[presented expired],
    %w[selected revalidated],
    %w[selected expired],
    %w[edited revalidated],
    %w[edited expired],
    %w[revalidated confirmed],
    %w[revalidated infeasible],
    %w[confirmed committed]
  ].freeze

  FORBIDDEN_TRANSITIONS = %w[
    generated presented selected edited revalidated infeasible expired stale
  ].map { |from| [from, 'committed'] }.freeze

  FEEDBACK_ACTIONS = %w[
    accepted_as_is selected_alternative edited_and_accepted rejected_all dismissed
    cancelled_after_creation completed
  ].freeze

  NORMATIVE_IDS = {
    'integration_contract.md' => %w[
      SR-ID-001 SR-PERSIST-001 SR-PERSIST-002 SR-CONFIRM-001 SR-IDEMPOTENCY-001
      SR-IDEMPOTENCY-002 SR-SNAPSHOT-001 SR-TOOL-001 SR-TOOL-002 SR-FLAG-001
      SR-SEMANTIC-001 SR-ERROR-001 SR-ERROR-002 SR-TOOL-003 SR-TOOL-004
      SR-VAULT-001 SR-UI-001 SR-INPUT-001
      SR-CONFIRM-002 SR-CONFIRM-003 SR-IDEMPOTENCY-003 SR-IDEMPOTENCY-004
      SR-IDEMPOTENCY-005 SR-TIME-001 SR-TIMEZONE-001 SR-DATA-001 SR-ERROR-003
      SR-STRING-001 SR-SEMANTIC-002
    ],
    'state_machine.md' => %w[SR-STATE-001 SR-STATE-002 SR-STATE-003 SR-STATE-004],
    'feedback_learning.md' => %w[
      SR-FEEDBACK-001 SR-FEEDBACK-002 SR-FEEDBACK-003 SR-FEEDBACK-004 SR-FEEDBACK-005
      SR-FEEDBACK-006 SR-FEEDBACK-007
    ],
    'privacy_and_logging.md' => %w[
      SR-PRIVACY-001 SR-PRIVACY-002 SR-PRIVACY-003 SR-PRIVACY-004
      SR-PRIVACY-005 SR-PRIVACY-006 SR-PRIVACY-007
    ]
  }.freeze

  FEATURE_FLAGS = %w[
    SCHEDULING_RECOMMENDATIONS_ENABLED=off
    SCHEDULING_FEEDBACK_LOGGING_ENABLED=off
    SCHEDULING_LEARNED_RANKING_ENABLED=off
    SCHEDULING_ROUTE_CONSTRAINTS_ENABLED=off
  ].freeze

  def setup
    @validator = SchedulingRecommendationsV1SubsetValidator.new(SCHEMA_ROOT, schema_names: SCHEMA_FILES)
    @semantic_validator = SchedulingRecommendationsV1SemanticValidator.new(
      contract_data('semantic_invariants.json').fetch('invariants')
    )
    @test_schema_documents = {}
  end

  test 'all contract schemas and fixtures are valid JSON and every schema audits fail closed' do
    actual_json_files = Dir[SCHEMA_ROOT.join('*.json').to_s] + Dir[FIXTURE_ROOT.join('**', '*.json').to_s]
    assert_equal expected_json_files.map(&:to_s).sort, actual_json_files.sort
    assert_equal 62, actual_json_files.length
    expected_json_files.each do |path|
      bytes = File.binread(path)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      assert text.valid_encoding?, "#{path} is not valid UTF-8"
      assert_nothing_raised { JSON.parse(text) }
    end

    SCHEMA_FILES.each do |schema_name|
      assert @validator.audit!(schema_name), schema_name
    end
  end

  test 'all seven machine-readable contract documents validate against closed fragments' do
    assert_equal '2.5.0', JSONSchemer::VERSION
    assert_empty JSONSchemer.validate_schema(schema_json('contract_data.schema.json')).to_a

    CONTRACT_DATA_DEFS.each do |file_name, definition_name|
      instance = contract_data(file_name)
      reference = "#/$defs/#{definition_name}"
      assert @validator.valid_ref?('contract_data.schema.json', reference, instance), file_name
      assert json_schemer_valid_ref?('contract_data.schema.json', reference, instance), file_name
    end
  end

  test 'in-memory contract data mutations close shape vocabulary identity counts and refs' do
    mutations = contract_data_mutations
    assert_equal 82, mutations.length

    mutations.each do |mutation|
      reference = "#/$defs/#{CONTRACT_DATA_DEFS.fetch(mutation.fetch(:file))}"
      error = assert_raises(
        SchedulingRecommendationsV1SubsetValidator::ContractValidationError,
        mutation.fetch(:id)
      ) do
        @validator.validate_ref!('contract_data.schema.json', reference, mutation.fetch(:instance))
      end
      flattened = error.flattened
      assert flattened.any? { |failure| failure.path }, "#{mutation.fetch(:id)} missing error path/category"
      refute json_schemer_valid_ref?(
        'contract_data.schema.json', reference, mutation.fetch(:instance)
      ), "JSONSchemer accepted #{mutation.fetch(:id)}"
    end
  end

  test 'the subset validator rejects unsupported schema keywords instead of ignoring them' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      write_temp_schema(
        directory, 'unsupported.schema.json',
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/unsupported.schema.json',
        'type' => 'string',
        'minLength' => 1,
        'unsupportedAssertion' => true
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: ['unsupported.schema.json']
      )
      error = assert_raises(SchedulingRecommendationsV1SubsetValidator::ContractValidationError) do
        validator.audit!('unsupported.schema.json')
      end
      assert_equal 'unknown_keyword', error.code
    end
  end

  test 'all schema documents select Draft 2020-12 and instance envelopes fix schema version 1.0' do
    SCHEMA_FILES.each do |schema_name|
      schema = schema_json(schema_name)
      assert_equal SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
                   schema['$schema'], schema_name
    end

    request_and_response_schema_names.each do |schema_name|
      assert schema_contains_const?(schema_name, 'schema_version', '1.0'),
             "#{schema_name} must close schema_version to 1.0"
    end
  end

  test 'public request operation constants are exact and feedback recording is not a public operation' do
    REQUEST_OPERATIONS.each do |schema_name, operation|
      assert schema_contains_const?(schema_name, 'operation', operation), schema_name
    end

    declared = REQUEST_OPERATIONS.keys.flat_map { |name| property_consts(name, 'operation') }
    assert_equal REQUEST_OPERATIONS.values.sort, declared.sort
    refute_includes declared, 'record_scheduling_feedback'
  end

  test 'all valid fixtures satisfy their corresponding closed schema' do
    VALID_FIXTURES.each do |fixture_name, schema_name|
      assert @validator.valid?(schema_name, valid_fixture(fixture_name)), fixture_name
      assert json_schemer_valid?(schema_name, valid_fixture(fixture_name)),
             "JSONSchemer #{fixture_name}"
    end
  end

  test 'all invalid fixtures are rejected by their corresponding schema' do
    assert_equal INVALID_FIXTURES.keys.sort, INVALID_FIXTURE_EXPECTATIONS.keys.sort
    INVALID_FIXTURES.each do |fixture_name, schema_name|
      error = assert_raises(SchedulingRecommendationsV1SubsetValidator::ContractValidationError) do
        @validator.validate!(schema_name, invalid_fixture(fixture_name))
      end
      expected = INVALID_FIXTURE_EXPECTATIONS.fetch(fixture_name)
      actual = error.flattened.map { |entry| [entry.path, entry.code] }
      assert_includes actual, expected, "#{fixture_name}: #{actual.inspect}"
      refute json_schemer_valid?(schema_name, invalid_fixture(fixture_name)),
             "JSONSchemer accepted #{fixture_name}"
    end
  end

  test 'unknown error and disclosure fixtures become valid after repairing only their named defect' do
    unknown = deep_copy(invalid_fixture('revise_time_slot.unknown_error_code.response.json'))
    unknown.fetch('error')['code'] = 'CANDIDATE_NOT_FEASIBLE'
    assert @validator.valid?('revise_time_slot.response.schema.json', unknown)

    repairs = {
      'error.conflict_with_missing_profile_keys.json' => 'missing_profile_keys',
      'error.invalid_token_with_conflicting_event_count.json' => 'conflicting_event_count',
      'error.profile_with_expired_at.json' => 'expired_at'
    }
    repairs.each do |fixture_name, extra_key|
      payload = deep_copy(invalid_fixture(fixture_name))
      payload.fetch('details').delete(extra_key)
      assert @validator.valid?('error.schema.json', payload),
             "#{fixture_name} has another failure besides #{extra_key}"
    end
  end

  test 'root envelopes reject unknown properties and a missing required property' do
    VALID_FIXTURES.each do |fixture_name, schema_name|
      payload = deep_copy(valid_fixture(fixture_name))
      payload['unexpected_contract_field'] = true
      refute @validator.valid?(schema_name, payload), "unknown field accepted by #{fixture_name}"
    end

    payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
    payload.delete('schema_version')
    refute @validator.valid?('recommend_time_slots.request.schema.json', payload)
  end

  test 'success and error envelopes are disjoint and preserve Event persistence boundaries' do
    mutations = [
      [
        'recommend error plus candidates', 'recommend_time_slots.response.schema.json',
        'recommend_time_slots.no_feasible_slot.response.json',
        ->(payload) { payload['candidates'] = deep_copy(valid_fixture('recommend_time_slots.response.json')['candidates']) }
      ],
      [
        'reject error plus feedback id', 'reject_schedule_recommendation.response.schema.json',
        'reject_schedule_recommendation.not_found.response.json',
        ->(payload) { payload['feedback_event_id'] = 'fb_schedule_9999' }
      ],
      [
        'reject recorded plus error', 'reject_schedule_recommendation.response.schema.json',
        'reject_schedule_recommendation.response.json',
        ->(payload) { payload['error'] = sample_error('RECOMMENDATION_NOT_FOUND') }
      ],
      [
        'revise error plus revised candidate', 'revise_time_slot.response.schema.json',
        'revise_time_slot.infeasible.response.json',
        lambda do |payload|
          payload['revised_candidate'] = deep_copy(
            valid_fixture('revise_time_slot.feasible.response.json')['revised_candidate']
          )
        end
      ],
      [
        'confirm error plus event id', 'confirm_schedule_candidate.response.schema.json',
        'confirm_schedule_candidate.expired.response.json',
        ->(payload) { payload['event_id'] = 'evt_schedule_9999' }
      ]
    ]
    mutations.each do |label, schema_name, fixture_name, mutation|
      payload = deep_copy(valid_fixture(fixture_name))
      mutation.call(payload)
      error = assert_raises(SchedulingRecommendationsV1SubsetValidator::ContractValidationError) do
        @validator.validate!(schema_name, payload)
      end
      assert_includes error.flattened.map(&:code), 'additional_property', label
    end
  end

  test 'every object-shaped instance schema is closed with additionalProperties false' do
    SCHEMA_FILES.each do |schema_name|
      assert_closed_object_schemas(schema_json(schema_name), schema_name)
    end
  end

  test 'request contracts exclude client supplied identity secrets and cross-binding fields' do
    REQUEST_OPERATIONS.each_key do |schema_name|
      declared = all_declared_property_names(schema_json(schema_name))
      FORBIDDEN_REQUEST_FIELDS.each do |field|
        refute_includes declared, field, "#{schema_name} declares forbidden #{field}"
      end
    end

    refute @validator.valid?(
      'confirm_schedule_candidate.request.schema.json',
      invalid_fixture('confirm_schedule_candidate.cross_binding.request.json')
    )
  end

  test 'reason penalty and error code registries are exact closed string enums' do
    assert_registry('reason_codes.json', REASON_CODES)
    assert_registry('penalty_codes.json', PENALTY_CODES)
    assert_registry('error_codes.json', ERROR_CODES)
  end

  test 'recommend and every revise response disclose the server-owned travel-time policy' do
    recommend = valid_fixture('recommend_time_slots.response.json')
    feasible_revision = valid_fixture('revise_time_slot.feasible.response.json')
    infeasible_revision = valid_fixture('revise_time_slot.infeasible.response.json')

    [recommend, feasible_revision, infeasible_revision].each do |response|
      assert_includes %w[strict advisory], response.dig('constraint_policy', 'travel_time_unknown')
    end
  end

  test 'integration contract fixes every error to its public message code' do
    mapping = machine_json('integration_contract.md') { |value| value.key?('error_message_codes') }
    assert_equal '1.0', mapping['schema_version']
    assert_equal ERROR_MESSAGE_CODES, mapping.fetch('error_message_codes')

    error_schema = schema_json('error.schema.json')
    branch_mapping = error_schema.fetch('$defs').each_with_object({}) do |(_name, branch), result|
      properties = branch.fetch('properties')
      code = properties.fetch('code').fetch('const')
      message_code = properties.fetch('message_code').fetch('const')
      assert_equal result.fetch(code, message_code), message_code, "inconsistent message mapping for #{code}"
      result[code] = message_code
    end
    assert_equal ERROR_MESSAGE_CODES, branch_mapping
  end

  test 'operation error matrix and every response schema expose exactly their applicable errors' do
    matrix = contract_data('operation_error_matrix.json')
    assert_equal '1.0', matrix['schema_version']
    assert_equal OPERATION_ERROR_CODES, matrix.fetch('operation_error_codes')

    OPERATION_ERROR_CODES.each do |operation, allowed_codes|
      schema_name = "#{operation}.response.schema.json"
      assert_equal allowed_codes.sort, response_error_codes(schema_name).sort, schema_name

      allowed_codes.each do |code|
        payload = wire_error_response(operation, sample_error(error_definition_for(operation, code)))
        assert @validator.valid?(schema_name, payload), "#{operation} must accept #{code}"
      end
      (ERROR_CODES - allowed_codes).each do |code|
        payload = wire_error_response(operation, sample_error(error_definition_for(nil, code)))
        refute @validator.valid?(schema_name, payload), "#{operation} accepted non-applicable #{code}"
      end
    end
  end

  test 'error branches close retryability required details and disclosure keys by code' do
    definitions = schema_json('error.schema.json').fetch('$defs')
    assert_equal ERROR_DETAILS_SAMPLES.keys.sort, definitions.keys.sort

    definitions.each do |definition_name, branch|
      properties = branch.fetch('properties')
      code = properties.fetch('code').fetch('const')
      assert_equal ERROR_MESSAGE_CODES.fetch(code), properties.fetch('message_code').fetch('const')
      assert_equal RETRYABLE_ERROR_CODES.include?(code), properties.fetch('retryable').fetch('const')
      assert_equal false, branch['additionalProperties'], definition_name
      assert_equal %w[code details message_code retryable].sort, branch.fetch('required').sort, definition_name

      details_schema = properties.fetch('details')
      assert_equal false, details_schema['additionalProperties'], definition_name
      assert_equal ERROR_DETAILS_SAMPLES.fetch(definition_name).keys.sort,
                   details_schema.fetch('properties').keys.sort, definition_name
      assert_equal ERROR_REQUIRED_DETAIL_KEYS.fetch(definition_name).sort,
                   details_schema.fetch('required').sort, definition_name

      valid_error = sample_error(definition_name)
      assert @validator.valid?('error.schema.json', valid_error), definition_name

      retryable_mismatch = deep_copy(valid_error)
      retryable_mismatch['retryable'] = !retryable_mismatch.fetch('retryable')
      refute @validator.valid?('error.schema.json', retryable_mismatch), "free retryable for #{definition_name}"

      wrong_detail = deep_copy(valid_error)
      wrong_detail.fetch('details')['unrelated_disclosure'] = true
      refute @validator.valid?('error.schema.json', wrong_detail), "open details for #{definition_name}"

      ERROR_REQUIRED_DETAIL_KEYS.fetch(definition_name).each do |required_key|
        missing_detail = deep_copy(valid_error)
        missing_detail.fetch('details').delete(required_key)
        refute @validator.valid?('error.schema.json', missing_detail),
               "#{definition_name} accepted without #{required_key}"
      end
    end
  end

  test 'error adversarial values reject wrong mappings counts arrays and timestamps' do
    mutations = []
    mutations << mutate_error('CONFLICT_DETECTED') { |error| error['details']['conflicting_event_count'] = -1 }
    mutations << mutate_error('TRAVEL_TIME_UNAVAILABLE') { |error| error['details']['unknown_leg_count'] = 0 }
    mutations << mutate_error('PROFILE_NOT_CONFIGURED') { |error| error['details']['missing_profile_keys'] = [] }
    mutations << mutate_error('PROFILE_NOT_CONFIGURED') do |error|
      error['details']['missing_profile_keys'] = %w[working_hours working_hours]
    end
    mutations << mutate_error('RECOMMENDATION_EXPIRED') do |error|
      error['details']['expired_at'] = '2026-08-30T09:15:00'
    end
    mutations << mutate_error('INVALID_CONFIRMATION_TOKEN') do |error|
      error['details'] = { 'required_reference' => 'confirmation_token', 'conflicting_event_count' => 1 }
    end
    mutations << mutate_error('CONFLICT_DETECTED') do |error|
      error['details'] = { 'conflicting_event_count' => 1, 'missing_profile_keys' => ['office_location'] }
    end
    mutations << mutate_error('PROFILE_NOT_CONFIGURED') do |error|
      error['details'] = {
        'missing_profile_keys' => ['working_hours'], 'expired_at' => '2026-08-30T09:15:00+09:00'
      }
    end
    mutations << mutate_error('INVALID_DURATION_RECOMMEND') do |error|
      error['details'] = { 'invalid_field_names' => ['duration_minutes'], 'retry_after_seconds' => 1 }
    end
    mutations << mutate_error('SPECIALIST_TIMEOUT') do |error|
      error['details'] = { 'retry_after_seconds' => 1, 'missing_profile_keys' => ['working_hours'] }
    end
    mutations << mutate_error('SPECIALIST_TIMEOUT') { |error| error.delete('retryable') }
    mutations << mutate_error('SPECIALIST_TIMEOUT') { |error| error['retryable'] = 'true' }
    mutations << mutate_error('NO_FEASIBLE_SLOT') { |error| error['message_code'] = 'LOCATION_REQUIRED' }
    mutations << mutate_error('NO_FEASIBLE_SLOT') { |error| error['code'] = 'UNKNOWN_ERROR' }

    mutations.each_with_index do |payload, index|
      refute @validator.valid?('error.schema.json', payload), "error mutation #{index} was accepted"
    end
  end

  test 'CONTRACT_INVALID exposes only the operation safe field matrix' do
    matrix = contract_data('contract_invalid_field_matrix.json')
    assert_equal %w[schema_version operation request_id trace_id], matrix.fetch('common_safe_fields')
    assert_equal CONTRACT_INVALID_SAFE_FIELDS, matrix.fetch('operation_safe_fields')
    assert_equal CONTRACT_INVALID_SAFE_FIELDS.values.flatten.uniq,
                 matrix.fetch('global_safe_fields')
    assert_empty matrix.fetch('global_safe_fields') & matrix.fetch('forbidden_fields')
    assert_operator matrix.fetch('forbidden_fields').length, :>=, 25

    global_definition = schema_json('error.schema.json').fetch('$defs').fetch('CONTRACT_INVALID')
    global_enum = global_definition.dig('properties', 'details', 'properties', 'invalid_field_names', 'items', 'enum')
    assert_equal matrix.fetch('global_safe_fields').sort, global_enum.sort

    CONTRACT_INVALID_SAFE_FIELDS.each do |operation, safe_fields|
      definition_name = CONTRACT_INVALID_DEFINITION_BY_OPERATION.fetch(operation)
      definition = schema_json('error.schema.json').fetch('$defs').fetch(definition_name)
      operation_enum = definition.dig(
        'properties', 'details', 'properties', 'invalid_field_names', 'items', 'enum'
      )
      assert_equal safe_fields.sort, operation_enum.sort

      safe_fields.each do |safe_field|
        error = sample_error(definition_name)
        error['details']['invalid_field_names'] = [safe_field]
        response = wire_error_response(operation, error)
        assert @validator.valid?("#{operation}.response.schema.json", response),
               "#{operation} rejected safe field #{safe_field}"
        assert json_schemer_valid?("#{operation}.response.schema.json", response),
               "JSONSchemer rejected #{operation} safe field #{safe_field}"
      end

      (matrix.fetch('global_safe_fields') - safe_fields).each do |other_operation_field|
        error = sample_error(definition_name)
        error['details']['invalid_field_names'] = [other_operation_field]
        response = wire_error_response(operation, error)
        refute @validator.valid?("#{operation}.response.schema.json", response),
               "#{operation} accepted cross-operation field #{other_operation_field}"
      end
    end

    matrix.fetch('forbidden_fields').each do |internal_field|
      root_error = sample_error('CONTRACT_INVALID')
      root_error['details']['invalid_field_names'] = [internal_field]
      refute @validator.valid?('error.schema.json', root_error), "root accepted #{internal_field}"
      refute json_schemer_valid?('error.schema.json', root_error), "JSONSchemer root accepted #{internal_field}"

      CONTRACT_INVALID_DEFINITION_BY_OPERATION.each do |operation, definition_name|
        error = sample_error(definition_name)
        error['details']['invalid_field_names'] = [internal_field]
        response = wire_error_response(operation, error)
        refute @validator.valid?("#{operation}.response.schema.json", response),
               "#{operation} accepted #{internal_field}"
        refute json_schemer_valid?("#{operation}.response.schema.json", response),
               "JSONSchemer #{operation} accepted #{internal_field}"
      end
    end
  end

  test 'recommend input ownership is an exact one-to-one classification of all ten inputs' do
    ownership = contract_data('recommend_input_ownership.json')
    assert_equal '1.0', ownership['schema_version']
    inputs = ownership.fetch('inputs')
    assert_equal 10, inputs.length
    assert_equal inputs.map { |entry| entry.fetch('input') }.uniq.length, inputs.length

    actual = inputs.to_h do |entry|
      [entry.fetch('input'), [entry.fetch('ownership'), entry.fetch('model_supplied'),
                              entry.fetch('model_visible'), entry['wire_path']]]
    end
    assert_equal EXPECTED_RECOMMEND_INPUTS, actual
    assert_equal 'closed category vocabulary not frozen',
                 inputs.find { |entry| entry['input'] == 'task_category' }.fetch('reason')
    top_k = inputs.find { |entry| entry['input'] == 'top_k' }
    assert_equal 3, top_k.fetch('default')
    assert_equal 20, top_k.fetch('structural_maximum')
  end

  test 'tool manifest has four resolvable public operations and closed secret-free model schemas' do
    manifest = contract_data('tool_manifest.json')
    assert_equal({
      'specialist_wire' => 'SERVER_TO_SERVER_ONLY',
      'model_visible' => 'CLOSED_MODEL_TOOL_PROJECTION',
      'server_vault' => 'TENANT_SCOPED_SERVER_ONLY',
      'browser_ui' => 'OPAQUE_IDENTIFIERS_ONLY'
    }, manifest.fetch('boundaries'))
    operations = manifest.fetch('public_operations')
    assert_equal MODEL_TOOL_REFS.keys, operations.map { |entry| entry.fetch('operation') }
    assert_equal ['record_scheduling_feedback'], manifest.fetch('internal_only_operations')
    assert_equal VAULT_ONLY_INTERNAL_CONCEPTS,
                 manifest.fetch('vault_only_internal_concepts')
    assert_equal FORBIDDEN_MODEL_VISIBLE_FIELDS.sort, manifest.fetch('forbidden_model_visible_fields').sort

    operations.each do |entry|
      operation = entry.fetch('operation')
      expected_defs = MODEL_TOOL_REFS.fetch(operation)
      assert_equal "model_tool.schema.json#/$defs/#{expected_defs[0]}", entry.fetch('arguments_schema_ref')
      assert_equal "model_tool.schema.json#/$defs/#{expected_defs[1]}", entry.fetch('result_schema_ref')
      EXPECTED_TOOL_MANIFEST_FIELDS.fetch(operation).each do |field, expected|
        assert_equal expected, entry.fetch(field), "#{operation} #{field}"
      end
    end

    operations.each do |entry|
      %w[arguments_schema_ref result_schema_ref].each do |reference_field|
        declared_model_fields = all_declared_property_names_for_ref(
          'model_tool.schema.json', entry.fetch(reference_field)
        ).map(&:downcase)
        FORBIDDEN_MODEL_VISIBLE_FIELDS.each do |field|
          refute_includes declared_model_fields, field,
                          "#{entry.fetch('operation')} #{reference_field} exposes #{field}"
        end
      end
    end


    definitions = schema_json('model_tool.schema.json').fetch('$defs')
    MODEL_TOOL_REFS.each do |operation, (arguments_name, _result_name)|
      assert_equal EXPECTED_TOOL_MANIFEST_FIELDS.fetch(operation).fetch('model_visible_arguments').sort,
                   definitions.fetch(arguments_name).fetch('properties').keys.sort,
                   "#{operation} argument property closure"
    end
    assert_equal %w[candidate_id penalty_codes rank reason_codes score slot].sort,
                 definitions.fetch('modelCandidate').fetch('properties').keys.sort
    assert_equal %w[
      candidate_id feasible penalty_codes rank reason_codes recommendation_id revision_id score slot
    ].sort, definitions.fetch('modelRevisedCandidate').fetch('properties').keys.sort
    {
      'recommendTimeSlotsSuccessResult' => %w[status recommendation_id expires_at candidates],
      'reviseTimeSlotSuccessResult' => %w[
        status recommendation_id candidate_id revision_id expires_at revised_candidate requires_confirmation
      ],
      'confirmScheduleCandidateSuccessResult' => %w[
        status recommendation_id candidate_id revision_id final_slot
      ],
      'rejectScheduleRecommendationSuccessResult' => %w[status recommendation_id action]
    }.each do |definition_name, expected_properties|
      assert_equal expected_properties.sort,
                   definitions.fetch(definition_name).fetch('properties').keys.sort,
                   definition_name
    end
  end

  test 'model-visible argument and result projections reject every server-owned or secret field mutation' do
    manifest_entries = contract_data('tool_manifest.json').fetch('public_operations').index_by do |entry|
      entry.fetch('operation')
    end
    model_argument_samples.each do |operation, payload|
      reference = manifest_entries.fetch(operation).fetch('arguments_schema_ref')
      assert @validator.valid_ref?('model_tool.schema.json', reference, payload), "#{operation} arguments"
    end
    model_result_samples.each do |operation, payload|
      reference = manifest_entries.fetch(operation).fetch('result_schema_ref')
      assert @validator.valid_ref?('model_tool.schema.json', reference, payload), "#{operation} result"
    end
    OPERATION_ERROR_CODES.each do |operation, codes|
      reference = manifest_entries.fetch(operation).fetch('result_schema_ref')
      codes.each do |code|
        wire_error = sample_error(error_definition_for(operation, code))
        model_error = pick_fields(wire_error, %w[code message_code retryable]).merge('status' => 'error')
        assert @validator.valid_ref?('model_tool.schema.json', reference, model_error),
               "#{operation} model error #{code}"
      end
      (ERROR_CODES - codes).each do |code|
        wire_error = sample_error(error_definition_for(nil, code))
        model_error = pick_fields(wire_error, %w[code message_code retryable]).merge('status' => 'error')
        refute @validator.valid_ref?('model_tool.schema.json', reference, model_error),
               "#{operation} model result accepted non-applicable #{code}"
      end
    end

    argument_mutations = [
      ['recommend_time_slots', 'user_id', 'usr_forbidden_0001'],
      ['recommend_time_slots', 'workspace_id', 'ws_forbidden_0001'],
      ['recommend_time_slots', 'authorization', 'Bearer forbidden'],
      ['confirm_schedule_candidate', 'confirmation_token', 'cnf_forbidden_candidate_0001'],
      ['confirm_schedule_candidate', 'idempotency_key', 'idem_forbidden_0001'],
      ['confirm_schedule_candidate', 'schedule_snapshot_version', 'sch_snapshot_0001']
    ]
    argument_mutations.each do |operation, field, value|
      payload = deep_copy(model_argument_samples.fetch(operation))
      payload[field] = value
      reference = manifest_entries.fetch(operation).fetch('arguments_schema_ref')
      refute @validator.valid_ref?('model_tool.schema.json', reference, payload),
             "#{operation} model arguments exposed #{field}"
    end

    result_mutations = [
      ['recommend_time_slots', 'confirmation_token', 'cnf_forbidden_candidate_0001'],
      ['recommend_time_slots', 'schedule_snapshot_version', 'sch_snapshot_0001'],
      ['confirm_schedule_candidate', 'event_id', 'evt_forbidden_0001']
    ]
    result_mutations.each do |operation, field, value|
      payload = deep_copy(model_result_samples.fetch(operation))
      payload[field] = value
      reference = manifest_entries.fetch(operation).fetch('result_schema_ref')
      refute @validator.valid_ref?('model_tool.schema.json', reference, payload),
             "#{operation} model result exposed #{field}"
    end

    nested_result_mutations = [
      ['recommend_time_slots', ['candidates', 0, 'confirmation_token'], 'cnf_forbidden_candidate_0001'],
      ['recommend_time_slots', ['candidates', 0, 'slot', 'event_id'], 'evt_forbidden_0001'],
      ['confirm_schedule_candidate', ['final_slot', 'schedule_snapshot_version'], 'sch_snapshot_0001']
    ]
    nested_result_mutations.each do |operation, path, value|
      payload = deep_copy(model_result_samples.fetch(operation))
      write_path(payload, path, value)
      reference = manifest_entries.fetch(operation).fetch('result_schema_ref')
      refute @validator.valid_ref?('model_tool.schema.json', reference, payload),
             "#{operation} model result exposed nested #{path.join('.')}"
    end
  end

  test 'date-time format requires an RFC 3339 timezone offset' do
    original = valid_fixture('recommend_time_slots.request.json')
    date_path = find_path(original) do |value, key|
      key.to_s.end_with?('_at') && value.is_a?(String) && value.include?('T')
    end
    assert date_path, 'recommend request needs a date-time field'

    [
      '2026-09-01T09:00:00',
      '2026-02-30T09:00:00Z',
      '2026-01-01T24:00:00Z',
      '2026-01-01T09:00:60Z',
      '2026-01-01T09:00:00+24:00'
    ].each do |invalid_date_time|
      payload = deep_copy(original)
      write_path(payload, date_path, invalid_date_time)
      refute @validator.valid?('recommend_time_slots.request.schema.json', payload), invalid_date_time
    end
  end

  test 'ChronoFlow date-time profile rejects leap seconds identically across validators' do
    reference = '#/$defs/dateTime'
    assert_equal 8, LEAP_SECOND_INVALID_DATE_TIMES.length
    assert_equal 6, NORMAL_SECOND_VALID_DATE_TIMES.length

    mismatches = []
    LEAP_SECOND_INVALID_DATE_TIMES.each do |value|
      subset = @validator.valid_ref?('common.schema.json', reference, value)
      standard = json_schemer_valid_ref?('common.schema.json', reference, value)
      mismatches << value unless subset == standard
      refute subset, "subset accepted #{value}"
      refute standard, "JSONSchemer accepted #{value}"
    end
    NORMAL_SECOND_VALID_DATE_TIMES.each do |value|
      subset = @validator.valid_ref?('common.schema.json', reference, value)
      standard = json_schemer_valid_ref?('common.schema.json', reference, value)
      mismatches << value unless subset == standard
      assert subset, "subset rejected #{value}"
      assert standard, "JSONSchemer rejected #{value}"
    end

    assert_empty mismatches, "cross-validator mismatches: #{mismatches.inspect}"
  end

  test 'leap-second fixture is invalid only at its timestamp seconds' do
    fixture_name = 'recommend_time_slots.leap_second.request.json'
    schema_name = INVALID_FIXTURES.fetch(fixture_name)
    payload = deep_copy(invalid_fixture(fixture_name))

    error = assert_raises(SchedulingRecommendationsV1SubsetValidator::ContractValidationError) do
      @validator.validate!(schema_name, payload)
    end
    failures = error.flattened.map { |entry| [entry.path, entry.code] }
    assert_includes failures, ['$.search_window.start_at', 'pattern']
    refute json_schemer_valid?(schema_name, payload)

    payload.fetch('search_window')['start_at'] = '2016-12-31T23:59:59Z'
    assert @validator.valid?(schema_name, payload)
    assert json_schemer_valid?(schema_name, payload)
    assert_empty @semantic_validator.validate_payload(payload)
  end

  test 'every wire date-time reference rejects leap-second values in both validators' do
    assert_equal 16, LEAP_SECOND_WIRE_PATHS.length

    LEAP_SECOND_WIRE_PATHS.each do |label, fixture_name, schema_name, path|
      payload = deep_copy(valid_fixture(fixture_name))
      original = path.reduce(payload) { |current, key| current.fetch(key) }
      write_path(payload, path, date_time_with_seconds(original, '60'))

      refute @validator.valid?(schema_name, payload), "subset #{label}"
      refute json_schemer_valid?(schema_name, payload), "JSONSchemer #{label}"
    end
  end

  test 'model-visible date-time references use the same leap-second-free profile' do
    manifest = contract_data('tool_manifest.json').fetch('public_operations').index_by do |entry|
      entry.fetch('operation')
    end
    assert_equal 12, LEAP_SECOND_MODEL_PATHS.length

    LEAP_SECOND_MODEL_PATHS.each do |label, kind, operation, path|
      samples = kind == :arguments ? model_argument_samples : model_result_samples
      reference_field = kind == :arguments ? 'arguments_schema_ref' : 'result_schema_ref'
      payload = deep_copy(samples.fetch(operation))
      original = path.reduce(payload) { |current, key| current.fetch(key) }
      write_path(payload, path, date_time_with_seconds(original, '60'))
      reference = manifest.fetch(operation).fetch(reference_field)
      fragment_reference = reference.delete_prefix('model_tool.schema.json')

      refute @validator.valid_ref?('model_tool.schema.json', reference, payload), "subset #{label}"
      refute json_schemer_valid_ref?('model_tool.schema.json', fragment_reference, payload),
             "JSONSchemer #{label}"
    end
  end

  test 'adjacent ordinary instants remain valid structurally and semantically' do
    cases = [
      ['UTC boundary', 'Etc/UTC', '2016-12-31T23:59:59Z', '2017-01-01T00:00:00Z'],
      ['offset boundary', 'America/Los_Angeles',
       '1990-12-31T15:59:59-08:00', '1990-12-31T16:00:00-08:00']
    ]

    cases.each do |label, zone, start_at, end_at|
      payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
      payload['time_zone'] = zone
      payload['search_window'] = { 'start_at' => start_at, 'end_at' => end_at }
      assert @validator.valid?('recommend_time_slots.request.schema.json', payload), "subset #{label}"
      assert json_schemer_valid?('recommend_time_slots.request.schema.json', payload),
             "JSONSchemer #{label}"
      assert_empty @semantic_validator.validate_payload(payload), label
    end
  end

  test 'integration contract defines the leap-second-free application profile' do
    integration = document_text('integration_contract.md')
    assert_includes integration, 'SR-TIME-001'
    assert_match(/seconds MUST be `00` through\s+`59`/, integration)
    assert_match(/`:60` representation is invalid/, integration)
    assert_match(/Specialist, adapter, and model-projection/, integration)
    assert_match(/MUST\s+NOT normalize/, integration)
    assert_match(/MUST NOT create an Event/, integration)
    assert_match(/MUST NOT finalize feedback/, integration)
    assert_match(/MUST NOT fall back to\s+an external API/, integration)
  end

  test 'timezone syntax is closed and accepted names exist in the local TZInfo registry' do
    schema_name = 'recommend_time_slots.request.schema.json'
    %w[Asia/Tokyo America/New_York Etc/UTC].each do |zone|
      payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
      payload['time_zone'] = zone
      assert @validator.valid?(schema_name, payload), zone
      assert_nothing_raised { TZInfo::Timezone.get(zone) }
    end

    ['Asia/Tokyo/', 'Asia/Tokyo//Foo', '/Asia/Tokyo', 'Asia//Tokyo', 'Asia/', 'Asia Tokyo'].each do |zone|
      payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
      payload['time_zone'] = zone
      refute @validator.valid?(schema_name, payload), zone
    end

    payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
    payload['time_zone'] = 'Mars/Olympus'
    assert @validator.valid?(schema_name, payload), 'unknown timezone mutation must isolate registry validation'
    assert_raises(TZInfo::InvalidTimezoneIdentifier) { TZInfo::Timezone.get(payload.fetch('time_zone')) }
  end

  test 'semantic timezone validation aligns each RFC 3339 offset to its IANA period' do
    cases = [
      ['Tokyo valid', 'Asia/Tokyo', '2026-09-01T09:00:00+09:00', '2026-09-01T10:00:00+09:00', true],
      ['Tokyo mismatch', 'Asia/Tokyo', '2026-09-01T09:00:00+00:00', '2026-09-01T10:00:00+00:00', false],
      ['New York winter valid', 'America/New_York', '2026-01-15T09:00:00-05:00', '2026-01-15T10:00:00-05:00', true],
      ['New York winter mismatch', 'America/New_York', '2026-01-15T09:00:00-04:00', '2026-01-15T10:00:00-04:00', false],
      ['New York summer valid', 'America/New_York', '2026-07-15T09:00:00-04:00', '2026-07-15T10:00:00-04:00', true],
      ['New York summer mismatch', 'America/New_York', '2026-07-15T09:00:00-05:00', '2026-07-15T10:00:00-05:00', false],
      ['New York DST transition', 'America/New_York', '2026-03-08T01:30:00-05:00', '2026-03-08T03:30:00-04:00', true],
      ['UTC Z valid', 'Etc/UTC', '2026-09-01T09:00:00Z', '2026-09-01T10:00:00Z', true]
    ]

    cases.each do |label, zone, start_at, end_at, expected|
      payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
      payload['time_zone'] = zone
      payload['search_window'] = { 'start_at' => start_at, 'end_at' => end_at }
      original = deep_copy(payload)
      failures = @semantic_validator.validate_payload(payload).select do |failure|
        failure.invariant_id == 'SR-SEM-018'
      end
      if expected
        assert_empty failures, label
      else
        refute_empty failures, label
        assert failures.all? { |failure| failure.error_code == 'INVALID_TIME_WINDOW' }, label
      end
      assert_equal original, payload, "#{label} must not rewrite offsets"
    end


    endpoint_cases = {
      'start only mismatch' => [
        '2026-09-01T00:00:00+00:00', '2026-09-01T10:00:00+09:00',
        '$.search_window.start_at'
      ],
      'end only mismatch' => [
        '2026-09-01T09:00:00+09:00', '2026-09-01T02:00:00+00:00',
        '$.search_window.end_at'
      ]
    }
    endpoint_cases.each do |label, (start_at, end_at, expected_path)|
      payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
      payload['time_zone'] = 'Asia/Tokyo'
      payload['search_window'] = { 'start_at' => start_at, 'end_at' => end_at }
      failures = @semantic_validator.validate_payload(payload).select do |failure|
        failure.invariant_id == 'SR-SEM-018'
      end
      assert_equal [expected_path], failures.map(&:path), label
      assert_equal ['INVALID_TIME_WINDOW'], failures.map(&:error_code), label
    end
  end

  test 'anchored identifier patterns reject embedded line matches' do
    [
      "garbage\nreq_abcdefgh",
      "req_abcdefgh\ngarbage",
      "garbage\nreq_abcdefgh\nmore"
    ].each do |invalid_request_id|
      payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
      payload['request_id'] = invalid_request_id
      refute @validator.valid?('recommend_time_slots.request.schema.json', payload), invalid_request_id.inspect
    end
  end

  test 'raw Schema patterns reject controls identically in subset validator and JSONSchemer' do
    valid_values = {
      'requestId' => 'req_abcdefgh',
      'traceId' => 'trc_abcdefgh',
      'recommendationId' => 'rec_abcdefgh',
      'candidateId' => 'cand_abcdefgh',
      'revisionId' => 'rev_abcdefgh',
      'confirmationToken' => 'cnf_abcdefghijklmnop',
      'idempotencyKey' => 'idem_abcdefgh',
      'eventId' => 'evt_abcdefgh',
      'feedbackEventId' => 'fb_abcdefgh',
      'scheduleSnapshotVersion' => 'sch_abcdefgh',
      'dateTime' => '2026-09-01T09:00:00+09:00',
      'timeZone' => 'Asia/Tokyo'
    }

    ABSOLUTE_STRING_DEFS.each do |definition_name|
      value = valid_values.fetch(definition_name)
      reference = "#/$defs/#{definition_name}"
      assert @validator.valid_ref?('common.schema.json', reference, value), definition_name
      assert json_schemer_valid_ref?('common.schema.json', reference, value), definition_name

      control_variants(value).each do |mutation_id, mutation|
        refute @validator.valid_ref?('common.schema.json', reference, mutation),
               "subset #{definition_name} #{mutation_id}"
        refute json_schemer_valid_ref?('common.schema.json', reference, mutation),
               "JSONSchemer #{definition_name} #{mutation_id}"
      end
    end

    wire_mutations = [
      ['recommend request_id', 'recommend_time_slots.request.schema.json',
       valid_fixture('recommend_time_slots.request.json'), ['request_id']],
      ['recommend time_zone', 'recommend_time_slots.request.schema.json',
       valid_fixture('recommend_time_slots.request.json'), ['time_zone']],
      ['confirm token', 'confirm_schedule_candidate.request.schema.json',
       valid_fixture('confirm_schedule_candidate.request.json'), ['confirmation_token']],
      ['confirm key', 'confirm_schedule_candidate.request.schema.json',
       valid_fixture('confirm_schedule_candidate.request.json'), ['idempotency_key']]
    ]
    wire_mutations.each do |label, schema_name, original, path|
      payload = deep_copy(original)
      payload[path.first] = "#{payload.fetch(path.first)}\n"
      refute @validator.valid?(schema_name, payload), label
      refute json_schemer_valid?(schema_name, payload), label
    end
  end

  test 'schema registry requires unique absolute fragment-free ids' do
    cases = {
      'relative.schema.json' => ['relative.schema.json', 'relative_id'],
      'fragment.schema.json' => ['https://example.test/root.schema.json#named', 'fragmented_id']
    }
    cases.each do |name, (identifier, expected_code)|
      Dir.mktmpdir('scheduling-contract-schema') do |directory|
        write_temp_schema(
          directory, name,
          '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
          '$id' => identifier,
          'type' => 'string'
        )
        validator = SchedulingRecommendationsV1SubsetValidator.new(directory, schema_names: [name])
        assert_contract_error(expected_code) { validator.audit!(name) }
      end
    end

    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      %w[first.schema.json second.schema.json].each do |name|
        write_temp_schema(
          directory, name,
          '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
          '$id' => 'https://example.test/duplicate.schema.json',
          'type' => 'string'
        )
      end
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: %w[first.schema.json second.schema.json]
      )
      assert_contract_error('duplicate_id') { validator.audit!('first.schema.json') }
    end
  end

  test 'relative refs use the active id base and only resolve registered local resources' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      write_temp_schema(
        directory, 'root.schema.json',
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/root/root.schema.json',
        '$ref' => '#/$defs/nested',
        '$defs' => {
          'nested' => {
            '$id' => 'https://example.test/nested/base.schema.json',
            '$ref' => 'target.schema.json#/$defs/value'
          }
        }
      )
      write_temp_schema(
        directory, 'physically-different-name.schema.json',
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/nested/target.schema.json',
        '$defs' => { 'value' => { 'type' => 'string', 'const' => 'resolved-by-active-id' } }
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: %w[root.schema.json physically-different-name.schema.json]
      )
      assert validator.valid?('root.schema.json', 'resolved-by-active-id')
      refute validator.valid?('root.schema.json', 'wrong')
    end

    {
      'https://not-registered.example/schema.json' => 'unregistered_ref',
      '../../../../outside.schema.json' => 'unregistered_ref',
      '#/$defs/missing' => 'missing_pointer',
      '#/$defs/~2malformed' => 'malformed_pointer'
    }.each do |reference, expected_code|
      Dir.mktmpdir('scheduling-contract-schema') do |directory|
        write_temp_schema(
          directory, 'root.schema.json',
          '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
          '$id' => 'https://example.test/contracts/root.schema.json',
          '$ref' => reference,
          '$defs' => {}
        )
        validator = SchedulingRecommendationsV1SubsetValidator.new(
          directory, schema_names: ['root.schema.json']
        )
        assert_contract_error(expected_code) { validator.audit!('root.schema.json') }
      end
    end
  end

  test 'json pointer escaping cycles and document-fragment cache keys fail closed' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      write_temp_schema(
        directory, 'pointer.schema.json',
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/pointer.schema.json',
        '$ref' => '#/$defs/a~1b~0c',
        '$defs' => { 'a/b~c' => { 'const' => 'escaped' } }
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: ['pointer.schema.json']
      )
      assert validator.valid?('pointer.schema.json', 'escaped')
    end

    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      write_temp_schema(
        directory, 'cycle.schema.json',
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/cycle.schema.json',
        '$ref' => '#'
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(directory, schema_names: ['cycle.schema.json'])
      assert validator.audit!('cycle.schema.json')
      assert_contract_error('recursive_ref') { validator.validate!('cycle.schema.json', 'anything') }
    end

    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      write_temp_schema(
        directory, 'root.schema.json',
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/root.schema.json',
        'oneOf' => [
          { '$ref' => 'target.schema.json#/$defs/stringValue' },
          { '$ref' => 'target.schema.json#/$defs/integerValue' }
        ]
      )
      write_temp_schema(
        directory, 'target.schema.json',
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/target.schema.json',
        '$defs' => {
          'stringValue' => { 'type' => 'string' },
          'integerValue' => { 'type' => 'integer' }
        }
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: %w[root.schema.json target.schema.json]
      )
      assert validator.valid?('root.schema.json', 'text')
      assert validator.valid?('root.schema.json', 1)
      refute validator.valid?('root.schema.json', true)
    end
  end

  test 'schema and instance strings reject invalid UTF-8 recursively' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      bytes = <<~JSON.b
        {"$schema":"#{SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12}",
         "$id":"https://example.test/invalid-utf8.schema.json","title":"
      JSON
      bytes << "\xFF".b << '"}'
      File.binwrite(File.join(directory, 'invalid-utf8.schema.json'), bytes)
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: ['invalid-utf8.schema.json']
      )
      assert_contract_error('invalid_utf8') { validator.audit!('invalid-utf8.schema.json') }
    end

    payload = deep_copy(valid_fixture('recommend_time_slots.request.json'))
    payload['title'] = "\xFF".b.force_encoding(Encoding::UTF_8)
    error = assert_contract_error('invalid_utf8') do
      @validator.validate!('recommend_time_slots.request.schema.json', payload)
    end
    assert_equal '$.title', error.flattened.find { |entry| entry.code == 'invalid_utf8' }.path
  end

  test 'validator sessions do not reuse mutable document state across validations' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      base = {
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/cache.schema.json',
        'const' => 'first'
      }
      write_temp_schema(directory, 'cache.schema.json', base)
      validator = SchedulingRecommendationsV1SubsetValidator.new(directory, schema_names: ['cache.schema.json'])
      assert validator.valid?('cache.schema.json', 'first')

      write_temp_schema(directory, 'cache.schema.json', base.merge('const' => 'second'))
      assert validator.valid?('cache.schema.json', 'second')
      refute validator.valid?('cache.schema.json', 'first')
    end
  end

  test 'oneOf is exclusive and JSON booleans numbers and nested unique items keep wire semantics' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      write_temp_schema(
        directory, 'semantics.schema.json',
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/semantics.schema.json',
        '$defs' => {
          'exclusive' => { 'oneOf' => [{ 'type' => 'number' }, { 'minimum' => 0 }] },
          'integer' => { 'type' => 'integer' },
          'unique' => { 'type' => 'array', 'uniqueItems' => true }
        }
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: ['semantics.schema.json']
      )
      error = assert_contract_error('one_of_multiple_matches') do
        validator.validate_ref!('semantics.schema.json', '#/$defs/exclusive', 1)
      end
      assert_equal '$', error.path
      refute validator.valid_ref?('semantics.schema.json', '#/$defs/integer', true)
      assert validator.valid_ref?('semantics.schema.json', '#/$defs/integer', 1.0)
      refute validator.valid_ref?(
        'semantics.schema.json', '#/$defs/unique',
        [{ 'a' => [1, { 'b' => 2 }] }, { 'a' => [1.0, { 'b' => 2.0 }] }]
      )
    end
  end

  test 'registry rejects missing files and symlinks that escape its physical root' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      validator = SchedulingRecommendationsV1SubsetValidator.new(directory, schema_names: ['missing.schema.json'])
      assert_contract_error('missing_document') { validator.audit!('missing.schema.json') }

      outside = File.join(File.dirname(directory), "outside-#{File.basename(directory)}.schema.json")
      File.binwrite(outside, JSON.generate(
        '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
        '$id' => 'https://example.test/outside.schema.json',
        'type' => 'string'
      ))
      begin
        File.symlink(outside, File.join(directory, 'escape.schema.json'))
        escaping = SchedulingRecommendationsV1SubsetValidator.new(
          directory, schema_names: ['escape.schema.json']
        )
        assert_contract_error('path_traversal') { escaping.audit!('escape.schema.json') }
      ensure
        File.delete(outside) if File.exist?(outside)
      end
    end
  end

  test 'referenced annotation content is audited and unsupported assertions fail closed' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      File.write(
        File.join(directory, 'unsupported.schema.json'),
        JSON.generate(
          '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
          '$id' => 'https://example.test/unsupported.schema.json',
          'type' => 'object',
          'default' => { 'minProperties' => 1 },
          '$ref' => '#/default'
        )
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: ['unsupported.schema.json']
      )

      assert_raises(SchedulingRecommendationsV1SubsetValidator::ContractValidationError) do
        validator.audit!('unsupported.schema.json')
      end
    end
  end

  test 'unsafe floating point schema values cannot create false numeric equality' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      File.write(
        File.join(directory, 'unsafe-number.schema.json'),
        <<~JSON
          {
            "$schema": "#{SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12}",
            "$id": "https://example.test/unsafe-number.schema.json",
            "enum": [9007199254740993.0]
          }
        JSON
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: ['unsafe-number.schema.json']
      )

      refute validator.valid?('unsafe-number.schema.json', 9_007_199_254_740_992)
      rounded_instance = JSON.parse('9007199254740993.0')
      refute validator.valid?('unsafe-number.schema.json', rounded_instance)

      File.write(
        File.join(directory, 'precise-decimal.schema.json'),
        <<~JSON
          {
            "$schema": "#{SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12}",
            "$id": "https://example.test/precise-decimal.schema.json",
            "enum": [0.100000000000000005]
          }
        JSON
      )
      precise_validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: ['precise-decimal.schema.json']
      )
      refute precise_validator.valid?('precise-decimal.schema.json', 0.1)

      File.write(
        File.join(directory, 'equal-number.schema.json'),
        <<~JSON
          {
            "$schema": "#{SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12}",
            "$id": "https://example.test/equal-number.schema.json",
            "enum": [1.0]
          }
        JSON
      )
      equal_validator = SchedulingRecommendationsV1SubsetValidator.new(
        directory, schema_names: ['equal-number.schema.json']
      )
      assert equal_validator.valid?('equal-number.schema.json', 1), 'JSON numbers 1 and 1.0 must compare equally'
    end
  end

  test 'unknown properties are rejected at every nested object boundary' do
    VALID_FIXTURES.each do |fixture_name, schema_name|
      original = valid_fixture(fixture_name)
      hash_paths(original).each do |path|
        payload = deep_copy(original)
        object = path.reduce(payload) { |current, key| current.fetch(key) }
        object['unexpected_nested_field'] = true
        label = path.empty? ? '$' : path.join('.')
        refute @validator.valid?(schema_name, payload), "#{fixture_name} accepted unknown property at #{label}"
      end
    end
  end

  test 'fixture time windows slots durations and candidate ordering are internally consistent' do
    all_valid_payloads.each do |fixture_name, payload|
      assert_ordered_time_pair(payload, 'generated_at', 'expires_at', fixture_name)
      assert_ordered_named_windows(payload, fixture_name)
      assert_slot_consistency(payload, fixture_name)
      assert_unique_candidate_fields(payload, fixture_name)
    end
  end

  test 'recommendation candidate revision and snapshot bindings stay consistent across fixtures' do
    recommendation = valid_fixture('recommend_time_slots.response.json')
    revision_request = valid_fixture('revise_time_slot.request.json')
    feasible_revision = valid_fixture('revise_time_slot.feasible.response.json')
    confirm_request = valid_fixture('confirm_schedule_candidate.request.json')
    committed = valid_fixture('confirm_schedule_candidate.committed.response.json')

    assert_equal recommendation.fetch('recommendation_id'), revision_request.fetch('recommendation_id')
    assert_equal recommendation.fetch('recommendation_id'), feasible_revision.fetch('recommendation_id')
    assert_equal recommendation.fetch('recommendation_id'), confirm_request.fetch('recommendation_id')
    assert_equal recommendation.fetch('recommendation_id'), committed.fetch('recommendation_id')

    assert_equal recommendation.fetch('schedule_snapshot_version'),
                 revision_request.fetch('schedule_snapshot_version')
    assert_equal recommendation.fetch('schedule_snapshot_version'),
                 feasible_revision.fetch('schedule_snapshot_version')

    original_candidate_ids = recommendation.fetch('candidates').map { |candidate| candidate.fetch('candidate_id') }
    assert_includes original_candidate_ids, revision_request.fetch('candidate_id')

    revised_candidate = feasible_revision.fetch('revised_candidate')
    assert_equal revised_candidate.fetch('candidate_id'), confirm_request.fetch('candidate_id')
    assert_equal feasible_revision.fetch('candidate_id'), revised_candidate.fetch('candidate_id')
    assert_equal feasible_revision.fetch('candidate_id'), committed.fetch('candidate_id')
    assert_equal feasible_revision.fetch('revision_id'), confirm_request.fetch('revision_id')
    assert_equal feasible_revision.fetch('revision_id'), committed.fetch('revision_id')
    assert_equal feasible_revision.fetch('revision_id'), revised_candidate.fetch('revision_id')
    assert_equal feasible_revision.fetch('schedule_snapshot_version'), confirm_request.fetch('schedule_snapshot_version')
    refute_equal confirm_request.fetch('schedule_snapshot_version'), committed.fetch('schedule_snapshot_version'),
                 'committed Event must advance the canonical schedule snapshot'

    recommendation.fetch('candidates').each do |candidate|
      assert_equal recommendation.fetch('recommendation_id'), candidate.fetch('recommendation_id')
    end
    assert_equal recommendation.fetch('recommendation_id'), revised_candidate.fetch('recommendation_id')
    assert_equal revision_request.fetch('candidate_id'), revised_candidate.fetch('candidate_id')
    assert_equal recommendation.fetch('expires_at'), feasible_revision.fetch('expires_at'),
                 'a revision must not extend the original recommendation expiry'
  end

  test 'semantic invariant registry is exact and every valid fixture and exchange satisfies it' do
    registry = contract_data('semantic_invariants.json')
    assert_equal '1.0', registry['schema_version']
    entries = registry.fetch('invariants')
    assert_equal SEMANTIC_INVARIANT_IDS, entries.map { |entry| entry.fetch('id') }
    assert_equal SEMANTIC_VALIDATORS, entries.to_h { |entry| [entry.fetch('id'), entry.fetch('validator')] }
    assert_equal SchedulingRecommendationsV1SemanticValidator::INVARIANT_IDS, SEMANTIC_INVARIANT_IDS

    VALID_FIXTURES.each_key do |fixture_name|
      assert_empty @semantic_validator.validate_payload(valid_fixture(fixture_name)), fixture_name
    end
    semantic_valid_exchanges.each do |label, context|
      assert_empty @semantic_validator.validate_exchange(**context), label
    end
  end

  test 'semantic mutations mechanically reject all eighteen cross-field invariants at exact paths' do
    recommendation_request = deep_copy(valid_fixture('recommend_time_slots.request.json'))
    recommendation = deep_copy(valid_fixture('recommend_time_slots.response.json'))
    revision_request = deep_copy(valid_fixture('revise_time_slot.request.json'))
    revision = deep_copy(valid_fixture('revise_time_slot.feasible.response.json'))
    confirm_request = deep_copy(valid_fixture('confirm_schedule_candidate.request.json'))
    committed = deep_copy(valid_fixture('confirm_schedule_candidate.committed.response.json'))
    reject_request = deep_copy(valid_fixture('reject_schedule_recommendation.request.json'))
    rejected = deep_copy(valid_fixture('reject_schedule_recommendation.response.json'))

    payload = deep_copy(recommendation_request)
    payload['search_window']['end_at'] = payload['search_window']['start_at']
    assert_structural_then_semantic_failure(
      'SEM-SEARCH-EQUAL', 'SR-SEM-001', '$.search_window.end_at',
      'recommend_time_slots.request.schema.json', payload
    )

    payload = deep_copy(recommendation_request)
    payload['search_window']['end_at'] = '2026-09-01T08:00:00+09:00'
    assert_structural_then_semantic_failure(
      'SEM-SEARCH-REVERSED', 'SR-SEM-001', '$.search_window.end_at',
      'recommend_time_slots.request.schema.json', payload
    )

    payload = deep_copy(recommendation)
    payload['expires_at'] = payload['generated_at']
    assert_structural_then_semantic_failure(
      'SEM-EXPIRY-EQUAL', 'SR-SEM-002', '$.expires_at',
      'recommend_time_slots.response.schema.json', payload
    )
    payload = deep_copy(recommendation)
    payload['expires_at'] = '2026-08-30T08:59:00+09:00'
    assert_structural_then_semantic_failure(
      'SEM-EXPIRY-REVERSED', 'SR-SEM-002', '$.expires_at',
      'recommend_time_slots.response.schema.json', payload
    )

    payload = deep_copy(recommendation)
    payload['candidates'][0]['slot']['end_at'] = payload['candidates'][0]['slot']['start_at']
    assert_structural_then_semantic_failure(
      'SEM-SLOT-EQUAL', 'SR-SEM-003', '$.candidates[0].slot.end_at',
      'recommend_time_slots.response.schema.json', payload
    )
    payload = deep_copy(recommendation)
    payload['candidates'][0]['slot']['end_at'] = '2026-09-01T09:00:00+09:00'
    assert_structural_then_semantic_failure(
      'SEM-SLOT-REVERSED', 'SR-SEM-003', '$.candidates[0].slot.end_at',
      'recommend_time_slots.response.schema.json', payload
    )

    payload = deep_copy(recommendation)
    payload['candidates'][0]['slot']['duration_minutes'] = 30
    assert_structural_then_semantic_failure(
      'SEM-DURATION-MISMATCH', 'SR-SEM-004', '$.candidates[0].slot.duration_minutes',
      'recommend_time_slots.response.schema.json', payload
    )

    payload = deep_copy(recommendation)
    payload['candidates'][1]['candidate_id'] = payload['candidates'][0]['candidate_id']
    assert_structural_then_semantic_failure(
      'SEM-DUPLICATE-CANDIDATE', 'SR-SEM-005', '$.candidates',
      'recommend_time_slots.response.schema.json', payload
    )

    payload = deep_copy(recommendation)
    payload['candidates'].each_with_index { |candidate, index| candidate['rank'] = index + 2 }
    assert_structural_then_semantic_failure(
      'SEM-RANK-NONCONTIGUOUS', 'SR-SEM-006', '$.candidates',
      'recommend_time_slots.response.schema.json', payload
    )
    payload = deep_copy(recommendation)
    payload['candidates'][1]['rank'] = payload['candidates'][0]['rank']
    assert_structural_then_semantic_failure(
      'SEM-RANK-DUPLICATE', 'SR-SEM-006', '$.candidates',
      'recommend_time_slots.response.schema.json', payload
    )

    payload = deep_copy(recommendation)
    payload['candidates'][0]['recommendation_id'] = 'rec_schedule_other_0001'
    assert_structural_then_semantic_failure(
      'SEM-CANDIDATE-RECOMMENDATION', 'SR-SEM-007', '$.candidates[0].recommendation_id',
      'recommend_time_slots.response.schema.json', payload
    )

    payload = deep_copy(revision)
    payload['revised_candidate']['recommendation_id'] = 'rec_schedule_other_0001'
    assert_structural_then_semantic_failure(
      'SEM-REVISED-RECOMMENDATION', 'SR-SEM-008', '$.revised_candidate.recommendation_id',
      'revise_time_slot.response.schema.json', payload
    )

    payload = deep_copy(revision)
    payload['revised_candidate']['candidate_id'] = 'cand_slot_other_0001'
    assert_structural_then_semantic_failure(
      'SEM-REVISED-CANDIDATE', 'SR-SEM-009', '$.revised_candidate.candidate_id',
      'revise_time_slot.response.schema.json', payload
    )

    payload = deep_copy(revision)
    payload['revised_candidate']['revision_id'] = 'rev_slot_other_0001'
    assert_structural_then_semantic_failure(
      'SEM-REVISED-REVISION', 'SR-SEM-010', '$.revised_candidate.revision_id',
      'revise_time_slot.response.schema.json', payload
    )

    response = deep_copy(recommendation)
    response['request_id'] = 'req_schedule_other_0001'
    assert_exchange_semantic_failure(
      'SEM-REQUEST-CORRELATION', 'SR-SEM-011', '$.response.request_id',
      request: recommendation_request, response: response
    )
    response = deep_copy(recommendation)
    response['trace_id'] = 'trc_schedule_other_0001'
    assert_exchange_semantic_failure(
      'SEM-TRACE-CORRELATION', 'SR-SEM-011', '$.response.trace_id',
      request: recommendation_request, response: response
    )

    response = deep_copy(revision)
    response['expires_at'] = '2026-08-30T09:16:00+09:00'
    assert_exchange_semantic_failure(
      'SEM-REVISION-EXPIRY', 'SR-SEM-012', '$.response.expires_at',
      request: revision_request, response: response, recommendation: recommendation
    )

    response = deep_copy(committed)
    response['candidate_id'] = 'cand_slot_other_0001'
    assert_exchange_semantic_failure(
      'SEM-CONFIRM-BINDING', 'SR-SEM-013', '$.response.candidate_id',
      request: confirm_request, response: response, recommendation: recommendation, revision: revision
    )

    response = deep_copy(committed)
    response['schedule_snapshot_version'] = confirm_request['schedule_snapshot_version']
    assert_exchange_semantic_failure(
      'SEM-SNAPSHOT-NOT-ADVANCED', 'SR-SEM-014', '$.response.schedule_snapshot_version',
      request: confirm_request, response: response, recommendation: recommendation, revision: revision
    )

    response = deep_copy(committed)
    response['final_slot']['start_at'] = '2026-09-01T12:00:00+09:00'
    response['final_slot']['end_at'] = '2026-09-01T13:00:00+09:00'
    assert_exchange_semantic_failure(
      'SEM-FINAL-SLOT', 'SR-SEM-015', '$.response.final_slot',
      request: confirm_request, response: response, recommendation: recommendation, revision: revision
    )

    response = deep_copy(rejected)
    response['action'] = response['action'] == 'rejected_all' ? 'dismissed' : 'rejected_all'
    assert_exchange_semantic_failure(
      'SEM-REJECT-ACTION', 'SR-SEM-016', '$.response.action',
      request: reject_request, response: response
    )

    error_response = deep_copy(valid_fixture('confirm_schedule_candidate.expired.response.json'))
    failed_request = request_for_response(error_response)
    error_response['request_id'] = 'req_confirm_other_0001'
    assert_exchange_semantic_failure(
      'SEM-ERROR-CORRELATION', 'SR-SEM-017', '$.response.request_id',
      request: failed_request, response: error_response
    )

    payload = deep_copy(recommendation_request)
    payload['time_zone'] = 'Asia/Tokyo'
    payload['search_window']['start_at'] = '2026-09-01T09:00:00+00:00'
    payload['search_window']['end_at'] = '2026-09-01T10:00:00+00:00'
    assert_structural_then_semantic_failure(
      'SEM-TIMEZONE-OFFSET', 'SR-SEM-018', '$.search_window.start_at',
      'recommend_time_slots.request.schema.json', payload
    )
  end

  test 'SR-SEM-012 and every declared semantic context path fail closed' do
    request = deep_copy(valid_fixture('revise_time_slot.request.json'))
    response = deep_copy(valid_fixture('revise_time_slot.feasible.response.json'))
    recommendation = deep_copy(valid_fixture('recommend_time_slots.response.json'))

    missing_failures = @semantic_validator.validate_exchange(request: request, response: response)
    assert_semantic_failure(
      'recommendation missing', 'SR-SEM-012', '$.response.expires_at', missing_failures
    )

    mutations = {
      'recommendation null' => nil,
      'recommendation wrong type' => 'not-an-object',
      'recommendation expires_at missing' => recommendation.except('expires_at'),
      'recommendation expires_at invalid' => recommendation.merge('expires_at' => 'not-a-date-time'),
      'response expiry mismatch' => recommendation.merge('expires_at' => '2026-08-30T09:16:00+09:00')
    }
    mutations.each do |label, source_recommendation|
      failures = @semantic_validator.validate_exchange(
        request: request, response: response, recommendation: source_recommendation
      )
      assert_semantic_failure(label, 'SR-SEM-012', '$.response.expires_at', failures)
    end

    complete_context = semantic_required_context_sample
    contract_data('semantic_invariants.json').fetch('invariants').each do |invariant|
      assert_empty @semantic_validator.validate_required_context(invariant.fetch('id'), complete_context),
                   "complete context for #{invariant.fetch('id')}"
      invariant.fetch('required_context_paths').each do |required_path|
        mutated = deep_copy(complete_context)
        delete_json_path(mutated, required_path)
        failures = @semantic_validator.validate_required_context(invariant.fetch('id'), mutated)
        assert_semantic_failure(
          "#{invariant.fetch('id')} missing #{required_path}",
          invariant.fetch('id'), invariant.fetch('failure_path'), failures
        )

        wrong_type = deep_copy(complete_context)
        parts = required_path.delete_prefix('$.').split('.')
        parent = parts[0...-1].reduce(wrong_type) { |current, part| current.fetch(part) }
        original = parent.fetch(parts.last)
        parent[parts.last] = original.is_a?(Hash) ? [] : (original.is_a?(Array) ? {} : {})
        failures = @semantic_validator.validate_required_context(invariant.fetch('id'), wrong_type)
        assert_semantic_failure(
          "#{invariant.fetch('id')} wrong type at #{required_path}",
          invariant.fetch('id'), invariant.fetch('failure_path'), failures
        )
      end
    end
  end

  test 'confirmation and idempotency credentials are mandatory and revision issues a fresh token' do
    request = valid_fixture('confirm_schedule_candidate.request.json')
    assert request['confirmation_token'].present?
    assert request['idempotency_key'].present?

    refute @validator.valid?(
      'confirm_schedule_candidate.request.schema.json',
      invalid_fixture('confirm_schedule_candidate.missing_confirmation_token.request.json')
    )
    refute @validator.valid?(
      'confirm_schedule_candidate.request.schema.json',
      invalid_fixture('confirm_schedule_candidate.missing_idempotency_key.request.json')
    )

    recommendation = valid_fixture('recommend_time_slots.response.json')
    revision = valid_fixture('revise_time_slot.feasible.response.json')
    assert revision['confirmation_token'].present?
    assert_equal true, revision['requires_confirmation']
    refute_includes recommendation.fetch('candidates').map { |candidate| candidate['confirmation_token'] },
                    revision['confirmation_token']
  end

  test 'evidence and logical-attempt machine data freeze exact bindings states and ordering' do
    evidence = contract_data('confirmation_evidence_contract.json')
    assert_equal %w[
      authenticated_user_id authenticated_workspace_id recommendation_id candidate_id
      revision_id_exact_or_absent final_slot_canonical_fingerprint
      pre_commit_schedule_snapshot_version recommendation_expires_at
    ], evidence.fetch('binding_fields')
    assert_equal %w[
      recommendation_machine_revalidated final_slot_presented_to_authenticated_user
      authenticated_user_originated_confirmation_action recommendation_unexpired
      tenant_recommendation_candidate_revision_consistent
    ], evidence.fetch('creation_preconditions')
    assert_equal %w[active consumed expired revoked], evidence.fetch('statuses')
    assert_equal true, evidence.fetch('single_use')
    assert_equal false, evidence.fetch('model_tool_call_is_evidence')
    assert_equal 'CONFIRMATION_REQUIRED', evidence.fetch('missing_evidence_error')
    assert_equal 'CONFIRMATION_REQUIRED', evidence.fetch('mismatch_error')
    assert_equal %w[
      authenticated_tenant_binding exact_confirmation_evidence_lookup
      candidate_revision_final_slot_snapshot_expiry_binding_validation
      logical_confirmation_attempt_atomic_get_or_create existing_idempotency_key_retrieval
      confirmation_token_retrieval
    ], evidence.fetch('pre_dispatch_order')
    assert_equal %w[
      event feedback_record post_commit_schedule_snapshot idempotency_result
      confirmation_evidence_consumption confirmation_token_consumption
    ], evidence.fetch('commit_atomic_with')

    lifecycle = contract_data('idempotency_lifecycle.json')
    assert_equal %w[allocated in_progress outcome_unknown committed failed_terminal], lifecycle.fetch('states')
    assert_equal %w[committed failed_terminal], lifecycle.fetch('terminal_states')
    assert_equal 7, lifecycle.fetch('transitions').length
    assert_equal 'ONE_TO_ONE', lifecycle.dig('cardinality', 'confirmation_evidence_to_logical_attempt')
    assert_equal 'ONE_TO_ONE', lifecycle.dig('cardinality', 'logical_attempt_to_idempotency_key')
    assert_equal 86_400, lifecycle.dig('retry_policy', 'logical_confirmation_retry_window_seconds')
    assert_equal 86_400, lifecycle.dig('retry_policy', 'idempotency_result_minimum_retention_seconds')
    assert_equal false, lifecycle.dig('terminal_result_policy', 'duplicate_event_allowed')
    assert_equal false, lifecycle.dig('terminal_result_policy', 'duplicate_feedback_allowed')

    manifest = contract_data('tool_manifest.json')
    confirm = manifest.fetch('public_operations').find do |entry|
      entry.fetch('operation') == 'confirm_schedule_candidate'
    end
    assert_equal EXPECTED_TOOL_MANIFEST_FIELDS.fetch('confirm_schedule_candidate').fetch('adapter_sequence'),
                 confirm.fetch('adapter_sequence')
  end

  test 'confirmation evidence reference rejects every pivot before token or key access' do
    now = Time.iso8601('2026-08-30T08:00:00+09:00')
    base_evidence, base_request, tenant = confirmation_evidence_samples
    scenarios = {
      'missing evidence' => [nil, base_request, tenant, false],
      'model Tool call only' => [base_evidence, base_request, tenant, true],
      'authenticated user mismatch' => [base_evidence, base_request,
                                        tenant.merge('authenticated_user_id' => 'user_other'), false],
      'tenant mismatch' => [base_evidence, base_request,
                            tenant.merge('authenticated_workspace_id' => 'workspace_other'), false],
      'recommendation mismatch' => [base_evidence,
                                    base_request.merge('recommendation_id' => 'rec_schedule_other_0001'), tenant, false],
      'candidate A evidence candidate B confirm' => [base_evidence,
                                                      base_request.merge('candidate_id' => 'cand_slot_0002'), tenant, false],
      'candidate evidence revision confirm' => [base_evidence.except('revision_id'), base_request, tenant, false],
      'revision A evidence revision B confirm' => [base_evidence,
                                                   base_request.merge('revision_id' => 'rev_slot_other_0001'), tenant, false],
      'final slot mismatch' => [base_evidence,
                               base_request.merge('final_slot_canonical_fingerprint' => 'slot_sha256_other'), tenant, false],
      'snapshot mismatch' => [base_evidence,
                             base_request.merge('pre_commit_schedule_snapshot_version' => 'sch_snapshot_other_0001'), tenant, false],
      'future expiry mismatch' => [base_evidence,
                                   base_request.merge('recommendation_expires_at' => '2026-08-30T09:30:00+09:00'), tenant, false],
      'expired evidence' => [base_evidence.merge('recommendation_expires_at' => '2026-08-30T07:59:59+09:00'),
                             base_request.merge('recommendation_expires_at' => '2026-08-30T07:59:59+09:00'), tenant, false],
      'expired evidence status' => [base_evidence.merge('status' => 'expired'), base_request, tenant, false],
      'revoked evidence' => [base_evidence.merge('status' => 'revoked'), base_request, tenant, false],
      'consumed evidence new commit' => [base_evidence.merge('status' => 'consumed'), base_request, tenant, false]
    }

    %w[
      recommendation_id candidate_id final_slot_canonical_fingerprint
      pre_commit_schedule_snapshot_version recommendation_expires_at
    ].each do |field|
      scenarios["both sides missing #{field}"] = [
        base_evidence.except(field), base_request.except(field), tenant, false
      ]
    end
    %w[authenticated_user_id authenticated_workspace_id].each do |field|
      scenarios["evidence and tenant missing #{field}"] = [
        base_evidence.except(field), base_request, tenant.except(field), false
      ]
    end
    scenarios['missing evidence identity'] = [base_evidence.except('evidence_id'), base_request, tenant, false]
    scenarios['both revisions null'] = [
      base_evidence.merge('revision_id' => nil), base_request.merge('revision_id' => nil), tenant, false
    ]
    scenarios['evidence revision null'] = [
      base_evidence.merge('revision_id' => nil), base_request, tenant, false
    ]
    scenarios['request revision null'] = [
      base_evidence, base_request.merge('revision_id' => nil), tenant, false
    ]

    scenarios.each do |label, (evidence, request_context, authenticated_tenant, model_only)|
      validator = SchedulingConfirmationEvidenceReference.new(now: now)
      result = validator.authorize(
        evidence: evidence, request_context: request_context,
        authenticated_tenant: authenticated_tenant, model_only: model_only
      )
      assert_equal 'REJECTED', result.outcome, label
      assert_equal 'CONFIRMATION_REQUIRED', result.error_code, label
      assert_equal 0, validator.token_lookup_count, label
      assert_equal 0, validator.idempotency_allocation_count, label
      assert_equal 0, validator.event_side_effect_count, label
    end

    validator = SchedulingConfirmationEvidenceReference.new(now: now)
    exact = validator.authorize(
      evidence: base_evidence, request_context: base_request,
      authenticated_tenant: tenant
    )
    assert_equal 'AUTHORIZED_TO_CONTINUE', exact.outcome
    assert_equal 1, validator.idempotency_allocation_count
    assert_equal 1, validator.token_lookup_count
    assert_equal 0, validator.event_side_effect_count

    candidate_validator = SchedulingConfirmationEvidenceReference.new(now: now)
    candidate_exact = candidate_validator.authorize(
      evidence: base_evidence.except('revision_id'),
      request_context: base_request.except('revision_id'),
      authenticated_tenant: tenant
    )
    assert_equal 'AUTHORIZED_TO_CONTINUE', candidate_exact.outcome

    duplicate = SchedulingConfirmationEvidenceReference.new(now: now)
    first = duplicate.create_for_authenticated_action('user_action_fixed_0001', base_evidence)
    second = duplicate.create_for_authenticated_action('user_action_fixed_0001', base_evidence.merge('evidence_id' => 'evidence_other'))
    assert_same first, second
    assert_equal 1, duplicate.evidence_creation_count
  end

  test 'logical confirmation lifecycle reuses one attempt key and authoritative terminal result' do
    now = Time.iso8601('2026-08-30T08:00:00+09:00')
    lifecycle = SchedulingIdempotencyLifecycleReference.new
    first = lifecycle.acquire(evidence_id: 'evidence_fixed_0001', now: now, model_invocation_id: 'model_1')
    retry_attempt = lifecycle.acquire(
      evidence_id: 'evidence_fixed_0001', now: now + 1, model_invocation_id: 'model_2'
    )
    assert_same first, retry_attempt
    assert_equal first.idempotency_key, retry_attempt.idempotency_key
    assert_equal 1, lifecycle.allocation_count
    assert_raises(ArgumentError) { lifecycle.force_second_key!('evidence_fixed_0001') }

    original_key = first.idempotency_key
    unknown = lifecycle.execute_or_replay!(first, now: now, outcome: :outcome_unknown)
    assert_equal 'outcome_unknown', unknown.fetch('status')
    assert_equal 'outcome_unknown', first.state
    assert_equal original_key, first.idempotency_key
    assert_equal 1, lifecycle.authoritative_lookup_count

    committed_result = lifecycle.execute_or_replay!(first, now: now + 1, outcome: :committed)
    assert_equal %w[
      authoritative_idempotency_state_lookup dispatch_with_existing_idempotency_key
      stage_terminal_result_for_atomic_commit
      atomically_store_result_event_feedback_snapshot_and_consume_token_evidence
    ], lifecycle.operation_log.last(4)
    replayed_result = lifecycle.execute_or_replay!(
      first, now: now + 2, evidence_status: 'consumed'
    )
    assert_same committed_result, replayed_result
    assert_equal committed_result.fetch('event_id'), replayed_result.fetch('event_id')
    assert_equal committed_result.fetch('feedback_event_id'), replayed_result.fetch('feedback_event_id')
    assert_equal 1, lifecycle.event_side_effect_count
    assert_equal 1, lifecycle.feedback_side_effect_count
    assert_equal 2, lifecycle.dispatch_count
    assert_equal 1, lifecycle.atomic_commit_count
    assert_same first, lifecycle.acquire(
      evidence_id: 'evidence_fixed_0001', now: now + 2, evidence_status: 'consumed'
    )
    assert_raises(ArgumentError) { lifecycle.transition!(first, 'in_progress') }

    second = lifecycle.acquire(evidence_id: 'evidence_fixed_0002', now: now + 3)
    refute_equal first.idempotency_key, second.idempotency_key
    assert_equal 2, lifecycle.allocation_count

    failed = SchedulingIdempotencyLifecycleReference.new
    failed_attempt = failed.acquire(evidence_id: 'evidence_failed', now: now)
    failed_result = failed.execute_or_replay!(failed_attempt, now: now, outcome: :failed_terminal)
    replayed_failure = failed.execute_or_replay!(
      failed_attempt, now: now + 1, outcome: :committed, evidence_status: 'revoked'
    )
    assert_same failed_result, replayed_failure
    assert_equal 'failed_terminal', replayed_failure.fetch('status')
    assert_equal 0, failed.event_side_effect_count
    assert_equal 0, failed.feedback_side_effect_count
    assert_equal 1, failed.dispatch_count
    assert_raises(ArgumentError) { failed.transition!(failed_attempt, 'committed') }
  end

  test 'concurrent retries converge on one dispatch Event feedback and result' do
    now = Time.iso8601('2026-08-30T08:00:00+09:00')
    concurrent = SchedulingIdempotencyLifecycleReference.new
    ready = Queue.new
    release = Queue.new
    threads = 8.times.map do
      Thread.new do
        attempt = concurrent.acquire(evidence_id: 'evidence_concurrent', now: now)
        ready << true
        release.pop
        [attempt, concurrent.execute_or_replay!(attempt, now: now)]
      end
    end
    8.times { ready.pop }
    8.times { release << true }
    concurrent_pairs = threads.map(&:value)
    concurrent_attempts = concurrent_pairs.map(&:first)
    concurrent_results = concurrent_pairs.map(&:last)
    assert_equal 1, concurrent_attempts.map(&:object_id).uniq.length
    assert_equal 1, concurrent_attempts.map(&:idempotency_key).uniq.length
    assert_equal 1, concurrent_results.map(&:object_id).uniq.length
    assert_equal 1, concurrent_results.uniq.length
    assert_equal 1, concurrent.allocation_count
    assert_equal 1, concurrent.dispatch_count
    assert_equal 1, concurrent.atomic_commit_count
    assert_equal 1, concurrent.event_side_effect_count
    assert_equal 1, concurrent.feedback_side_effect_count
  end

  test 'outcome unknown consults and reconciles authoritative committed failed or unresolved state' do
    now = Time.iso8601('2026-08-30T08:00:00+09:00')
    {
      'committed' => %w[event_id feedback_event_id],
      'failed_terminal' => %w[code retryable]
    }.each do |terminal_state, result_fields|
      lifecycle = SchedulingIdempotencyLifecycleReference.new
      attempt = lifecycle.acquire(evidence_id: "evidence_#{terminal_state}", now: now)
      lifecycle.execute_or_replay!(attempt, now: now, outcome: :outcome_unknown)
      key = attempt.idempotency_key
      authoritative = lifecycle.record_authoritative_terminal_after_lost_response!(
        attempt, state: terminal_state, now: now + 1
      )
      replayed = lifecycle.execute_or_replay!(
        attempt, now: now + 2, evidence_status: terminal_state == 'committed' ? 'consumed' : 'revoked'
      )
      assert_same authoritative, replayed, terminal_state
      assert_equal terminal_state, attempt.state, terminal_state
      assert_equal key, attempt.idempotency_key, terminal_state
      result_fields.each { |field| assert replayed.key?(field), "#{terminal_state} #{field}" }
      assert_equal 1, lifecycle.allocation_count, terminal_state
      assert_equal 1, lifecycle.dispatch_count, terminal_state
      assert_equal 1, lifecycle.atomic_commit_count, terminal_state
    end

    unresolved = SchedulingIdempotencyLifecycleReference.new
    attempt = unresolved.acquire(evidence_id: 'evidence_unresolved', now: now)
    original_key = attempt.idempotency_key
    unresolved.execute_or_replay!(attempt, now: now, outcome: :outcome_unknown)
    lookup_count = unresolved.authoritative_lookup_count
    result = unresolved.execute_or_replay!(attempt, now: now + 1, outcome: :committed)
    assert_equal 'committed', result.fetch('status')
    assert_equal original_key, attempt.idempotency_key
    assert_equal 1, unresolved.allocation_count
    assert_equal lookup_count + 1, unresolved.authoritative_lookup_count
    assert_equal %w[
      authoritative_idempotency_state_lookup dispatch_with_existing_idempotency_key
      stage_terminal_result_for_atomic_commit
      atomically_store_result_event_feedback_snapshot_and_consume_token_evidence
    ], unresolved.operation_log.last(4)

    consumed_without_result = SchedulingIdempotencyLifecycleReference.new
    orphan = consumed_without_result.acquire(evidence_id: 'evidence_orphan', now: now)
    consumed_without_result.execute_or_replay!(orphan, now: now, outcome: :outcome_unknown)
    assert_raises(ArgumentError) do
      consumed_without_result.execute_or_replay!(orphan, now: now + 1, evidence_status: 'consumed')
    end
    assert_equal 0, consumed_without_result.event_side_effect_count
    assert_equal 0, consumed_without_result.feedback_side_effect_count
  end

  test 'a failure after terminal staging leaves no durable result Event feedback or consumption' do
    now = Time.iso8601('2026-08-30T08:00:00+09:00')
    lifecycle = SchedulingIdempotencyLifecycleReference.new
    attempt = lifecycle.acquire(evidence_id: 'evidence_staging_failure', now: now)
    lifecycle.transition!(attempt, 'in_progress')
    staged = lifecycle.stage_terminal_result_for_atomic_commit(attempt, state: 'committed')
    assert_equal({ 'terminal_state' => 'committed', 'durable' => false }, staged)
    assert_nil attempt.result
    assert_nil attempt.terminal_stored_at
    assert_equal 0, lifecycle.atomic_commit_count
    assert_equal 0, lifecycle.event_side_effect_count
    assert_equal 0, lifecycle.feedback_side_effect_count
    assert_raises(ArgumentError) do
      lifecycle.execute_or_replay!(attempt, now: now + 1, evidence_status: 'consumed')
    end
    assert_equal 'in_progress', attempt.state
    assert_nil attempt.result
    assert_equal 0, lifecycle.atomic_commit_count
    assert_equal 0, lifecycle.event_side_effect_count
    assert_equal 0, lifecycle.feedback_side_effect_count
  end

  test 'retry and result retention boundaries replay then fail closed without a second effect' do
    now = Time.iso8601('2026-08-30T08:00:00+09:00')
    lifecycle = SchedulingIdempotencyLifecycleReference.new
    attempt = lifecycle.acquire(evidence_id: 'evidence_boundary', now: now)
    original_key = attempt.idempotency_key
    committed = lifecycle.execute_or_replay!(attempt, now: now)
    replayed = lifecycle.execute_or_replay!(
      attempt, now: now + 86_399, evidence_status: 'consumed'
    )
    assert_same committed, replayed
    assert lifecycle.retry_window_open?(attempt, attempt.allocated_at + 86_399)
    refute lifecycle.retry_window_open?(attempt, attempt.allocated_at + 86_400)
    assert_raises(ArgumentError) do
      lifecycle.execute_or_replay!(attempt, now: now + 86_400, evidence_status: 'consumed')
    end
    assert_same attempt, lifecycle.acquire(
      evidence_id: 'evidence_boundary', now: now + 86_400, evidence_status: 'consumed'
    )
    assert_equal original_key, attempt.idempotency_key
    assert_equal 1, lifecycle.allocation_count
    assert_equal 1, lifecycle.dispatch_count
    assert_equal 1, lifecycle.event_side_effect_count
    assert_equal 1, lifecycle.feedback_side_effect_count

    assert_raises(ArgumentError) do
      SchedulingIdempotencyLifecycleReference.new(retention_seconds: 86_399)
    end

    longer = SchedulingIdempotencyLifecycleReference.new(retention_seconds: 172_800)
    long_attempt = longer.acquire(evidence_id: 'evidence_long_retention', now: now)
    long_result = longer.execute_or_replay!(long_attempt, now: now)
    assert_same long_result, longer.execute_or_replay!(
      long_attempt, now: now + 86_400, evidence_status: 'consumed'
    )
    assert_equal 1, longer.event_side_effect_count
    assert_equal 1, longer.feedback_side_effect_count
  end

  test 'normative response fields remain required under mutation' do
    required_paths = {
      'recommend_time_slots.response.json' => [
        %w[recommendation_id], %w[policy_version], %w[schedule_snapshot_version],
        %w[generated_at], %w[expires_at], %w[constraint_policy], %w[candidates],
        ['candidates', 0, 'candidate_id'], ['candidates', 0, 'rank'],
        ['candidates', 0, 'feasible'], ['candidates', 0, 'confirmation_token'],
        ['candidates', 0, 'slot'], ['candidates', 0, 'reason_codes'],
        ['candidates', 0, 'penalty_codes'], ['candidates', 0, 'score']
      ],
      'revise_time_slot.feasible.response.json' => [
        %w[revision_id], %w[schedule_snapshot_version], %w[expires_at],
        %w[confirmation_token], %w[revised_candidate], %w[requires_confirmation],
        %w[constraint_policy], %w[revised_candidate candidate_id],
        %w[revised_candidate revision_id], %w[revised_candidate slot]
      ],
      'revise_time_slot.infeasible.response.json' => [
        %w[constraint_policy], %w[error]
      ],
      'confirm_schedule_candidate.committed.response.json' => [
        %w[event_id], %w[feedback_event_id], %w[final_slot]
      ],
      'reject_schedule_recommendation.response.json' => [
        %w[feedback_event_id]
      ]
    }

    required_paths.each do |fixture_name, paths|
      schema_name = VALID_FIXTURES.fetch(fixture_name)
      paths.each do |path|
        payload = deep_copy(valid_fixture(fixture_name))
        delete_path(payload, path)
        refute @validator.valid?(schema_name, payload), "#{fixture_name} accepted without #{path.join('.')}"
      end
    end
  end

  test 'only a committed confirmation response can contain an event id' do
    %w[
      recommend_time_slots.request.schema.json recommend_time_slots.response.schema.json
      revise_time_slot.request.schema.json revise_time_slot.response.schema.json
      reject_schedule_recommendation.request.schema.json reject_schedule_recommendation.response.schema.json
    ].each do |schema_name|
      refute_includes all_declared_property_names(schema_json(schema_name)), 'event_id', schema_name
    end

    committed = valid_fixture('confirm_schedule_candidate.committed.response.json')
    assert committed['event_id'].present?
    assert committed['feedback_event_id'].present?

    %w[
      confirm_schedule_candidate.expired.response.json
      confirm_schedule_candidate.stale_snapshot.response.json
      revise_time_slot.infeasible.response.json
      reject_schedule_recommendation.response.json
    ].each do |fixture_name|
      refute tree_has_key?(valid_fixture(fixture_name), 'event_id'), fixture_name
    end
  end

  test 'reject records feedback but never persists an event' do
    response = valid_fixture('reject_schedule_recommendation.response.json')
    assert_equal 'recorded', response['status']
    assert_includes %w[rejected_all dismissed], response['action']
    assert response['feedback_event_id'].present?
    refute response.key?('event_id')
  end

  test 'state machine JSON is versioned exact and cannot bypass confirmation before commit' do
    machine = machine_json('state_machine.md') { |value| value.key?('states') && value.key?('transitions') }
    assert_equal '1.0', machine['schema_version']
    assert_equal STATES.sort, machine.fetch('states').sort

    transitions = normalize_transitions(machine.fetch('transitions'))
    assert_equal TRANSITIONS.sort, transitions.sort
    assert_equal ['confirmed'], machine.fetch('commit_entry_from')
    assert_equal FORBIDDEN_TRANSITIONS.sort,
                 normalize_transitions(machine.fetch('forbidden_transitions')).sort
    FORBIDDEN_TRANSITIONS.each do |transition|
      refute_includes transitions, transition
    end
    assert_equal [%w[confirmed committed]], transitions.select { |_from, to| to == 'committed' }
  end

  test 'feedback action registry is exact and versioned' do
    feedback = machine_json('feedback_learning.md') { |value| value.key?('actions') }
    assert_equal '1.0', feedback['schema_version']
    assert_equal FEEDBACK_ACTIONS.sort, feedback.fetch('actions').sort
  end

  test 'all normative requirement ids and off-by-default feature flags are documented' do
    NORMATIVE_IDS.each do |document_name, identifiers|
      document = document_text(document_name)
      identifiers.each { |identifier| assert_includes document, identifier, document_name }
      headings = document.scan(/^\*\*(SR-[A-Z]+-[0-9]{3})\b/).flatten
      assert_equal headings.uniq, headings, "duplicate normative ID in #{document_name}"
      assert_equal identifiers.sort, headings.sort, "unregistered normative ID in #{document_name}"
    end

    integration = document_text('integration_contract.md')
    FEATURE_FLAGS.each { |flag| assert_includes integration, flag }
  end

  test 'feedback identity privacy and logging invariants are normative' do
    integration = document_text('integration_contract.md')
    feedback = document_text('feedback_learning.md')
    privacy = document_text('privacy_and_logging.md')

    assert_contract_statement(integration, /server[- ]side/i, /user/i, /workspace/i)
    assert_contract_statement(feedback, /append[- ]only/i)
    assert_contract_statement(feedback, /not displayed|unshown|表示していない/i, /negative|負例/i)
    assert_contract_statement(feedback, /record_scheduling_feedback/, /not.*public|公開.*ない|internal/i)
    assert_contract_statement(privacy, /confirmation[_ ]token/i, /production/i, /log/i, /must not|禁止/i)
  end

  private

  def contract_data_mutations
    mutations = []
    add = lambda do |id, file, &mutation|
      instance = deep_copy(contract_data(file))
      mutation.call(instance)
      mutations << { id: id, file: file, instance: instance }
    end

    typed_paths = {
      'operation_error_matrix.json' => ['operation_error_codes'],
      'recommend_input_ownership.json' => ['inputs'],
      'semantic_invariants.json' => ['invariants'],
      'tool_manifest.json' => ['public_operations'],
      'confirmation_evidence_contract.json' => ['binding_fields'],
      'idempotency_lifecycle.json' => ['states'],
      'contract_invalid_field_matrix.json' => ['common_safe_fields']
    }
    CONTRACT_DATA_FILES.each do |file|
      add.call("#{file}:top_unknown", file) { |value| value['unexpected_top_level'] = true }
      add.call("#{file}:required_missing", file) { |value| value.delete('schema_version') }
      add.call("#{file}:wrong_type", file) { |value| write_path(value, typed_paths.fetch(file), {}) }
      add.call("#{file}:unexpected_null", file) { |value| write_path(value, typed_paths.fetch(file), nil) }
    end

    add.call('operation_matrix:nested_unknown', 'operation_error_matrix.json') do |value|
      value.fetch('operation_error_codes')['unexpected_operation'] = []
    end
    add.call('ownership:nested_unknown', 'recommend_input_ownership.json') do |value|
      value.fetch('inputs').first['unexpected_nested'] = true
    end
    add.call('semantic:nested_unknown', 'semantic_invariants.json') do |value|
      value.fetch('invariants').first['unexpected_nested'] = true
    end
    add.call('manifest:nested_unknown', 'tool_manifest.json') do |value|
      value.fetch('public_operations').first['unexpected_nested'] = true
    end
    add.call('evidence:nested_unknown', 'confirmation_evidence_contract.json') do |value|
      value.fetch('transitions').first['unexpected_nested'] = true
    end
    add.call('idempotency:nested_unknown', 'idempotency_lifecycle.json') do |value|
      value.fetch('retry_policy')['unexpected_nested'] = true
    end
    add.call('field_matrix:nested_unknown', 'contract_invalid_field_matrix.json') do |value|
      value.fetch('operation_safe_fields')['unexpected_operation'] = []
    end

    add.call('operation_matrix:schema_version', 'operation_error_matrix.json') { |value| value['schema_version'] = '2.0' }
    add.call('ownership:contract_identity', 'recommend_input_ownership.json') { |value| value['contract'] = 'other' }
    add.call('ownership:duplicate_input', 'recommend_input_ownership.json') do |value|
      value.fetch('inputs')[1] = deep_copy(value.fetch('inputs').first)
    end
    add.call('ownership:unknown_ownership', 'recommend_input_ownership.json') do |value|
      value.fetch('inputs').first['ownership'] = 'MODEL_GUESSED'
    end
    add.call('ownership:wire_path_mismatch', 'recommend_input_ownership.json') do |value|
      value.fetch('inputs').first['wire_path'] = 'duration_minutes'
    end

    add.call('semantic:duplicate_id', 'semantic_invariants.json') do |value|
      value.fetch('invariants')[1] = deep_copy(value.fetch('invariants').first)
    end
    add.call('semantic:duplicate_validator', 'semantic_invariants.json') do |value|
      value.fetch('invariants')[1]['validator'] = value.fetch('invariants').first.fetch('validator')
    end
    add.call('semantic:relation_missing', 'semantic_invariants.json') do |value|
      value.fetch('invariants').first.delete('relation')
    end
    add.call('semantic:required_context_missing', 'semantic_invariants.json') do |value|
      value.fetch('invariants').first.delete('required_context_paths')
    end
    add.call('semantic:duplicate_id_with_distinct_relation', 'semantic_invariants.json') do |value|
      value.fetch('invariants')[1] = deep_copy(value.fetch('invariants').first)
      value.fetch('invariants')[1]['relation'] = 'different relation under duplicate identity'
    end
    add.call('semantic:relation_changed', 'semantic_invariants.json') do |value|
      value.fetch('invariants').first['relation'] = 'different relation'
    end
    add.call('semantic:required_context_order_changed', 'semantic_invariants.json') do |value|
      value.fetch('invariants').first.fetch('required_context_paths').reverse!
    end
    add.call('semantic:unknown_applies_to', 'semantic_invariants.json') do |value|
      value.fetch('invariants').first['applies_to'] = ['unknown.operation']
    end
    add.call('semantic:schema_version', 'semantic_invariants.json') { |value| value['schema_version'] = '2.0' }

    add.call('manifest:identity', 'tool_manifest.json') { |value| value['manifest'] = 'other_manifest' }
    add.call('manifest:duplicate_operation', 'tool_manifest.json') do |value|
      value.fetch('public_operations')[1] = deep_copy(value.fetch('public_operations').first)
    end
    add.call('manifest:feedback_public', 'tool_manifest.json') do |value|
      value.fetch('public_operations').first['operation'] = 'record_scheduling_feedback'
    end
    add.call('manifest:broken_schema_ref', 'tool_manifest.json') do |value|
      value.fetch('public_operations').first['arguments_schema_ref'] = 'missing.schema.json#/$defs/arguments'
    end
    {
      'evidence_and_token' => [2, 8],
      'wire_validation_and_dispatch' => [10, 11],
      'response_validation_and_staging' => [12, 13],
      'staging_and_atomic_commit' => [13, 14]
    }.each do |label, (left, right)|
      add.call("manifest:adapter_sequence_swap_#{label}", 'tool_manifest.json') do |value|
        sequence = value.fetch('public_operations').find do |entry|
          entry.fetch('operation') == 'confirm_schedule_candidate'
        end.fetch('adapter_sequence')
        sequence[left], sequence[right] = sequence[right], sequence[left]
      end
    end
    add.call('manifest:idempotency_key_model_result', 'tool_manifest.json') do |value|
      confirm = value.fetch('public_operations').find do |entry|
        entry.fetch('operation') == 'confirm_schedule_candidate'
      end
      confirm.fetch('model_visible_projection').fetch('success') << 'idempotency_key'
    end
    add.call('manifest:idempotency_key_model_argument', 'tool_manifest.json') do |value|
      confirm = value.fetch('public_operations').find do |entry|
        entry.fetch('operation') == 'confirm_schedule_candidate'
      end
      confirm.fetch('model_visible_arguments') << 'idempotency_key'
    end
    add.call('manifest:confirmation_evidence_not_vault_only', 'tool_manifest.json') do |value|
      confirm = value.fetch('public_operations').find do |entry|
        entry.fetch('operation') == 'confirm_schedule_candidate'
      end
      confirm.fetch('vault_only_fields').delete('confirmation_evidence')
    end
    add.call('manifest:adapter_sequence_on_non_confirm', 'tool_manifest.json') do |value|
      recommend = value.fetch('public_operations').find do |entry|
        entry.fetch('operation') == 'recommend_time_slots'
      end
      confirm = value.fetch('public_operations').find do |entry|
        entry.fetch('operation') == 'confirm_schedule_candidate'
      end
      recommend['adapter_sequence'] = deep_copy(confirm.fetch('adapter_sequence'))
    end

    add.call('evidence:contract_identity', 'confirmation_evidence_contract.json') { |value| value['contract'] = 'other' }
    add.call('evidence:model_tool_is_evidence', 'confirmation_evidence_contract.json') do |value|
      value['model_tool_call_is_evidence'] = true
    end
    add.call('evidence:candidate_binding_missing', 'confirmation_evidence_contract.json') do |value|
      value.fetch('binding_fields').delete('candidate_id')
    end
    add.call('evidence:unknown_status', 'confirmation_evidence_contract.json') do |value|
      value.fetch('statuses')[-1] = 'unknown'
    end
    add.call('evidence:mismatched_transition', 'confirmation_evidence_contract.json') do |value|
      value.fetch('transitions').first['trigger'] = 'recommendation_expired'
    end
    {
      'tenant_and_evidence' => [0, 1],
      'evidence_and_binding' => [1, 2],
      'binding_and_attempt' => [2, 3],
      'attempt_and_key' => [3, 4],
      'key_and_token' => [4, 5]
    }.each do |label, (left, right)|
      add.call("evidence:pre_dispatch_swap_#{label}", 'confirmation_evidence_contract.json') do |value|
        sequence = value.fetch('pre_dispatch_order')
        sequence[left], sequence[right] = sequence[right], sequence[left]
      end
    end

    add.call('idempotency:contract_identity', 'idempotency_lifecycle.json') { |value| value['contract'] = 'other' }
    add.call('idempotency:unknown_state', 'idempotency_lifecycle.json') do |value|
      value.fetch('states')[-1] = 'unknown'
    end
    add.call('idempotency:unknown_transition', 'idempotency_lifecycle.json') do |value|
      value.fetch('transitions').first['to'] = 'committed'
    end
    add.call('idempotency:terminal_outgoing', 'idempotency_lifecycle.json') do |value|
      value.fetch('transitions').first['from'] = 'committed'
    end
    add.call('idempotency:retry_window_86399', 'idempotency_lifecycle.json') do |value|
      value.fetch('retry_policy')['logical_confirmation_retry_window_seconds'] = 86_399
    end
    add.call('idempotency:retention_86399', 'idempotency_lifecycle.json') do |value|
      value.fetch('retry_policy')['idempotency_result_minimum_retention_seconds'] = 86_399
    end
    add.call('idempotency:second_key_allowed', 'idempotency_lifecycle.json') do |value|
      value.fetch('allocation')['new_key_requires_new_authenticated_confirmation_evidence'] = false
    end
    add.call('idempotency:terminal_outgoing_flag', 'idempotency_lifecycle.json') do |value|
      value.fetch('terminal_result_policy')['terminal_states_have_outgoing_transitions'] = true
    end

    add.call('field_matrix:contract_identity', 'contract_invalid_field_matrix.json') { |value| value['contract'] = 'other' }
    add.call('field_matrix:confirmation_token_safe', 'contract_invalid_field_matrix.json') do |value|
      value.fetch('global_safe_fields')[-1] = 'confirmation_token'
    end
    add.call('field_matrix:cross_operation_safe', 'contract_invalid_field_matrix.json') do |value|
      value.fetch('operation_safe_fields').fetch('confirm_schedule_candidate')[-1] = 'time_zone'
    end

    mutations
  end

  def json_schemer_valid?(schema_name, instance)
    json_schemer(schema_json(schema_name)).valid?(instance)
  end

  def json_schemer_valid_ref?(schema_name, ref, instance)
    source_id = schema_json(schema_name).fetch('$id')
    wrapper = {
      '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
      '$id' => 'https://chronoflow.app/contracts/scheduling_recommendations/v1/test-crosscheck.schema.json',
      '$ref' => "#{source_id}#{ref}"
    }
    json_schemer(wrapper).valid?(instance)
  end

  def json_schemer(schema)
    JSONSchemer.schema(
      schema,
      ref_resolver: lambda do |uri|
        resource = uri.dup
        resource.fragment = nil
        json_schemer_documents.fetch(resource.normalize.to_s)
      end
    )
  end

  def json_schemer_documents
    @json_schemer_documents ||= SCHEMA_FILES.each_with_object({}) do |schema_name, documents|
      document = schema_json(schema_name)
      documents[URI.parse(document.fetch('$id')).normalize.to_s] = document
    end
  end

  def control_variants(value)
    middle = value.length / 2
    {
      'trailing_lf' => value + CONTROL_MUTATIONS.fetch('trailing_lf'),
      'trailing_cr' => value + CONTROL_MUTATIONS.fetch('trailing_cr'),
      'trailing_u2028' => value + CONTROL_MUTATIONS.fetch('trailing_u2028'),
      'trailing_u2029' => value + CONTROL_MUTATIONS.fetch('trailing_u2029'),
      'leading_lf' => CONTROL_MUTATIONS.fetch('leading_lf') + value,
      'embedded_nul' => value.dup.insert(middle, CONTROL_MUTATIONS.fetch('embedded_nul')),
      'embedded_vt' => value.dup.insert(middle, CONTROL_MUTATIONS.fetch('embedded_vt')),
      'embedded_ff' => value.dup.insert(middle, CONTROL_MUTATIONS.fetch('embedded_ff')),
      'embedded_nel' => value.dup.insert(middle, CONTROL_MUTATIONS.fetch('embedded_nel')),
      'embedded_del' => value.dup.insert(middle, CONTROL_MUTATIONS.fetch('embedded_del'))
    }
  end

  def semantic_required_context_sample
    recommendation = deep_copy(valid_fixture('recommend_time_slots.response.json'))
    revision = deep_copy(valid_fixture('revise_time_slot.feasible.response.json'))
    committed = deep_copy(valid_fixture('confirm_schedule_candidate.committed.response.json'))
    rejected = deep_copy(valid_fixture('reject_schedule_recommendation.response.json'))
    request = deep_copy(valid_fixture('recommend_time_slots.request.json'))
      .merge(deep_copy(valid_fixture('confirm_schedule_candidate.request.json')))
      .merge(deep_copy(valid_fixture('reject_schedule_recommendation.request.json')))
    response = recommendation.merge(revision).merge(committed).merge(rejected)
    {
      'request' => request,
      'response' => response,
      'recommendation' => recommendation,
      'revision' => revision,
      'payload' => recommendation
    }
  end

  def delete_json_path(value, json_path)
    parts = json_path.delete_prefix('$.').split('.')
    parent = parts[0...-1].reduce(value) { |current, part| current.fetch(part) }
    parent.delete(parts.last)
  end

  def confirmation_evidence_samples
    evidence = {
      'evidence_id' => 'evidence_fixed_0001',
      'status' => 'active',
      'authenticated_user_id' => 'user_fixed_0001',
      'authenticated_workspace_id' => 'workspace_fixed_0001',
      'recommendation_id' => 'rec_schedule_0001',
      'candidate_id' => 'cand_slot_0001',
      'revision_id' => 'rev_slot_0001',
      'final_slot_canonical_fingerprint' => 'slot_sha256_fixed_0001',
      'pre_commit_schedule_snapshot_version' => 'sch_snapshot_0001',
      'recommendation_expires_at' => '2026-08-30T09:15:00+09:00'
    }
    request = evidence.slice(
      'recommendation_id', 'candidate_id', 'revision_id', 'final_slot_canonical_fingerprint',
      'pre_commit_schedule_snapshot_version', 'recommendation_expires_at'
    )
    tenant = evidence.slice('authenticated_user_id', 'authenticated_workspace_id')
    [evidence, request, tenant]
  end

  def write_temp_schema(directory, name, value)
    File.binwrite(File.join(directory, name), JSON.pretty_generate(value))
  end

  def assert_contract_error(expected_code, &block)
    error = assert_raises(SchedulingRecommendationsV1SubsetValidator::ContractValidationError, &block)
    assert_includes error.flattened.map(&:code), expected_code.to_s, error.message
    error
  end

  def error_definition_for(operation, code)
    ERROR_DEFINITION_BY_OPERATION_AND_CODE.fetch([operation, code]) do
      case code
      when 'INVALID_TIME_WINDOW' then 'INVALID_TIME_WINDOW_RECOMMEND'
      when 'INVALID_DURATION' then 'INVALID_DURATION_RECOMMEND'
      else code
      end
    end
  end

  def sample_error(definition_name)
    definition = schema_json('error.schema.json').fetch('$defs').fetch(definition_name)
    properties = definition.fetch('properties')
    {
      'code' => properties.fetch('code').fetch('const'),
      'message_code' => properties.fetch('message_code').fetch('const'),
      'retryable' => properties.fetch('retryable').fetch('const'),
      'details' => deep_copy(ERROR_DETAILS_SAMPLES.fetch(definition_name))
    }
  end

  def mutate_error(definition_name)
    error = sample_error(definition_name)
    yield error
    error
  end

  def wire_error_response(operation, error)
    response = {
      'schema_version' => '1.0',
      'operation' => operation,
      'status' => 'error',
      'request_id' => "req_#{operation}_0001",
      'trace_id' => "trc_#{operation}_0001",
      'error' => error
    }
    if operation == 'revise_time_slot'
      response['constraint_policy'] = { 'travel_time_unknown' => 'advisory' }
    end
    response
  end

  def response_error_codes(schema_name)
    schema = schema_json(schema_name)
    branch = schema.fetch('oneOf').find { |entry| entry.dig('properties', 'status', 'const') == 'error' }
    refs = branch.fetch('properties').fetch('error').fetch('oneOf').map { |entry| entry.fetch('$ref') }
    definitions = schema_json('error.schema.json').fetch('$defs')
    refs.map do |reference|
      definition_name = reference.split('/').last
      definitions.fetch(definition_name).fetch('properties').fetch('code').fetch('const')
    end
  end

  def model_argument_samples
    @model_argument_samples ||= {
      'recommend_time_slots' => pick_fields(
        valid_fixture('recommend_time_slots.request.json'), %w[title duration_minutes search_window]
      ),
      'revise_time_slot' => pick_fields(
        valid_fixture('revise_time_slot.request.json'),
        %w[recommendation_id candidate_id proposed_slot optional_change_reason]
      ),
      'confirm_schedule_candidate' => pick_fields(
        valid_fixture('confirm_schedule_candidate.request.json'), %w[recommendation_id candidate_id revision_id]
      ),
      'reject_schedule_recommendation' => pick_fields(
        valid_fixture('reject_schedule_recommendation.request.json'),
        %w[recommendation_id action optional_reason]
      )
    }.transform_values { |value| deep_copy(value).freeze }.freeze
  end

  def model_result_samples
    @model_result_samples ||= begin
      recommendation = valid_fixture('recommend_time_slots.response.json')
      recommendation_result = pick_fields(recommendation, %w[status recommendation_id expires_at])
      recommendation_result['candidates'] = recommendation.fetch('candidates').map do |candidate|
        pick_fields(candidate, %w[candidate_id rank slot reason_codes penalty_codes score])
      end

      revision = valid_fixture('revise_time_slot.feasible.response.json')
      {
        'recommend_time_slots' => recommendation_result,
        'revise_time_slot' => pick_fields(
          revision,
          %w[status recommendation_id candidate_id revision_id expires_at revised_candidate requires_confirmation]
        ),
        'confirm_schedule_candidate' => pick_fields(
          valid_fixture('confirm_schedule_candidate.committed.response.json'),
          %w[status recommendation_id candidate_id revision_id final_slot]
        ),
        'reject_schedule_recommendation' => pick_fields(
          valid_fixture('reject_schedule_recommendation.response.json'), %w[status recommendation_id action]
        )
      }.transform_values { |value| deep_copy(value).freeze }.freeze
    end
  end

  def pick_fields(object, names)
    names.each_with_object({}) do |name, selected|
      selected[name] = deep_copy(object.fetch(name)) if object.key?(name)
    end
  end

  def semantic_valid_exchanges
    recommendation = valid_fixture('recommend_time_slots.response.json')
    revision = valid_fixture('revise_time_slot.feasible.response.json')
    exchanges = {
      'recommend success' => {
        request: valid_fixture('recommend_time_slots.request.json'), response: recommendation
      },
      'revise success' => {
        request: valid_fixture('revise_time_slot.request.json'), response: revision,
        recommendation: recommendation
      },
      'confirm committed' => {
        request: valid_fixture('confirm_schedule_candidate.request.json'),
        response: valid_fixture('confirm_schedule_candidate.committed.response.json'),
        recommendation: recommendation, revision: revision
      },
      'reject recorded' => {
        request: valid_fixture('reject_schedule_recommendation.request.json'),
        response: valid_fixture('reject_schedule_recommendation.response.json')
      }
    }
    VALID_FIXTURES.each_key do |fixture_name|
      payload = valid_fixture(fixture_name)
      next unless payload['status'] == 'error'

      exchanges["#{fixture_name} exchange"] = { request: request_for_response(payload), response: payload }
    end
    exchanges
  end

  def request_for_response(response)
    fixture_name = {
      'recommend_time_slots' => 'recommend_time_slots.request.json',
      'revise_time_slot' => 'revise_time_slot.request.json',
      'confirm_schedule_candidate' => 'confirm_schedule_candidate.request.json',
      'reject_schedule_recommendation' => 'reject_schedule_recommendation.request.json'
    }.fetch(response.fetch('operation'))
    request = deep_copy(valid_fixture(fixture_name))
    request['request_id'] = response.fetch('request_id')
    request['trace_id'] = response.fetch('trace_id')
    request
  end

  def assert_structural_then_semantic_failure(label, invariant_id, path, schema_name, payload)
    assert @validator.valid?(schema_name, payload), "#{label} must remain structurally valid"
    assert_semantic_failure(label, invariant_id, path, @semantic_validator.validate_payload(payload))
  end

  def assert_exchange_semantic_failure(label, invariant_id, path, context)
    request = context.fetch(:request)
    response = context.fetch(:response)
    assert @validator.valid?("#{request.fetch('operation')}.request.schema.json", request),
           "#{label} request must remain structurally valid"
    assert @validator.valid?("#{response.fetch('operation')}.response.schema.json", response),
           "#{label} response must remain structurally valid"
    assert_semantic_failure(label, invariant_id, path, @semantic_validator.validate_exchange(**context))
  end

  def assert_semantic_failure(label, invariant_id, path, failures)
    actual = failures.map { |failure| [failure.invariant_id, failure.path] }
    assert_includes actual, [invariant_id, path], "#{label}: #{actual.inspect}"
  end

  def expected_json_files
    (SCHEMA_FILES + CONTRACT_DATA_FILES).map { |name| SCHEMA_ROOT.join(name) } +
      VALID_FIXTURES.keys.map { |name| FIXTURE_ROOT.join('valid', name) } +
      INVALID_FIXTURES.keys.map { |name| FIXTURE_ROOT.join('invalid', name) }
  end

  def request_and_response_schema_names
    SCHEMA_FILES.grep(/\.(?:request|response)\.schema\.json\z/)
  end

  def schema_json(name)
    @schema_json ||= {}
    @schema_json[name] ||= JSON.parse(File.binread(SCHEMA_ROOT.join(name)))
  end

  def contract_data(name)
    @contract_data ||= {}
    @contract_data[name] ||= JSON.parse(File.binread(SCHEMA_ROOT.join(name)))
  end

  def valid_fixture(name)
    fixture_json('valid', name)
  end

  def invalid_fixture(name)
    fixture_json('invalid', name)
  end

  def fixture_json(kind, name)
    @fixture_json ||= {}
    key = [kind, name]
    @fixture_json[key] ||= JSON.parse(
      File.binread(FIXTURE_ROOT.join(kind, name)), decimal_class: BigDecimal
    )
  end

  def document_text(name)
    File.binread(DOC_ROOT.join(name)).force_encoding(Encoding::UTF_8)
  end

  def schema_contains_const?(schema_name, property, expected)
    property_consts(schema_name, property).include?(expected)
  end

  def property_consts(schema_name, property)
    values = []
    each_schema_node(schema_name) do |node|
      properties = node['properties']
      next unless properties.is_a?(Hash) && properties[property].is_a?(Hash)

      property_schema = properties.fetch(property)
      values << property_schema['const'] if property_schema.key?('const')
      if property_schema.key?('$ref')
        _document, resolved = resolve_test_ref(property_schema.fetch('$ref'), schema_path_for(schema_name))
        values << resolved['const'] if resolved.is_a?(Hash) && resolved.key?('const')
      end
    end
    values.uniq
  end

  def assert_closed_object_schemas(node, label, path = '$')
    return unless node.is_a?(Hash)

    object_shaped = node['type'] == 'object' || Array(node['type']).include?('object')
    if object_shaped
      assert_equal false, node['additionalProperties'], "#{label} #{path} must be closed"
    end

    if node['properties'].is_a?(Hash)
      node['properties'].each do |name, child|
        assert_closed_object_schemas(child, label, "#{path}/properties/#{name}")
      end
    end
    if node['$defs'].is_a?(Hash)
      node['$defs'].each do |name, child|
        assert_closed_object_schemas(child, label, "#{path}/$defs/#{name}")
      end
    end
    Array(node['oneOf']).each_with_index do |child, index|
      assert_closed_object_schemas(child, label, "#{path}/oneOf/#{index}")
    end
    assert_closed_object_schemas(node['items'], label, "#{path}/items") if node.key?('items')
    if node['additionalProperties'].is_a?(Hash)
      assert_closed_object_schemas(node['additionalProperties'], label, "#{path}/additionalProperties")
    end
  end

  def all_declared_property_names(node)
    return [] unless node.is_a?(Hash)

    names = node.fetch('properties', {}).keys
    child_schemas = []
    child_schemas.concat(node.fetch('$defs', {}).values) if node['$defs'].is_a?(Hash)
    child_schemas.concat(node.fetch('properties', {}).values) if node['properties'].is_a?(Hash)
    child_schemas.concat(node.fetch('oneOf', [])) if node['oneOf'].is_a?(Array)
    child_schemas << node['items'] if node['items'].is_a?(Hash)
    child_schemas.concat([node['additionalProperties']]) if node['additionalProperties'].is_a?(Hash)
    (names + child_schemas.flat_map { |child| all_declared_property_names(child) }).uniq
  end

  def all_declared_property_names_for_ref(schema_name, ref)
    document, node = resolve_test_ref(ref, schema_path_for(schema_name))
    names = Set.new
    walk_schema_node(node, document, Set.new) do |schema|
      names.merge(schema.fetch('properties', {}).keys) if schema['properties'].is_a?(Hash)
    end
    names.to_a
  end

  def schema_path_for(schema_name)
    SCHEMA_ROOT.join(schema_name).expand_path.cleanpath
  end

  def each_schema_node(schema_name, &block)
    path = schema_path_for(schema_name)
    walk_schema_node(schema_json(schema_name), path, Set.new, &block)
  end

  def walk_schema_node(node, document, visited, &block)
    return unless node.is_a?(Hash)

    identity = [document.to_s, node.object_id]
    return if visited.include?(identity)

    visited.add(identity)
    yield node

    if node.key?('$ref')
      target_document, target = resolve_test_ref(node.fetch('$ref'), document)
      walk_schema_node(target, target_document, visited, &block)
    end

    children = []
    children.concat(node.fetch('$defs', {}).values) if node['$defs'].is_a?(Hash)
    children.concat(node.fetch('properties', {}).values) if node['properties'].is_a?(Hash)
    children.concat(node.fetch('oneOf', [])) if node['oneOf'].is_a?(Array)
    children << node['items'] if node['items'].is_a?(Hash)
    children << node['additionalProperties'] if node['additionalProperties'].is_a?(Hash)
    children.each { |child| walk_schema_node(child, document, visited, &block) }
  end

  def resolve_test_ref(ref, source_document)
    file_part, fragment = ref.split('#', 2)
    document = if file_part.nil? || file_part.empty?
                 source_document
               else
                 source_document.dirname.join(file_part).expand_path.cleanpath
               end
    value = @test_schema_documents[document.to_s] ||= JSON.parse(File.binread(document))
    unless fragment.nil? || fragment.empty?
      value = fragment.split('/').drop(1).reduce(value) do |current, token|
        current.fetch(token.gsub('~1', '/').gsub('~0', '~'))
      end
    end
    [document, value]
  end

  def assert_registry(schema_name, expected)
    schema = schema_json(schema_name)
    assert_equal 'string', schema['type'], schema_name
    assert_equal expected.sort, schema.fetch('enum').sort, schema_name
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def find_path(value, path = [], &block)
    case value
    when Hash
      value.each do |key, child|
        return path + [key] if yield(child, key)
        found = find_path(child, path + [key], &block)
        return found if found
      end
    when Array
      value.each_with_index do |child, index|
        found = find_path(child, path + [index], &block)
        return found if found
      end
    end
    nil
  end

  def write_path(value, path, replacement)
    parent = path[0...-1].reduce(value) { |current, key| current.fetch(key) }
    parent[path.last] = replacement
  end

  def date_time_with_seconds(value, seconds)
    replacement = value.sub(
      /:\d{2}(?=(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z)/,
      ":#{seconds}"
    )
    raise ArgumentError, "date-time seconds not found: #{value.inspect}" if replacement == value

    replacement
  end

  def delete_path(value, path)
    parent = path[0...-1].reduce(value) { |current, key| current.fetch(key) }
    parent.delete(path.last)
  end

  def hash_paths(value, path = [], paths = [])
    case value
    when Hash
      paths << path
      value.each { |key, child| hash_paths(child, path + [key], paths) }
    when Array
      value.each_with_index { |child, index| hash_paths(child, path + [index], paths) }
    end
    paths
  end

  def all_valid_payloads
    VALID_FIXTURES.keys.map { |name| [name, valid_fixture(name)] }
  end

  def assert_ordered_time_pair(payload, start_key, end_key, label)
    each_hash(payload) do |object|
      next unless object.key?(start_key) && object.key?(end_key)

      assert_operator Time.iso8601(object.fetch(start_key)), :<, Time.iso8601(object.fetch(end_key)), label
    end
  end

  def assert_ordered_named_windows(payload, label)
    each_hash(payload) do |object|
      next unless object.key?('start_at') && object.key?('end_at')

      assert_operator Time.iso8601(object.fetch('start_at')), :<, Time.iso8601(object.fetch('end_at')), label
    end
  end

  def assert_slot_consistency(payload, label)
    each_hash(payload) do |object|
      next unless object.key?('start_at') && object.key?('end_at') && object.key?('duration_minutes')

      seconds = Time.iso8601(object.fetch('end_at')) - Time.iso8601(object.fetch('start_at'))
      assert_equal object.fetch('duration_minutes') * 60, seconds, label
    end
  end

  def assert_unique_candidate_fields(payload, label)
    each_hash(payload) do |object|
      candidates = object['candidates']
      next unless candidates.is_a?(Array)

      ranks = candidates.map { |candidate| candidate['rank'] }
      ids = candidates.map { |candidate| candidate['candidate_id'] }
      assert_equal ranks.uniq, ranks, "duplicate rank in #{label}"
      assert_equal ids.uniq, ids, "duplicate candidate_id in #{label}"
    end
  end

  def each_hash(value, &block)
    case value
    when Hash
      yield value
      value.each_value { |child| each_hash(child, &block) }
    when Array
      value.each { |child| each_hash(child, &block) }
    end
  end

  def tree_has_key?(value, key)
    case value
    when Hash
      value.key?(key) || value.each_value.any? { |child| tree_has_key?(child, key) }
    when Array
      value.any? { |child| tree_has_key?(child, key) }
    else
      false
    end
  end

  def machine_json(document_name)
    blocks = document_text(document_name).scan(/```json\s*\n(.*?)```/m).flatten
    parsed = blocks.map { |block| JSON.parse(block) }
    parsed.find { |value| value.is_a?(Hash) && yield(value) } ||
      flunk("#{document_name} is missing its required machine-readable JSON block")
  end

  def normalize_transitions(transitions)
    transitions.map do |transition|
      if transition.is_a?(Hash)
        [transition.fetch('from'), transition.fetch('to')]
      elsif transition.is_a?(Array) && transition.length == 2
        transition
      else
        flunk("invalid transition entry: #{transition.inspect}")
      end
    end
  end

  def assert_contract_statement(document, *patterns)
    patterns.each do |pattern|
      assert_match pattern, document,
                   "missing normative contract language matching #{pattern.inspect}"
    end
  end
end
