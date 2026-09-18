# frozen_string_literal: true

require 'test_helper'
require 'digest'
require 'securerandom'

class SchedulingKnowledgeFoundationTest < ActiveSupport::TestCase
  test 'document identity requires exact owner scope and closed MVP source and visibility' do
    assert build_document.valid?
    %i[tenant_scope_ref user_scope_ref place_ref].each do |attribute|
      assert_not build_document(attribute => nil).valid?, attribute.to_s
      assert_not build_document(attribute => " \t").valid?, attribute.to_s
    end
    assert_not build_document(source_type: 'tenant_policy_document').valid?
    assert_not build_document(source_type: 'other').valid?
    assert_not build_document(status: 'deleted').valid?
    assert_not build_document(visibility: 'public').valid?
    assert_not build_document(source_type: 'user_note', visibility: 'tenant').valid?
    assert_not build_document(place_ref: '東京都 施設住所').valid?
    assert build_document(source_type: 'user_note', visibility: 'private').valid?
  end

  test 'visibility scopes never disclose private foreign user or any foreign tenant' do
    own = create_document
    private_other = create_document(user_scope_ref: 'other-user')
    shared = create_document(user_scope_ref: 'other-user', visibility: 'tenant')
    foreign = create_document(tenant_scope_ref: 'other-tenant', visibility: 'tenant')
    visible = KnowledgeDocument.visible_to(tenant_scope_ref: 'tenant-a', user_scope_ref: 'user-a')

    assert_includes visible, own
    assert_includes visible, shared
    assert_not_includes visible, private_other
    assert_not_includes visible, foreign
    assert_empty KnowledgeDocument.visible_to(tenant_scope_ref: 'tenant-a', user_scope_ref: nil)
    assert_empty KnowledgeDocument.visible_to(tenant_scope_ref: nil, user_scope_ref: 'user-a')
    assert_equal [own.id], KnowledgeDocument.owned_by(tenant_scope_ref: 'tenant-a', user_scope_ref: 'user-a').pluck(:id)
  end

  test 'canonical source hash and bounded source provenance are validated' do
    assert_not build_document(content_sha256: '0' * 64).valid?
    assert_not build_document(source_sha256: 'untrusted').valid?
    assert_not build_document(canonical_text: "受付\r\n案内").valid?
    assert_not build_document(canonical_text: "受付\u0000案内").valid?
    assert_not build_document(source_timezone: 'Not/A_Timezone').valid?
    assert_not build_document(source_temporal_json: { 'raw_document' => 'forbidden' }).valid?
    assert_not build_document(source_temporal_json: { 'valid_until' => 123 }).valid?
    assert build_document(source_temporal_json: { 'valid_until' => '2026-12-31' }).valid?
  end

  test 'document temporal intervals cannot be empty or reversed' do
    time = Time.utc(2026, 9, 19)
    assert_not build_document(valid_from: time, valid_until: time).valid?
    assert_not build_document(valid_from: time, valid_until: time - 1).valid?
    assert_not build_document(verified_at: time, verified_until: time).valid?
    assert build_document(valid_from: time, valid_until: time + 1).valid?
    assert build_document(valid_from: nil, valid_until: nil, verified_until: time).valid?
  end

  test 'effective expiry caps validity at the earlier explicit or verified end' do
    start = Time.utc(2026, 9, 19)
    assert_not build_document(valid_from: start, valid_until: start + 60, verified_until: start).valid?
    assert_not build_document(valid_from: start, valid_until: nil, verified_until: start - 1).valid?
    assert build_document(valid_from: start, valid_until: start + 60, verified_until: start + 1).valid?

    document = create_document(valid_from: start, valid_until: start + 60)
    assert_database_rejects do
      KnowledgeDocument.where(id: document.id).update_all(verified_until: start)
    end
  end

  test 'persisted content identity and original temporal provenance cannot mutate' do
    document = create_document
    changes = {
      canonical_text: 'changed', content_sha256: Digest::SHA256.hexdigest('changed'),
      document_version: 'v2', tenant_scope_ref: 'other-tenant', user_scope_ref: 'other-user',
      place_ref: 'other-place', series_ref: 'other-series', source_sha256: 'a' * 64,
      visibility: 'tenant', title: 'different', source_temporal_json: { 'valid_until' => '2027-01-01' },
      valid_until: Time.utc(2027, 1, 1)
    }
    changes.each do |attribute, value|
      document.reload.public_send("#{attribute}=", value)
      assert_not document.valid?, attribute.to_s
      assert_includes document.errors[attribute], 'is immutable; register a new version'
    end
  end

  test 'lifecycle transitions permit activation and retirement but never resurrection' do
    document = create_document(status: 'draft')
    document.update!(status: 'active')
    assert_not document.update(status: 'draft')
    document.reload.update!(status: 'superseded')
    assert_not document.update(status: 'active')

    %w[revoked expired].each do |terminal|
      retired = create_document
      retired.update!(status: terminal)
      assert_not retired.update(status: 'active')
    end
    create_document(status: 'draft').update!(status: 'revoked')
  end

  test 'deletion tombstones are orthogonal to lifecycle and cannot be cleared' do
    document = create_document
    document.update!(deleted_at: Time.current)
    assert_equal 'active', document.status
    assert_not KnowledgeDocument.active_version.exists?(document.id)
    assert_not document.update(deleted_at: nil)
    assert_not document.reload.update(deleted_at: Time.current + 1)
  end

  test 'document uniqueness is owner scoped and database prevents parallel active versions' do
    document = create_document
    assert_not build_document(series_ref: document.series_ref, document_version: document.document_version).valid?
    assert build_document(series_ref: document.series_ref, user_scope_ref: 'other-user').valid?
    assert build_document(series_ref: document.series_ref, tenant_scope_ref: 'other-tenant').valid?

    assert_database_rejects(ActiveRecord::RecordNotUnique) do
      create_document(series_ref: document.series_ref, document_version: 'v2')
    end
    draft = create_document(series_ref: document.series_ref, document_version: 'v2', status: 'draft')
    document.update!(status: 'superseded')
    draft.update!(status: 'active')
    assert_equal [draft.id], KnowledgeDocument.active_version.where(series_ref: document.series_ref).pluck(:id)
  end

  test 'database checks protect document source enum text hash and temporal bounds' do
    document = create_document
    [
      { source_type: 'tenant_policy_document' }, { visibility: 'public' }, { status: 'deleted' },
      { source_type: 'user_note', visibility: 'tenant' }, { content_sha256: '0' * 64 },
      { user_scope_ref: " \t" }, { source_temporal_json: [] },
      { valid_from: Time.utc(2027), valid_until: Time.utc(2026) }
    ].each do |attributes|
      assert_database_rejects { KnowledgeDocument.where(id: document.id).update_all(attributes) }
    end
  end

  test 'chunk offsets use Unicode characters and exactly reconstruct immutable source' do
    text = "案内😀e\u0301\n受付15分前。"
    document = create_document(canonical_text: text)
    chunk = build_chunk(document, character_start: 2, character_end: 6)
    assert_equal "😀e\u0301\n", chunk.content
    assert chunk.valid?, chunk.errors.full_messages.join(', ')
    chunk.save!
    assert_equal text[2...6], chunk.reload.content

    invalid = build_chunk(document, sequence: 1, character_start: 6, character_end: text.length)
    invalid.content = '異なる文章'
    invalid.content_sha256 = Digest::SHA256.hexdigest(invalid.content)
    assert_not invalid.valid?
    assert_not build_chunk(document, character_start: 0, character_end: 100).valid?
  end

  test 'chunk bounds hashes page and section metadata fail closed' do
    document = create_document
    [
      { sequence: -1 }, { character_start: -1 }, { character_end: 0 }, { page_number: 0 }, { page_number: nil },
      { section_path_json: {} }, { section_path_json: [''] }, { content_sha256: '0' * 64 }
    ].each do |attributes|
      assert_not build_chunk(document, **attributes).valid?, attributes.keys.join(', ')
    end
    long_document = create_document(canonical_text: 'あ' * 1201)
    assert_not build_chunk(long_document).valid?
  end

  test 'duplicate chunk positions rejected while repeated source text remains distinct' do
    document = create_document(canonical_text: '受付受付')
    first = build_chunk(document, character_start: 0, character_end: 2)
    first.save!
    assert_not build_chunk(document, sequence: 0, character_start: 2, character_end: 4).valid?
    assert_not build_chunk(document, sequence: 1, character_start: 0, character_end: 2).valid?
    second = build_chunk(document, sequence: 1, character_start: 2, character_end: 4)
    second.save!
    assert_equal first.content_sha256, second.content_sha256
    assert_not_equal first.id, second.id
  end

  test 'chunk evidence and invalidation tombstones cannot be mutated' do
    chunk = build_chunk(create_document)
    chunk.save!
    assert_not chunk.update(sequence: 1)
    assert_not chunk.reload.update(character_start: 1)
    assert_not chunk.reload.update(section_path_json: ['別セクション'])
    chunk.reload.update!(invalidated_at: Time.current)
    assert_not chunk.update(invalidated_at: nil)
  end

  test 'available chunks require active parent undeleted parent active link and no invalidation' do
    document = create_document
    chunk = build_chunk(document)
    chunk.save!
    assert_not KnowledgeChunk.available.exists?(chunk.id)
    link = create_link(document)
    assert KnowledgeChunk.available.exists?(chunk.id)
    link.update!(active: false)
    assert_not KnowledgeChunk.available.exists?(chunk.id)
    link.update!(active: true)
    chunk.update!(invalidated_at: Time.current)
    assert_not KnowledgeChunk.available.exists?(chunk.id)

    %w[draft superseded revoked expired].each do |status|
      inactive = create_document(status: status)
      inactive_chunk = build_chunk(inactive)
      inactive_chunk.save!
      create_link(inactive)
      assert_not KnowledgeChunk.available.exists?(inactive_chunk.id), status
    end
    deleted = create_document(deleted_at: Time.current)
    deleted_chunk = build_chunk(deleted)
    deleted_chunk.save!
    create_link(deleted)
    assert_not KnowledgeChunk.available.exists?(deleted_chunk.id)
  end

  test 'one link binds precisely its document owner tenant and canonical place' do
    document = create_document
    %i[tenant_scope_ref user_scope_ref place_ref].each do |attribute|
      assert_not build_link(document, attribute => 'foreign').valid?, attribute.to_s
    end
    %w[none optional required].each { |value| assert build_link(document, knowledge_requirement: value).valid? }
    assert_not build_link(document, knowledge_requirement: 'unknown').valid?
    link = create_link(document)
    assert_not build_link(document).valid?
    assert_not link.update(place_ref: 'other-place')
  end

  test 'availability guards reject malformed link scope even when validation is bypassed' do
    document = create_document
    chunk = build_chunk(document)
    chunk.save!
    link = create_link(document)
    link.update_columns(tenant_scope_ref: 'foreign')
    assert_not KnowledgeChunk.available.exists?(chunk.id)
  end

  test 'database checks protect chunk intervals and closed link requirement' do
    document = create_document
    chunk = build_chunk(document)
    chunk.save!
    [{ sequence: -1 }, { character_end: 0 }, { content_sha256: '0' * 64 }, { page_number: 0 }, { page_number: nil }].each do |attributes|
      assert_database_rejects { KnowledgeChunk.where(id: chunk.id).update_all(attributes) }
    end
    link = create_link(document)
    assert_database_rejects { PlaceKnowledgeLink.where(id: link.id).update_all(knowledge_requirement: 'unknown') }
  end

  test 'inspect filters source text and physical parent deletion removes both dependent tables' do
    document = create_document(canonical_text: 'PRIVATE_SOURCE_BODY')
    chunk = build_chunk(document)
    chunk.save!
    create_link(document)
    assert_not_includes document.inspect, 'PRIVATE_SOURCE_BODY'
    assert_not_includes chunk.inspect, 'PRIVATE_SOURCE_BODY'
    document.destroy!
    assert_not KnowledgeChunk.exists?(knowledge_document_id: document.id)
    assert_not PlaceKnowledgeLink.exists?(knowledge_document_id: document.id)
  end

  private

  def build_document(overrides = {})
    text = overrides.fetch(:canonical_text, "施設案内\n受付は予約15分前です。")
    KnowledgeDocument.new({
      series_ref: "series_#{SecureRandom.hex(8)}", document_version: 'v1',
      tenant_scope_ref: 'tenant-a', user_scope_ref: 'user-a', place_ref: 'place-a',
      source_type: 'official_facility_document', visibility: 'private', title: '施設案内',
      language: 'ja', status: 'active', canonical_text: text,
      content_sha256: Digest::SHA256.hexdigest(text), source_sha256: Digest::SHA256.hexdigest(text),
      source_timezone: 'Asia/Tokyo', source_temporal_json: {}
    }.merge(overrides))
  end

  def create_document(overrides = {})
    build_document(overrides).tap(&:save!)
  end

  def build_chunk(document, **overrides)
    start = overrides.fetch(:character_start, 0)
    finish = overrides.fetch(:character_end, document.canonical_text.length)
    text = document.canonical_text[start...finish].to_s
    KnowledgeChunk.new({
      knowledge_document: document, sequence: 0, section_path_json: ['施設案内'], page_number: 1,
      character_start: start, character_end: finish, content: text,
      content_sha256: Digest::SHA256.hexdigest(text)
    }.merge(overrides))
  end

  def build_link(document, overrides = {})
    PlaceKnowledgeLink.new({
      knowledge_document: document, tenant_scope_ref: document.tenant_scope_ref,
      user_scope_ref: document.user_scope_ref, place_ref: document.place_ref,
      knowledge_requirement: 'optional', active: true
    }.merge(overrides))
  end

  def create_link(document)
    build_link(document).tap(&:save!)
  end

  def assert_database_rejects(error_class = ActiveRecord::StatementInvalid, &block)
    assert_raises(error_class) do
      ApplicationRecord.transaction(requires_new: true) { block.call }
    end
  end
end
