# frozen_string_literal: true

module SchedulingKnowledge
  module CanonicalText
    class InvalidTextError < ArgumentError; end

    # Evidence offsets refer to Unicode codepoints in this text, not bytes or
    # grapheme clusters. Do not trim or Unicode-normalize the source.
    def self.normalize(text)
      unless text.is_a?(String) && text.encoding == Encoding::UTF_8 && text.valid_encoding?
        raise InvalidTextError, "knowledge text must be valid UTF-8"
      end
      raise InvalidTextError, "knowledge text must not contain NUL" if text.include?("\u0000")

      normalized = text.gsub(/\r\n?/, "\n")
      if normalized.match?(/\A[[:space:]]*\z/)
        raise InvalidTextError, "knowledge text must contain content"
      end

      normalized
    end
  end
end
