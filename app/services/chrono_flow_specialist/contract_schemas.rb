# frozen_string_literal: true

require "pathname"

module ChronoFlowSpecialist
  class ContractSchemas
    FILES = {
      request: "specialist_request.schema.json",
      response: "specialist_response.schema.json",
      error: "specialist_error.schema.json",
      action_proposal: "action_proposal.schema.json"
    }.freeze

    def initialize(root: Rails.root.join("contracts", "ai_secretary_home", "v2.1"))
      @root = Pathname(root)
      @loaded = {}
    end

    FILES.each_key do |name|
      define_method(name) { load_schema(name) }
    end

    def validator(name)
      JsonSchemaValidator.new(load_schema(name), resolver: method(:resolve_reference))
    end

    private

    def load_schema(name)
      @loaded[name] ||= begin
        parsed = StrictJson.parse(File.binread(@root.join(FILES.fetch(name))))
        raise Errors::Error.new(:service_unavailable) unless parsed.is_a?(Hash)

        deep_freeze(parsed)
      rescue Errno::ENOENT, Errno::EACCES, StrictJson::ParseError
        raise Errors::Error.new(:service_unavailable)
      end
    end

    def resolve_reference(reference)
      file_name = reference.to_s.split("#", 2).first
      name = FILES.key(file_name)
      raise KeyError unless name

      load_schema(name)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end
end
