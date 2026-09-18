# frozen_string_literal: true

require "digest"
require_relative "canonical_text"

module SchedulingKnowledge
  class Chunker
    class OversizedAtomError < ArgumentError; end

    TARGET_MIN_CHARACTERS = 300
    TARGET_MAX_CHARACTERS = 800
    MAX_CHARACTERS = 1_200

    def self.call(canonical_text:)
      new(canonical_text).call
    end

    def initialize(canonical_text)
      normalized = CanonicalText.normalize(canonical_text)
      unless normalized == canonical_text
        raise CanonicalText::InvalidTextError, "knowledge text must already be canonical"
      end

      @text = canonical_text
      @chunks = []
      @headings = []
    end

    def call
      page_start = 0
      @text.split("\f", -1).each_with_index do |page, index|
        chunk_page(page, page_start, index + 1)
        page_start += page.length + 1
      end
      @chunks
    end

    private

    # ATX headings start a section. Paragraphs (including contiguous table
    # headers and rows) remain indivisible, even when they exceed the soft
    # target. A heading is kept with its first paragraph where one exists.
    def chunk_page(page, page_start, page_number)
      section_start = 0
      line_start = 0
      starts_with_heading = false
      page.each_line do |line|
        if (heading = heading_match(line))
          chunk_section(page, page_start, page_number, section_start, line_start, starts_with_heading)
          level = heading[1].length
          @headings.pop while @headings.last && @headings.last.first >= level
          @headings << [level, heading[2]]
          section_start = line_start
          starts_with_heading = true
        end
        line_start += line.length
      end
      chunk_section(page, page_start, page_number, section_start, page.length, starts_with_heading)
    end

    def heading_match(line)
      line.chomp.match(/\A {0,3}(\#{1,6})[ \t]+(.+?)(?:[ \t]+\#+)?[ \t]*\z/)
    end

    def chunk_section(page, page_start, page_number, section_start, section_end, starts_with_heading)
      atoms = paragraph_spans(page[section_start...section_end], page_start + section_start)
      if starts_with_heading && atoms.length > 1 && heading_only?(atoms.first)
        atoms[0, 2] = [[atoms.first.first, atoms[1].last]]
      end

      pending = nil
      atoms.each do |atom|
        if atom.last - atom.first > MAX_CHARACTERS
          raise OversizedAtomError, "knowledge semantic block exceeds 1200 codepoints"
        end

        if pending && atom.last - pending.first <= TARGET_MAX_CHARACTERS
          pending = [pending.first, atom.last]
        else
          emit(pending, page_number) if pending
          pending = atom
        end
      end
      emit(pending, page_number) if pending
    end

    def paragraph_spans(section, global_start)
      spans = []
      paragraph_start = nil
      paragraph_end = nil
      position = global_start
      section.each_line do |line|
        if line.match?(/\A[[:space:]]*\z/)
          spans << [paragraph_start, paragraph_end] if paragraph_start
          paragraph_start = nil
        else
          paragraph_start ||= position
          paragraph_end = position + line.length
        end
        position += line.length
      end
      spans << [paragraph_start, paragraph_end] if paragraph_start
      spans
    end

    def heading_only?(span)
      content = @text[span.first...span.last]
      content.lines.length == 1 && heading_match(content)
    end

    def emit(span, page_number)
      content = @text[span.first...span.last]
      @chunks << {
        sequence: @chunks.length,
        section_path_json: @headings.map(&:last),
        page_number: page_number,
        character_start: span.first,
        character_end: span.last,
        content: content,
        content_sha256: Digest::SHA256.hexdigest(content)
      }
    end
  end
end
