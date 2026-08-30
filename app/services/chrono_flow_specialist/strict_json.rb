# frozen_string_literal: true

require "json"

module ChronoFlowSpecialist
  module StrictJson
    class ParseError < StandardError; end
    class DuplicateKeyError < ParseError; end

    class DuplicateAwareHash < Hash
      def []=(key, value)
        raise DuplicateKeyError, "duplicate JSON key" if key?(key)

        super
      end
    end

    module_function

    def parse(source)
      JSON.parse(
        String(source),
        object_class: DuplicateAwareHash,
        array_class: Array,
        create_additions: false,
        allow_nan: false,
        max_nesting: 100
      )
    rescue DuplicateKeyError
      raise
    rescue JSON::ParserError, EncodingError, TypeError
      raise ParseError, "invalid JSON"
    end
  end
end
