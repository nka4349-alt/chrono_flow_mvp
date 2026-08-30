# frozen_string_literal: true

require "time"

module ChronoFlowSpecialist
  class JsonSchemaValidator
    ValidationIssue = Struct.new(:path, :keyword, keyword_init: true)

    def initialize(schema, resolver: nil)
      @schema = schema
      @resolver = resolver
    end

    def validate(instance)
      issues = []
      validate_node(@schema, instance, "$", @schema, issues)
      issues
    end

    def valid?(instance)
      validate(instance).empty?
    end

    private

    def validate_node(schema, value, path, root_schema, issues)
      return unless schema.is_a?(Hash)

      if schema.key?("$ref")
        referenced_schema, referenced_root = resolve_reference(schema.fetch("$ref"), root_schema)
        return add_issue(issues, path, "$ref") unless referenced_schema

        validate_node(referenced_schema, value, path, referenced_root, issues)
        return
      end

      if schema.key?("oneOf")
        matches = schema.fetch("oneOf").count do |candidate|
          candidate_issues = []
          validate_node(candidate, value, path, root_schema, candidate_issues)
          candidate_issues.empty?
        end
        add_issue(issues, path, "oneOf") unless matches == 1
        return unless matches == 1
      end

      validate_type(schema, value, path, issues)
      return if schema.key?("type") && !type_matches?(schema.fetch("type"), value)

      add_issue(issues, path, "const") if schema.key?("const") && value != schema.fetch("const")
      add_issue(issues, path, "enum") if schema.key?("enum") && !schema.fetch("enum").include?(value)

      case value
      when Hash then validate_object(schema, value, path, root_schema, issues)
      when Array then validate_array(schema, value, path, root_schema, issues)
      when String then validate_string(schema, value, path, issues)
      when Numeric then validate_number(schema, value, path, issues)
      end
    end

    def validate_type(schema, value, path, issues)
      return unless schema.key?("type")
      return if type_matches?(schema.fetch("type"), value)

      add_issue(issues, path, "type")
    end

    def type_matches?(expected, value)
      Array(expected).any? do |type|
        case type
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "string" then value.is_a?(String)
        when "integer" then value.is_a?(Integer)
        when "number" then value.is_a?(Numeric) && (!value.is_a?(Float) || value.finite?)
        when "boolean" then value == true || value == false
        when "null" then value.nil?
        else false
        end
      end
    end

    def validate_object(schema, value, path, root_schema, issues)
      Array(schema["required"]).each do |name|
        add_issue(issues, child_path(path, name), "required") unless value.key?(name)
      end

      properties = schema.fetch("properties", {})
      value.each do |name, child|
        if properties.key?(name)
          validate_node(properties.fetch(name), child, child_path(path, name), root_schema, issues)
        elsif schema["additionalProperties"] == false
          add_issue(issues, child_path(path, name), "additionalProperties")
        elsif schema["additionalProperties"].is_a?(Hash)
          validate_node(schema.fetch("additionalProperties"), child, child_path(path, name), root_schema, issues)
        end
      end
    end

    def validate_array(schema, value, path, root_schema, issues)
      add_issue(issues, path, "maxItems") if schema.key?("maxItems") && value.length > schema.fetch("maxItems")
      add_issue(issues, path, "minItems") if schema.key?("minItems") && value.length < schema.fetch("minItems")
      add_issue(issues, path, "uniqueItems") if schema["uniqueItems"] && value.uniq.length != value.length
      return unless schema["items"].is_a?(Hash)

      value.each_with_index do |child, index|
        validate_node(schema.fetch("items"), child, "#{path}[#{index}]", root_schema, issues)
      end
    end

    def validate_string(schema, value, path, issues)
      add_issue(issues, path, "minLength") if schema.key?("minLength") && value.length < schema.fetch("minLength")
      add_issue(issues, path, "maxLength") if schema.key?("maxLength") && value.length > schema.fetch("maxLength")
      add_issue(issues, path, "pattern") if schema.key?("pattern") && !Regexp.new(schema.fetch("pattern")).match?(value)
      return unless schema["format"] == "date-time"

      begin
        Time.iso8601(value)
        raise ArgumentError unless value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      rescue ArgumentError
        add_issue(issues, path, "format")
      end
    end

    def validate_number(schema, value, path, issues)
      add_issue(issues, path, "minimum") if schema.key?("minimum") && value < schema.fetch("minimum")
      add_issue(issues, path, "maximum") if schema.key?("maximum") && value > schema.fetch("maximum")
    end

    def resolve_reference(reference, root_schema)
      if reference.start_with?("#")
        [json_pointer(root_schema, reference.delete_prefix("#")), root_schema]
      elsif @resolver
        resolved = @resolver.call(reference)
        [resolved, resolved]
      end
    rescue KeyError, ArgumentError
      [nil, root_schema]
    end

    def json_pointer(root, pointer)
      return root if pointer.empty?
      raise ArgumentError unless pointer.start_with?("/")

      pointer.split("/").drop(1).reduce(root) do |node, token|
        node.fetch(token.gsub("~1", "/").gsub("~0", "~"))
      end
    end

    def child_path(path, name)
      name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? "#{path}.#{name}" : "#{path}[#{name.inspect}]"
    end

    def add_issue(issues, path, keyword)
      issues << ValidationIssue.new(path: path, keyword: keyword)
    end
  end
end
