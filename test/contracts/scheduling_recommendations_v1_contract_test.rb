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

# This deliberately small validator is test-only. It implements exactly the
# Draft 2020-12 keywords used by the scheduling recommendation v1 contracts and
# rejects every other assertion keyword. That makes an accidentally unsupported
# schema change fail closed instead of silently weakening the contract tests.
class SchedulingRecommendationsV1SubsetValidator
  class ContractValidationError < StandardError; end

  DRAFT_2020_12 = 'https://json-schema.org/draft/2020-12/schema'
  JSON_SAFE_INTEGER_MAX = 9_007_199_254_740_991
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

  def initialize(schema_root)
    @schema_root = Pathname.new(schema_root).expand_path.cleanpath
    @documents = {}
    @audit_state = {}
    @active_audit_refs = Set.new
  end

  def audit!(schema_name)
    document = schema_path(schema_name)
    audit_document!(document)
    true
  end

  def valid?(schema_name, instance)
    validate!(schema_name, instance)
    true
  rescue ContractValidationError
    false
  end

  def validate!(schema_name, instance)
    document = schema_path(schema_name)
    audit_document!(document)
    validate_schema!(instance, document_for(document), document, '$', Set.new)
    true
  end

  private

  def schema_path(schema_name)
    candidate = schema_root.join(schema_name.to_s).expand_path.cleanpath
    ensure_inside_schema_root!(candidate)
    candidate
  end

  def ensure_inside_schema_root!(candidate)
    root = schema_root.to_s
    path = candidate.to_s
    return if path == root || path.start_with?(root + File::SEPARATOR)

    schema_failure!(candidate, '$ref escapes the scheduling contract directory')
  end

  def document_for(path)
    clean_path = Pathname.new(path).expand_path.cleanpath
    ensure_inside_schema_root!(clean_path)
    @documents[clean_path.to_s] ||= begin
      parsed = JSON.parse(File.binread(clean_path.to_s), decimal_class: BigDecimal)
      unless parsed.is_a?(Hash)
        schema_failure!(clean_path, 'schema document root must be an object')
      end
      parsed
    rescue Errno::ENOENT
      schema_failure!(clean_path, 'referenced schema file does not exist')
    rescue JSON::ParserError => error
      schema_failure!(clean_path, "schema is not JSON: #{error.message}")
    end
  end

  def audit_document!(path)
    clean_path = Pathname.new(path).expand_path.cleanpath
    state = @audit_state[clean_path.to_s]
    return if state == :complete || state == :active

    @audit_state[clean_path.to_s] = :active
    audit_schema!(document_for(clean_path), clean_path, '$')
    @audit_state[clean_path.to_s] = :complete
  rescue StandardError
    @audit_state.delete(clean_path.to_s)
    raise
  end

  def audit_schema!(schema, document, location)
    unless schema.is_a?(Hash)
      schema_failure!(document, "#{location} must be a schema object")
    end

    unknown = schema.keys.reject { |keyword| ALLOWED_KEYWORDS.include?(keyword) }
    unless unknown.empty?
      schema_failure!(document, "#{location} uses unsupported keyword(s): #{unknown.sort.join(', ')}")
    end

    audit_annotations!(schema, document, location)
    audit_type!(schema['type'], document, location) if schema.key?('type')
    audit_ref!(schema['$ref'], document, location) if schema.key?('$ref')
    audit_defs!(schema['$defs'], document, location) if schema.key?('$defs')
    audit_required!(schema['required'], document, location) if schema.key?('required')
    audit_properties!(schema['properties'], document, location) if schema.key?('properties')
    audit_additional_properties!(schema['additionalProperties'], document, location) if schema.key?('additionalProperties')
    audit_schema!(schema['items'], document, "#{location}/items") if schema.key?('items')
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
    audit_one_of!(schema['oneOf'], document, location) if schema.key?('oneOf')
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

  def audit_ref!(ref, document, location)
    unless ref.is_a?(String) && !ref.empty?
      schema_failure!(document, "#{location}/$ref must be a non-empty string")
    end

    target_document, target_schema = resolve_ref(ref, document)
    audit_document!(target_document)
    unless target_schema.is_a?(Hash)
      schema_failure!(document, "#{location}/$ref must resolve to a schema object")
    end

    target_key = [target_document.to_s, target_schema.object_id]
    return if @active_audit_refs.include?(target_key)

    @active_audit_refs.add(target_key)
    begin
      audit_schema!(target_schema, target_document, "#{location}/$ref")
    ensure
      @active_audit_refs.delete(target_key)
    end
  end

  def audit_defs!(defs, document, location)
    unless defs.is_a?(Hash) && defs.keys.all? { |name| name.is_a?(String) && !name.empty? }
      schema_failure!(document, "#{location}/$defs must be an object with non-empty names")
    end

    defs.each do |name, definition|
      audit_schema!(definition, document, "#{location}/$defs/#{escape_pointer(name)}")
    end
  end

  def audit_required!(required, document, location)
    unless required.is_a?(Array) && required.all? { |name| name.is_a?(String) } && required.uniq == required
      schema_failure!(document, "#{location}/required must contain unique property names")
    end
  end

  def audit_properties!(properties, document, location)
    unless properties.is_a?(Hash) && properties.keys.all? { |name| name.is_a?(String) }
      schema_failure!(document, "#{location}/properties must be an object")
    end

    properties.each do |name, subschema|
      audit_schema!(subschema, document, "#{location}/properties/#{escape_pointer(name)}")
    end
  end

  def audit_additional_properties!(value, document, location)
    return if value == true || value == false

    audit_schema!(value, document, "#{location}/additionalProperties")
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

  def audit_one_of!(branches, document, location)
    unless branches.is_a?(Array) && !branches.empty?
      schema_failure!(document, "#{location}/oneOf must contain at least one schema")
    end

    branches.each_with_index do |branch, index|
      audit_schema!(branch, document, "#{location}/oneOf/#{index}")
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

  def resolve_ref(ref, source_document)
    if ref.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/) || ref.start_with?('/')
      schema_failure!(source_document, "non-local $ref is forbidden: #{ref}")
    end

    file_part, fragment = ref.split('#', 2)
    target_document = if file_part.nil? || file_part.empty?
                        Pathname.new(source_document).expand_path.cleanpath
                      else
                        decoded = URI::DEFAULT_PARSER.unescape(file_part)
                        Pathname.new(source_document).dirname.join(decoded).expand_path.cleanpath
                      end
    ensure_inside_schema_root!(target_document)
    target = document_for(target_document)
    target = resolve_fragment(target, fragment, target_document) unless fragment.nil? || fragment.empty?
    [target_document, target]
  end

  def resolve_fragment(document, fragment, document_path)
    unless fragment.start_with?('/')
      schema_failure!(document_path, "only JSON Pointer fragments are supported: ##{fragment}")
    end

    fragment.split('/').drop(1).reduce(document) do |current, raw_token|
      token = URI::DEFAULT_PARSER.unescape(raw_token).gsub('~1', '/').gsub('~0', '~')
      unless current.is_a?(Hash) && current.key?(token)
        schema_failure!(document_path, "unresolvable JSON Pointer fragment: ##{fragment}")
      end
      current.fetch(token)
    end
  end

  def validate_schema!(instance, schema, document, path, active_refs)
    if schema.key?('$ref')
      target_document, target_schema = resolve_ref(schema.fetch('$ref'), document)
      reference_key = [target_document.to_s, target_schema.object_id, path]
      if active_refs.include?(reference_key)
        validation_failure!(path, 'non-progressing recursive $ref')
      end

      next_refs = active_refs.dup.add(reference_key)
      validate_schema!(instance, target_schema, target_document, path, next_refs)
    end

    if schema.key?('oneOf')
      matches = schema.fetch('oneOf').count do |branch|
        begin
          validate_schema!(instance, branch, document, path, active_refs.dup)
          true
        rescue ContractValidationError
          false
        end
      end
      validation_failure!(path, "oneOf matched #{matches} branches") unless matches == 1
    end

    if schema.key?('const') && !json_equal?(instance, schema.fetch('const'))
      validation_failure!(path, 'does not match const')
    end
    if schema.key?('enum') && schema.fetch('enum').none? { |entry| json_equal?(instance, entry) }
      validation_failure!(path, 'is not in enum')
    end

    validate_type!(instance, schema.fetch('type'), path) if schema.key?('type')
    validate_object!(instance, schema, document, path, active_refs) if instance.is_a?(Hash)
    validate_array!(instance, schema, document, path, active_refs) if instance.is_a?(Array)
    validate_string!(instance, schema, path) if instance.is_a?(String)
    validate_number!(instance, schema, path) if json_number?(instance)
  end

  def validate_type!(instance, declared, path)
    types = declared.is_a?(Array) ? declared : [declared]
    return if types.any? { |type| type_match?(instance, type) }

    validation_failure!(path, "does not match type #{types.join(' or ')}")
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

  def validate_object!(instance, schema, document, path, active_refs)
    required = schema.fetch('required', [])
    required.each do |name|
      validation_failure!(path, "is missing required property #{name}") unless instance.key?(name)
    end

    properties = schema.fetch('properties', {})
    instance.each do |name, value|
      if properties.key?(name)
        validate_schema!(value, properties.fetch(name), document, property_path(path, name), active_refs.dup)
      elsif schema.key?('additionalProperties')
        additional = schema.fetch('additionalProperties')
        validation_failure!(property_path(path, name), 'is an additional property') if additional == false
        if additional.is_a?(Hash)
          validate_schema!(value, additional, document, property_path(path, name), active_refs.dup)
        end
      end
    end
  end

  def validate_array!(instance, schema, document, path, active_refs)
    if schema.key?('minItems') && instance.length < schema.fetch('minItems')
      validation_failure!(path, 'contains too few items')
    end
    if schema.key?('maxItems') && instance.length > schema.fetch('maxItems')
      validation_failure!(path, 'contains too many items')
    end
    if schema['uniqueItems'] && duplicate_json_item?(instance)
      validation_failure!(path, 'contains duplicate items')
    end
    return unless schema.key?('items')

    instance.each_with_index do |item, index|
      validate_schema!(item, schema.fetch('items'), document, "#{path}[#{index}]", active_refs.dup)
    end
  end

  def validate_string!(instance, schema, path)
    length = instance.each_char.count
    if schema.key?('minLength') && length < schema.fetch('minLength')
      validation_failure!(path, 'is shorter than minLength')
    end
    if schema.key?('maxLength') && length > schema.fetch('maxLength')
      validation_failure!(path, 'is longer than maxLength')
    end
    if schema.key?('pattern') && !compile_json_pattern(schema.fetch('pattern')).match?(instance)
      validation_failure!(path, 'does not match pattern')
    end
    if schema['format'] == 'date-time' && !rfc3339_with_offset?(instance)
      validation_failure!(path, 'is not an RFC 3339 date-time with an explicit offset')
    end
  end

  def validate_number!(instance, schema, path)
    if schema.key?('minimum') && instance < schema.fetch('minimum')
      validation_failure!(path, 'is less than minimum')
    end
    if schema.key?('maximum') && instance > schema.fetch('maximum')
      validation_failure!(path, 'is greater than maximum')
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
      return nil unless value.finite? && value.abs <= JSON_SAFE_INTEGER_MAX

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

  def validation_failure!(path, message)
    raise ContractValidationError, "#{path} #{message}"
  end

  def schema_failure!(document, message)
    raise ContractValidationError, "#{document}: #{message}"
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
    reason_codes.json
    penalty_codes.json
    error_codes.json
  ].freeze

  VALID_FIXTURES = {
    'recommend_time_slots.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.response.json' => 'recommend_time_slots.response.schema.json',
    'revise_time_slot.request.json' => 'revise_time_slot.request.schema.json',
    'revise_time_slot.feasible.response.json' => 'revise_time_slot.response.schema.json',
    'revise_time_slot.infeasible.response.json' => 'revise_time_slot.response.schema.json',
    'confirm_schedule_candidate.request.json' => 'confirm_schedule_candidate.request.schema.json',
    'confirm_schedule_candidate.committed.response.json' => 'confirm_schedule_candidate.response.schema.json',
    'confirm_schedule_candidate.expired.response.json' => 'confirm_schedule_candidate.response.schema.json',
    'confirm_schedule_candidate.stale_snapshot.response.json' => 'confirm_schedule_candidate.response.schema.json',
    'reject_schedule_recommendation.request.json' => 'reject_schedule_recommendation.request.schema.json',
    'reject_schedule_recommendation.response.json' => 'reject_schedule_recommendation.response.schema.json'
  }.freeze

  INVALID_FIXTURES = {
    'recommend_time_slots.missing_schema_version.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.unknown_field.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.invalid_operation.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.invalid_datetime.request.json' => 'recommend_time_slots.request.schema.json',
    'recommend_time_slots.unknown_reason_code.response.json' => 'recommend_time_slots.response.schema.json',
    'recommend_time_slots.unknown_penalty_code.response.json' => 'recommend_time_slots.response.schema.json',
    'revise_time_slot.unknown_error_code.response.json' => 'revise_time_slot.response.schema.json',
    'confirm_schedule_candidate.cross_binding.request.json' => 'confirm_schedule_candidate.request.schema.json',
    'confirm_schedule_candidate.missing_confirmation_token.request.json' => 'confirm_schedule_candidate.request.schema.json',
    'confirm_schedule_candidate.missing_idempotency_key.request.json' => 'confirm_schedule_candidate.request.schema.json'
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
    @validator = SchedulingRecommendationsV1SubsetValidator.new(SCHEMA_ROOT)
  end

  test 'all contract schemas and fixtures are valid JSON and every schema audits fail closed' do
    expected_json_files.each do |path|
      assert_nothing_raised { JSON.parse(File.binread(path)) }
    end

    SCHEMA_FILES.each do |schema_name|
      assert @validator.audit!(schema_name), schema_name
    end
  end

  test 'the subset validator rejects unsupported schema keywords instead of ignoring them' do
    invalid_schema = {
      'type' => 'string',
      'minLength' => 1,
      'unsupportedAssertion' => true
    }

    assert_raises(SchedulingRecommendationsV1SubsetValidator::ContractValidationError) do
      @validator.send(:audit_schema!, invalid_schema, SCHEMA_ROOT.join('inline-test.schema.json'), '$')
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
    INVALID_FIXTURES.each do |fixture_name, schema_name|
      refute @validator.valid?(schema_name, invalid_fixture(fixture_name)), fixture_name
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
    branch_mapping = error_schema.fetch('oneOf').each_with_object({}) do |branch, result|
      properties = branch.fetch('properties')
      result[properties.fetch('code').fetch('const')] = properties.fetch('message_code').fetch('const')
    end
    assert_equal ERROR_MESSAGE_CODES, branch_mapping
    assert_equal ERROR_MESSAGE_CODES.values.sort,
                 error_schema.fetch('properties').fetch('message_code').fetch('enum').sort
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

  test 'referenced annotation content is audited and unsupported assertions fail closed' do
    Dir.mktmpdir('scheduling-contract-schema') do |directory|
      File.write(
        File.join(directory, 'unsupported.schema.json'),
        JSON.generate(
          '$schema' => SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12,
          'type' => 'object',
          'default' => { 'minProperties' => 1 },
          '$ref' => '#/default'
        )
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(directory)

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
            "enum": [9007199254740993.0]
          }
        JSON
      )
      validator = SchedulingRecommendationsV1SubsetValidator.new(directory)

      refute validator.valid?('unsafe-number.schema.json', 9_007_199_254_740_992)
      rounded_instance = JSON.parse('9007199254740993.0')
      refute validator.valid?('unsafe-number.schema.json', rounded_instance)

      File.write(
        File.join(directory, 'precise-decimal.schema.json'),
        <<~JSON
          {
            "$schema": "#{SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12}",
            "enum": [0.100000000000000005]
          }
        JSON
      )
      refute validator.valid?('precise-decimal.schema.json', 0.1)

      File.write(
        File.join(directory, 'equal-number.schema.json'),
        <<~JSON
          {
            "$schema": "#{SchedulingRecommendationsV1SubsetValidator::DRAFT_2020_12}",
            "enum": [1.0]
          }
        JSON
      )
      assert validator.valid?('equal-number.schema.json', 1), 'JSON numbers 1 and 1.0 must compare equally'
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

  def expected_json_files
    SCHEMA_FILES.map { |name| SCHEMA_ROOT.join(name) } +
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

  def valid_fixture(name)
    fixture_json('valid', name)
  end

  def invalid_fixture(name)
    fixture_json('invalid', name)
  end

  def fixture_json(kind, name)
    @fixture_json ||= {}
    key = [kind, name]
    @fixture_json[key] ||= JSON.parse(File.binread(FIXTURE_ROOT.join(kind, name)))
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
    value = JSON.parse(File.binread(document))
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
    JSON.parse(JSON.generate(value))
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
