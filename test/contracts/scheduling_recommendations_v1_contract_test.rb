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
      validation_failure!(path, 'is not an RFC 3339 date-time with an explicit offset', code: :format)
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
    if pattern.start_with?('^') && pattern.end_with?('$')
      Regexp.new("\\A(?:#{pattern[1...-1]})\\z")
    else
      Regexp.new(pattern)
    end
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
  Failure = Struct.new(:invariant_id, :path, :message, keyword_init: true)

  INVARIANT_IDS = (1..17).map { |number| format('SR-SEM-%03d', number) }.freeze

  def validate_payload(payload)
    failures = []
    operation = payload['operation']
    status = payload['status']

    if operation == 'recommend_time_slots' && !payload.key?('status')
      ordered_pair(failures, 'SR-SEM-001', payload['search_window'], '$.search_window')
    end
    if operation == 'recommend_time_slots' && status == 'success'
      ordered_values(
        failures, 'SR-SEM-002', payload['generated_at'], payload['expires_at'], '$.generated_at', '$.expires_at'
      )
      validate_recommendation_candidates(failures, payload)
    end

    each_hash(payload) do |object, path|
      next unless %w[start_at end_at duration_minutes].all? { |key| object.key?(key) }

      ordered_pair(failures, 'SR-SEM-003', object, path)
      validate_duration(failures, object, path)
    end

    if operation == 'revise_time_slot' && status == 'success' && payload['revised_candidate'].is_a?(Hash)
      revised = payload.fetch('revised_candidate')
      compare_exact(failures, 'SR-SEM-008', revised['recommendation_id'], payload['recommendation_id'],
                    '$.revised_candidate.recommendation_id')
      compare_exact(failures, 'SR-SEM-009', revised['candidate_id'], payload['candidate_id'],
                    '$.revised_candidate.candidate_id')
      compare_exact(failures, 'SR-SEM-010', revised['revision_id'], payload['revision_id'],
                    '$.revised_candidate.revision_id')
    end

    failures
  end

  def validate_exchange(request:, response:, recommendation: nil, revision: nil)
    failures = validate_payload(request) + validate_payload(response)
    %w[request_id trace_id].each do |field|
      compare_exact(failures, 'SR-SEM-011', response[field], request[field], "$.response.#{field}")
    end

    operation = request['operation']
    if operation == 'revise_time_slot' && response['status'] == 'success' && recommendation
      compare_exact(failures, 'SR-SEM-012', response['expires_at'], recommendation['expires_at'],
                    '$.response.expires_at')
    end

    if operation == 'confirm_schedule_candidate' && response['status'] == 'committed'
      validate_confirm_exchange(failures, request, response, recommendation, revision)
    elsif operation == 'reject_schedule_recommendation' && response['status'] == 'recorded'
      %w[recommendation_id action].each do |field|
        compare_exact(failures, 'SR-SEM-016', response[field], request[field], "$.response.#{field}")
      end
    end

    if response['status'] == 'error'
      %w[request_id trace_id].each do |field|
        compare_exact(failures, 'SR-SEM-017', response[field], request[field], "$.response.#{field}")
      end
    end
    failures
  end

  private

  def validate_recommendation_candidates(failures, payload)
    candidates = payload['candidates']
    return unless candidates.is_a?(Array)

    ids = candidates.map { |candidate| candidate['candidate_id'] }
    unless ids.uniq.length == ids.length
      add_failure(failures, 'SR-SEM-005', '$.candidates', 'candidate_id values must be unique')
    end

    ranks = candidates.map { |candidate| candidate['rank'] }
    expected_ranks = (1..candidates.length).to_a
    unless ranks.uniq.length == ranks.length && ranks.sort == expected_ranks
      add_failure(failures, 'SR-SEM-006', '$.candidates', 'ranks must be unique and exactly 1..candidate_count')
    end

    candidates.each_with_index do |candidate, index|
      compare_exact(
        failures, 'SR-SEM-007', candidate['recommendation_id'], payload['recommendation_id'],
        "$.candidates[#{index}].recommendation_id"
      )
    end
  end

  def validate_confirm_exchange(failures, request, response, recommendation, revision)
    %w[recommendation_id candidate_id].each do |field|
      compare_exact(failures, 'SR-SEM-013', response[field], request[field], "$.response.#{field}")
    end
    if request.key?('revision_id')
      compare_exact(failures, 'SR-SEM-013', response['revision_id'], request['revision_id'], '$.response.revision_id')
    elsif response.key?('revision_id')
      add_failure(failures, 'SR-SEM-013', '$.response.revision_id', 'must be absent when request has no revision_id')
    end

    if response['schedule_snapshot_version'] == request['schedule_snapshot_version']
      add_failure(
        failures, 'SR-SEM-014', '$.response.schedule_snapshot_version',
        'committed snapshot must differ from the pre-commit request snapshot'
      )
    end

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

  def add_failure(failures, invariant_id, path, message)
    failures << Failure.new(invariant_id: invariant_id, path: path, message: message)
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
    reason_codes.json
    penalty_codes.json
    error_codes.json
  ].freeze

  CONTRACT_DATA_FILES = %w[
    operation_error_matrix.json
    recommend_input_ownership.json
    semantic_invariants.json
    tool_manifest.json
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
    ['revise_time_slot', 'INVALID_DURATION'] => 'INVALID_DURATION_REVISE'
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
        confirmation_token_consumption_state schedule_snapshot_version idempotency_state event_id
        feedback_event_id user_id workspace_id
      ],
      'vault_only_fields' => %w[
        confirmation_token schedule_snapshot_version idempotency_key idempotency_state event_id
        feedback_event_id user_id workspace_id
      ],
      'redacted_fields' => %w[
        schema_version operation request_id trace_id confirmation_token schedule_snapshot_version
        idempotency_key event_id feedback_event_id committed_at error.details
      ],
      'model_visible_projection' => {
        'success' => %w[status recommendation_id candidate_id revision_id final_slot],
        'error' => %w[status code message_code retryable]
      }
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
    confirmation_token schedule_snapshot_version idempotency_key user_id workspace_id authorization
    cookie access_token refresh_token api_key secret feedback_event_id event_id
  ].freeze

  SEMANTIC_INVARIANT_IDS = (1..17).map { |number| format('SR-SEM-%03d', number) }.freeze
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
    'SR-SEM-017' => 'error_correlation_binding'
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
    ],
    'state_machine.md' => %w[SR-STATE-001 SR-STATE-002],
    'feedback_learning.md' => %w[
      SR-FEEDBACK-001 SR-FEEDBACK-002 SR-FEEDBACK-003 SR-FEEDBACK-004 SR-FEEDBACK-005
    ],
    'privacy_and_logging.md' => %w[
      SR-PRIVACY-001 SR-PRIVACY-002 SR-PRIVACY-003 SR-PRIVACY-004
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
    @semantic_validator = SchedulingRecommendationsV1SemanticValidator.new
    @test_schema_documents = {}
  end

  test 'all contract schemas and fixtures are valid JSON and every schema audits fail closed' do
    actual_json_files = Dir[SCHEMA_ROOT.join('*.json').to_s] + Dir[FIXTURE_ROOT.join('**', '*.json').to_s]
    assert_equal expected_json_files.map(&:to_s).sort, actual_json_files.sort
    assert_equal 57, actual_json_files.length
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

  test 'semantic mutations mechanically reject all seventeen cross-field invariants at exact paths' do
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
