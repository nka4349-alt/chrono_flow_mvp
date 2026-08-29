# frozen_string_literal: true

require 'date'
require 'json'
require 'set'

module Specialists
  module Contracts
    class SchemaValidator
      DRAFT_2020_12 = 'https://json-schema.org/draft/2020-12/schema'
      SUPPORTED_TYPES = Set.new(%w[object array string integer number boolean null]).freeze
      SUPPORTED_KEYWORDS = Set.new(
        %w[
          $schema $id title description $defs $ref oneOf const enum type required
          properties additionalProperties items minLength maxLength maxItems
          uniqueItems minimum maximum format
        ]
      ).freeze
      SCHEMA_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.json\z/
      SAFE_PATH_PATTERN = /\A\$(?:\.[A-Za-z][A-Za-z0-9_]*|\[\d+\])*\z/
      RFC3339_DATE_TIME_PATTERN = /\A
        (?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})
        [Tt](?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})(?:\.\d+)?
        (?:[Zz]|[+-](?<offset_hour>\d{2}):(?<offset_minute>\d{2}))
      \z/x

      Document = Struct.new(:name, :path, :schema, keyword_init: true)

      class ValidationError < StandardError
        attr_reader :schema_name, :path

        def initialize(schema_name:, path:)
          @schema_name = File.basename(schema_name.to_s)
          @schema_name = 'unknown.schema.json' unless @schema_name.match?(SCHEMA_NAME_PATTERN)
          @path = path.to_s.match?(SAFE_PATH_PATTERN) ? path.to_s : '$'
          super("Schema validation failed for #{@schema_name} at #{@path}")
        end
      end

      def self.default_schema_directory
        Rails.root.join('contracts/ai_secretary_home/v2.1')
      end

      def self.validate!(data, schema_name:, schema_directory: default_schema_directory)
        new(schema_directory: schema_directory).validate!(data, schema_name: schema_name)
      end

      def initialize(schema_directory: self.class.default_schema_directory)
        @schema_directory = File.expand_path(schema_directory.to_s)
        @documents = {}
        @preflighted_documents = Set.new
        @preflighting_documents = Set.new
      end

      def validate!(data, schema_name:)
        document = load_document(schema_name)
        validate_value!(data, document.schema, document, '$')
        true
      end

      def resolve_ref!(schema_name:, ref:)
        document = load_document(schema_name)
        resolve_reference(document, ref, '$')
        true
      end

      private

      attr_reader :schema_directory, :documents, :preflighted_documents, :preflighting_documents

      def load_document(schema_name, reporting_name: schema_name)
        name = schema_name.to_s
        validation_failure!(reporting_name, '$') unless valid_schema_name?(name)

        path = File.expand_path(name, schema_directory)
        validation_failure!(reporting_name, '$') unless File.dirname(path) == schema_directory && File.file?(path)
        validation_failure!(reporting_name, '$') unless File.dirname(File.realpath(path)) == real_schema_directory

        return documents.fetch(path) if documents.key?(path)

        schema = JSON.parse(File.binread(path))
        validation_failure!(reporting_name, '$') unless schema.is_a?(Hash)

        document = Document.new(name: name, path: path, schema: schema)
        documents[path] = document
        preflight_document!(document)
        document
      rescue ValidationError
        documents.delete(path) if defined?(path) && !preflighted_documents.include?(path)
        raise
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, ArgumentError
        documents.delete(path) if defined?(path)
        validation_failure!(reporting_name, '$')
      end

      def real_schema_directory
        @real_schema_directory ||= File.realpath(schema_directory)
      rescue Errno::ENOENT, Errno::EACCES
        validation_failure!('unknown.schema.json', '$')
      end

      def valid_schema_name?(name)
        name.match?(SCHEMA_NAME_PATTERN) && File.basename(name) == name
      end

      def preflight_document!(document)
        return if preflighted_documents.include?(document.path)
        return if preflighting_documents.include?(document.path)

        preflighting_documents.add(document.path)
        validation_failure!(document.name, '$') unless document.schema['$schema'] == DRAFT_2020_12
        validate_schema_node!(document.schema, document)
        preflighted_documents.add(document.path)
      ensure
        preflighting_documents.delete(document.path)
      end

      def validate_schema_node!(schema, document)
        validation_failure!(document.name, '$') unless schema.is_a?(Hash)
        validation_failure!(document.name, '$') unless (schema.keys.to_set - SUPPORTED_KEYWORDS).empty?

        validate_schema_annotations!(schema, document)
        validate_schema_composition!(schema, document)
        validate_schema_types!(schema, document)
        validate_schema_object_keywords!(schema, document)
        validate_schema_array_keywords!(schema, document)
        validate_schema_scalar_keywords!(schema, document)
      end

      def validate_schema_annotations!(schema, document)
        if schema.key?('$schema')
          validation_failure!(document.name, '$') unless schema['$schema'] == DRAFT_2020_12
        end

        %w[$id title description].each do |keyword|
          next unless schema.key?(keyword)

          validation_failure!(document.name, '$') unless schema[keyword].is_a?(String)
        end
      end

      def validate_schema_composition!(schema, document)
        if schema.key?('$ref')
          validation_failure!(document.name, '$') unless schema['$ref'].is_a?(String)
          resolve_reference(document, schema['$ref'], '$')
        end

        if schema.key?('$defs')
          definitions = schema['$defs']
          validation_failure!(document.name, '$') unless definitions.is_a?(Hash)
          definitions.each_value { |definition| validate_schema_node!(definition, document) }
        end

        if schema.key?('oneOf')
          branches = schema['oneOf']
          validation_failure!(document.name, '$') unless branches.is_a?(Array) && branches.any?
          branches.each { |branch| validate_schema_node!(branch, document) }
        end

        if schema.key?('enum')
          choices = schema['enum']
          validation_failure!(document.name, '$') unless choices.is_a?(Array) && choices.any?
        end
      end

      def validate_schema_types!(schema, document)
        return unless schema.key?('type')

        types = Array(schema['type'])
        valid = types.any? && types.all? { |type| type.is_a?(String) && SUPPORTED_TYPES.include?(type) }
        validation_failure!(document.name, '$') unless valid && types.uniq.length == types.length
      end

      def validate_schema_object_keywords!(schema, document)
        if schema.key?('required')
          required = schema['required']
          valid = required.is_a?(Array) && required.all? { |name| name.is_a?(String) }
          validation_failure!(document.name, '$') unless valid && required.uniq.length == required.length
        end

        if schema.key?('properties')
          properties = schema['properties']
          validation_failure!(document.name, '$') unless properties.is_a?(Hash)
          properties.each do |name, property_schema|
            validation_failure!(document.name, '$') unless name.is_a?(String)
            validate_schema_node!(property_schema, document)
          end
        end

        return unless schema.key?('additionalProperties')

        validation_failure!(document.name, '$') unless [true, false].include?(schema['additionalProperties'])
      end

      def validate_schema_array_keywords!(schema, document)
        validate_schema_node!(schema['items'], document) if schema.key?('items')

        if schema.key?('maxItems')
          validation_failure!(document.name, '$') unless non_negative_integer?(schema['maxItems'])
        end

        return unless schema.key?('uniqueItems')

        validation_failure!(document.name, '$') unless [true, false].include?(schema['uniqueItems'])
      end

      def validate_schema_scalar_keywords!(schema, document)
        %w[minLength maxLength].each do |keyword|
          next unless schema.key?(keyword)

          validation_failure!(document.name, '$') unless non_negative_integer?(schema[keyword])
        end

        if schema.key?('minLength') && schema.key?('maxLength')
          validation_failure!(document.name, '$') if schema['minLength'] > schema['maxLength']
        end

        %w[minimum maximum].each do |keyword|
          next unless schema.key?(keyword)

          validation_failure!(document.name, '$') unless finite_number?(schema[keyword])
        end

        if schema.key?('minimum') && schema.key?('maximum')
          validation_failure!(document.name, '$') if schema['minimum'] > schema['maximum']
        end

        return unless schema.key?('format')

        validation_failure!(document.name, '$') unless schema['format'] == 'date-time'
      end

      def validate_value!(value, schema, document, path)
        if schema.key?('$ref')
          referenced_document, referenced_schema = resolve_reference(document, schema['$ref'], path)
          validate_value!(value, referenced_schema, referenced_document, path)
        end

        validate_one_of!(value, schema['oneOf'], document, path) if schema.key?('oneOf')
        validate_type!(value, schema['type'], document.name, path) if schema.key?('type')
        validation_failure!(document.name, path) if schema.key?('const') && value != schema['const']
        validation_failure!(document.name, path) if schema.key?('enum') && !schema['enum'].include?(value)

        validate_object!(value, schema, document, path) if value.is_a?(Hash)
        validate_array!(value, schema, document, path) if value.is_a?(Array)
        validate_string!(value, schema, document.name, path) if value.is_a?(String)
        validate_number!(value, schema, document.name, path) if finite_number?(value)
      end

      def validate_one_of!(value, branches, document, path)
        matches = branches.count do |branch|
          validate_value!(value, branch, document, path)
          true
        rescue ValidationError
          false
        end
        validation_failure!(document.name, path) unless matches == 1
      end

      def validate_type!(value, declared_type, schema_name, path)
        types = Array(declared_type)
        validation_failure!(schema_name, path) unless types.any? { |type| type_match?(value, type) }
      end

      def type_match?(value, type)
        case type
        when 'object' then value.is_a?(Hash)
        when 'array' then value.is_a?(Array)
        when 'string' then value.is_a?(String)
        when 'integer' then value.is_a?(Integer)
        when 'number' then finite_number?(value)
        when 'boolean' then value == true || value == false
        when 'null' then value.nil?
        else false
        end
      end

      def validate_object!(value, schema, document, path)
        logical_keys = value.keys.map(&:to_s)
        validation_failure!(document.name, path) unless logical_keys.uniq.length == logical_keys.length

        Array(schema['required']).each do |name|
          validation_failure!(document.name, property_path(path, name)) unless property_present?(value, name)
        end

        properties = schema.fetch('properties', {})
        properties.each do |name, property_schema|
          next unless property_present?(value, name)

          validate_value!(property_value(value, name), property_schema, document, property_path(path, name))
        end

        return unless schema['additionalProperties'] == false
        return if value.keys.all? { |key| properties.key?(key.to_s) }

        validation_failure!(document.name, path)
      end

      def validate_array!(value, schema, document, path)
        if schema.key?('items')
          value.each_with_index do |item, index|
            validate_value!(item, schema['items'], document, "#{path}[#{index}]")
          end
        end

        validation_failure!(document.name, path) if schema.key?('maxItems') && value.length > schema['maxItems']
        return unless schema['uniqueItems'] && value.uniq.length != value.length

        validation_failure!(document.name, path)
      end

      def validate_string!(value, schema, schema_name, path)
        validation_failure!(schema_name, path) if schema.key?('minLength') && value.length < schema['minLength']
        validation_failure!(schema_name, path) if schema.key?('maxLength') && value.length > schema['maxLength']
        return unless schema['format'] == 'date-time'

        validation_failure!(schema_name, path) unless valid_rfc3339_date_time?(value)
      end

      def validate_number!(value, schema, schema_name, path)
        validation_failure!(schema_name, path) if schema.key?('minimum') && value < schema['minimum']
        validation_failure!(schema_name, path) if schema.key?('maximum') && value > schema['maximum']
      end

      def property_present?(object, name)
        object.key?(name) || object.key?(name.to_sym)
      end

      def property_value(object, name)
        object.key?(name) ? object[name] : object[name.to_sym]
      end

      def property_path(path, name)
        candidate = "#{path}.#{name}"
        candidate.match?(SAFE_PATH_PATTERN) ? candidate : path
      end

      def resolve_reference(document, reference, path)
        validation_failure!(document.name, path) unless reference.is_a?(String) && reference.count('#') <= 1

        file_name, separator, fragment = reference.partition('#')
        target_document = if file_name.empty?
                            document
                          else
                            load_document(file_name, reporting_name: document.name)
                          end
        target = separator.empty? || fragment.empty? ? target_document.schema : resolve_fragment(target_document, fragment, path)
        validation_failure!(document.name, path) unless target.is_a?(Hash)

        [target_document, target]
      end

      def resolve_fragment(document, fragment, path)
        validation_failure!(document.name, path) unless fragment.start_with?('/') && !fragment.include?('%')

        fragment.delete_prefix('/').split('/', -1).reduce(document.schema) do |current, encoded_token|
          token = decode_pointer_token(encoded_token, document.name, path)
          case current
          when Hash
            validation_failure!(document.name, path) unless current.key?(token)
            current[token]
          when Array
            validation_failure!(document.name, path) unless token.match?(/\A(?:0|[1-9]\d*)\z/)
            index = token.to_i
            validation_failure!(document.name, path) unless index < current.length
            current[index]
          else
            validation_failure!(document.name, path)
          end
        end
      end

      def decode_pointer_token(token, schema_name, path)
        validation_failure!(schema_name, path) if token.match?(/~(?:[^01]|\z)/)
        token.gsub('~1', '/').gsub('~0', '~')
      end

      def non_negative_integer?(value)
        value.is_a?(Integer) && value >= 0
      end

      def valid_rfc3339_date_time?(value)
        match = RFC3339_DATE_TIME_PATTERN.match(value)
        return false unless match

        date_valid = Date.valid_date?(match[:year].to_i, match[:month].to_i, match[:day].to_i)
        time_valid = match[:hour].to_i <= 23 && match[:minute].to_i <= 59 && match[:second].to_i <= 60
        leap_second_valid = match[:second].to_i < 60 || (match[:hour] == '23' && match[:minute] == '59')
        offset_valid = if match[:offset_hour]
                         match[:offset_hour].to_i <= 23 && match[:offset_minute].to_i <= 59
                       else
                         true
                       end

        date_valid && time_valid && leap_second_valid && offset_valid
      end

      def finite_number?(value)
        return false unless value.is_a?(Numeric)

        !value.respond_to?(:finite?) || value.finite?
      end

      def validation_failure!(schema_name, path)
        raise ValidationError.new(schema_name: schema_name, path: path)
      end
    end
  end
end
