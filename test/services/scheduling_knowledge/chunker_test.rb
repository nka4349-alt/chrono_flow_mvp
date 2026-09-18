# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../app/services/scheduling_knowledge/canonical_text"
require_relative "../../../app/services/scheduling_knowledge/chunker"

class SchedulingKnowledgeChunkerTest < Minitest::Test
  def test_canonicalization_only_changes_line_endings
    original = "  受付\r\ne\u0301 👨‍👩‍👧‍👦\r次の行\f次頁  "
    canonical = SchedulingKnowledge::CanonicalText.normalize(original)

    assert_equal "  受付\ne\u0301 👨‍👩‍👧‍👦\n次の行\f次頁  ", canonical
    assert_equal "  受付\r\ne\u0301 👨‍👩‍👧‍👦\r次の行\f次頁  ", original
    refute_includes canonical, "é"
    assert_traceable(canonical, chunk(canonical))
  end

  def test_invalid_encoding_type_and_empty_text_have_bounded_errors
    [nil, 12, "", " \n\t\f", "受付\u0000本文", "\xff".b.force_encoding(Encoding::UTF_8), "受付".b].each do |invalid|
      error = assert_raises(SchedulingKnowledge::CanonicalText::InvalidTextError) do
        SchedulingKnowledge::CanonicalText.normalize(invalid)
      end
      assert_operator error.message.length, :<, 80
    end
    assert_raises(SchedulingKnowledge::CanonicalText::InvalidTextError) { chunk("受付\r\n本文") }
  end

  def test_unicode_offsets_count_codepoints_instead_of_bytes_or_graphemes
    canonical = "e\u0301😀\f受付には15分必要です。"
    chunks = chunk(canonical)

    assert_equal 3, chunks[0][:character_end]
    assert_equal 4, chunks[1][:character_start]
    assert_equal [1, 2], chunks.map { |item| item[:page_number] }
    assert_traceable(canonical, chunks)
  end

  def test_pages_and_sections_are_never_combined_and_headings_keep_ancestry
    canonical = "# 施設案内\n\n受付は1階です。\n\n## 入館 ##\n\n15分前に到着。\f次頁も入館の説明。\n# 帰宅\n退館は裏口。"
    chunks = chunk(canonical)

    assert_equal [["施設案内"], ["施設案内", "入館"], ["施設案内", "入館"], ["帰宅"]],
                 chunks.map { |item| item[:section_path_json] }
    assert_equal [1, 1, 2, 2], chunks.map { |item| item[:page_number] }
    assert chunks.none? { |item| item[:content].include?("\f") }
    assert_includes chunks[0][:content], "受付は1階です。"
    assert_includes chunks[1][:content], "15分前に到着。"
    assert_traceable(canonical, chunks)
  end

  def test_packs_whole_paragraphs_toward_target_without_overlap
    paragraphs = %w[あ い う え お].map { |letter| letter * 250 }
    canonical = paragraphs.join("\n\n")
    chunks = chunk(canonical)

    assert_equal 2, chunks.length
    assert_equal paragraphs.first(3).join("\n\n") + "\n", chunks[0][:content]
    assert_equal paragraphs.last(2).join("\n\n"), chunks[1][:content]
    chunks.each { |item| assert_operator item[:content].length, :<=, 800 }
    assert_traceable(canonical, chunks)
  end

  def test_table_header_and_rows_are_an_indivisible_block
    table = "| 条件 | 必要時間 |\n| --- | --- |\n" + ("| 初回の方 | 15分 |\n" * 50)
    canonical = ("案内" * 160) + "\n\n" + table + "\nその後、入口に進んでください。"
    chunks = chunk(canonical)

    table_chunks = chunks.select { |item| item[:content].include?("| 条件 |") }
    assert_equal 1, table_chunks.length
    assert_includes table_chunks.first[:content], table
    assert_equal 50, table_chunks.first[:content].scan("| 初回の方 |").length
    assert_traceable(canonical, chunks)
  end

  def test_number_unit_and_condition_conclusion_paragraph_remain_whole
    instruction = "雨天の場合は、" + ("屋根のある通路をご利用ください。" * 22) + "入口から受付まで15分必要です。"
    canonical = ("序文。" * 100) + "\n\n" + instruction + "\n\n終了。"
    containing = chunk(canonical).select { |item| item[:content].include?("雨天の場合は、") }

    assert_equal 1, containing.length
    assert_includes containing.first[:content], instruction
    assert_traceable(canonical, chunk(canonical))
  end

  def test_single_large_atom_is_allowed_up_to_hard_limit
    [801, 1_200].each do |size|
      canonical = "あ" * size
      chunks = chunk(canonical)
      assert_equal 1, chunks.length
      assert_equal canonical, chunks.first[:content]
      assert_traceable(canonical, chunks)
    end
  end

  def test_oversized_paragraph_and_table_are_rejected_without_source_in_error
    paragraph = "秘密本文" + ("あ" * 1_200)
    table = "| 秘密本文 | 分 |\n| --- | --- |\n" + ("| 受付 | 15分 |\n" * 150)
    [paragraph, table, "# 受付\n\n" + ("あ" * 1_200)].each do |canonical|
      error = assert_raises(SchedulingKnowledge::Chunker::OversizedAtomError) { chunk(canonical) }
      assert_operator error.message.length, :<, 80
      refute_includes error.message, "秘密本文"
    end
  end

  def test_repeated_text_keeps_distinct_offsets_and_equal_hashes
    paragraph = "受付は15分前に済ませてください。" * 28
    canonical = paragraph + "\n\n" + paragraph + "\n\n" + paragraph
    chunks = chunk(canonical)

    assert_equal 3, chunks.length
    assert_equal 3, chunks.map { |item| item[:character_start] }.uniq.length
    assert_equal chunks[0][:content_sha256], chunks[1][:content_sha256]
    assert_traceable(canonical, chunks)
  end

  def test_empty_pages_preserve_document_page_numbers
    canonical = "\f\f受付。\f\f次の説明。\f"
    chunks = chunk(canonical)
    assert_equal [3, 5], chunks.map { |item| item[:page_number] }
    assert_traceable(canonical, chunks)
  end

  private

  def chunk(canonical)
    SchedulingKnowledge::Chunker.call(canonical_text: canonical)
  end

  def assert_traceable(canonical, chunks)
    assert_equal (0...chunks.length).to_a, chunks.map { |item| item[:sequence] }
    chunks.each_with_index do |item, index|
      assert_equal canonical[item[:character_start]...item[:character_end]], item[:content]
      assert_equal Digest::SHA256.hexdigest(item[:content]), item[:content_sha256]
      assert_equal item[:content].length, item[:character_end] - item[:character_start]
      assert_operator item[:content].length, :<=, SchedulingKnowledge::Chunker::MAX_CHARACTERS
      assert_operator item[:character_start], :>=, chunks[index - 1][:character_end] if index.positive?
    end
  end
end
