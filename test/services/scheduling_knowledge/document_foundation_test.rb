# frozen_string_literal: true

require 'test_helper'

class SchedulingKnowledgeDocumentFoundationTest < ActiveSupport::TestCase
  setup do
    @scope = SchedulingKnowledge::AccessScope.new(tenant_scope_ref: 'tenant-r1', user_scope_ref: 'owner-r1')
    @other_user = SchedulingKnowledge::AccessScope.new(tenant_scope_ref: 'tenant-r1', user_scope_ref: 'other-r1')
    @other_tenant = SchedulingKnowledge::AccessScope.new(tenant_scope_ref: 'tenant-other', user_scope_ref: 'owner-r1')
    @now = Time.utc(2026, 9, 19, 12)
  end

  test 'registrar stores exact normalized source chunks and one canonical place link atomically' do
    raw = "# 受付\r\n\r\n予約の15分前までに受付。😀e\u0301\r\n"
    document = register(content: raw)
    assert_equal raw.gsub("\r\n", "\n"), document.canonical_text
    assert_equal Digest::SHA256.hexdigest(raw), document.source_sha256
    assert_equal Digest::SHA256.hexdigest(document.canonical_text), document.content_sha256
    assert_equal '2026-12-31', document.source_temporal_json['valid_until']
    assert_equal 1, PlaceKnowledgeLink.where(knowledge_document_id: document.id).count
    document.knowledge_chunks.each do |chunk|
      assert_equal document.canonical_text[chunk.character_start...chunk.character_end], chunk.content
      assert_equal Digest::SHA256.hexdigest(chunk.content), chunk.content_sha256
    end
    assert eligible?(document)
  end

  test 'failed link or chunk validation leaves no partial document foundation' do
    counts = foundation_counts
    assert_raises(ActiveRecord::RecordInvalid) { register(knowledge_requirement: 'unsafe') }
    assert_equal counts, foundation_counts
    assert_raises(ArgumentError) { register(content: 'あ' * 1201) }
    assert_equal counts, foundation_counts
  end

  test 'default draft and every inactive lifecycle are excluded' do
    draft = register(status: 'draft')
    assert_not eligible?(draft)
    %w[superseded revoked expired].each do |status|
      document = register
      invalidate(document, status)
      assert_not eligible?(document), status
      assert_empty document.knowledge_chunks.merge(KnowledgeChunk.available)
    end
  end

  test 'tenant and owner isolation also apply to lifecycle writes of shared official documents' do
    private_document = register
    assert_not eligible?(private_document, scope: @other_user)
    assert_not eligible?(private_document, scope: @other_tenant)
    shared = register(visibility: 'tenant')
    assert eligible?(shared, scope: @other_user)
    assert_not eligible?(shared, scope: @other_tenant)
    [private_document, shared].each do |document|
      assert_raises(SchedulingKnowledge::AccessScope::Denied) do
        SchedulingKnowledge::DocumentInvalidator.call(scope: @other_user, document_id: document.public_id, reason: 'deleted')
      end
      assert_raises(SchedulingKnowledge::AccessScope::Denied) do
        SchedulingKnowledge::DocumentVersioner.call(scope: @other_user, document_id: document.public_id,
                                                    document_version: 'v2', content: '受付20分前。')
      end
      assert_equal 'active', document.reload.status
      assert_nil document.deleted_at
    end
  end

  test 'user notes cannot become tenant shared and tenant policies cannot be registered in MVP' do
    counts = foundation_counts
    assert_raises(ActiveRecord::RecordInvalid) { register(source_type: 'user_note', visibility: 'tenant') }
    assert_raises(ActiveRecord::RecordInvalid) { register(source_type: 'tenant_policy_document') }
    assert_equal counts, foundation_counts
  end

  test 'inclusive date expiry is converted to the next trusted local midnight' do
    document = register(valid_from: '2026-12-31', valid_until: '2026-12-31')
    assert_equal Time.utc(2026, 12, 30, 15), document.valid_from
    assert_equal Time.utc(2026, 12, 31, 15), document.valid_until
    assert eligible?(document, start_at: Time.utc(2026, 12, 31, 14), end_at: document.valid_until)
    assert_not eligible?(document, start_at: document.valid_until, end_at: document.valid_until + 60)
    assert_not eligible?(document, start_at: document.valid_from - 1, end_at: document.valid_from + 60)
  end

  test 'date conversion advances local calendar days rather than 86400 seconds across DST' do
    values = normalize(source_timezone: 'America/New_York', valid_from: '2026-03-08', valid_until: '2026-03-08')
    assert_equal 23 * 3600, values[:valid_until] - values[:valid_from]
    autumn = normalize(source_timezone: 'America/New_York', valid_from: '2026-11-01', valid_until: '2026-11-01')
    assert_equal 25 * 3600, autumn[:valid_until] - autumn[:valid_from]
  end

  test 'ambiguous skipped invalid and unzoned dates cannot be guessed' do
    assert_raises(ArgumentError) { normalize(source_timezone: 'America/Havana', valid_from: '2026-11-01') }
    assert_raises(ArgumentError) { normalize(source_timezone: 'Pacific/Apia', valid_from: '2011-12-30') }
    assert_raises(ArgumentError) { normalize(valid_from: '2026-02-30') }
    assert_raises(ArgumentError) { normalize(valid_from: '2026-02-30T10:00:00+09:00') }
    assert_raises(ArgumentError) { normalize(valid_from: '2026-09-19T10:00:00') }
    assert_raises(ArgumentError) { normalize(valid_from: '2026-09-19T10:00:60Z') }
    assert_raises(ArgumentError) { normalize(source_timezone: nil) }
    assert_raises(ArgumentError) { normalize(source_timezone: 'Tokyo') }
  end

  test 'offset timestamps stay exact exclusive instants and provenance is retained' do
    raw = '2026-12-31T10:15:00.123456+09:00'
    values = normalize(valid_until: raw)
    assert_equal Time.iso8601(raw).utc, values[:valid_until]
    assert_equal raw, values[:source_temporal_json]['valid_until']
  end

  test 'verification cannot extend explicit expiry and bounds cover the entire target interval' do
    document = register(valid_until: '2026-09-20T13:00:00Z', verified_until: '2026-09-25T13:00:00Z')
    assert eligible?(document, start_at: Time.utc(2026, 9, 20, 12), end_at: Time.utc(2026, 9, 20, 13))
    assert_not eligible?(document, start_at: Time.utc(2026, 9, 20, 12), end_at: Time.utc(2026, 9, 20, 13, 0, 1))
    early = register(verified_until: '2026-09-20T13:00:00Z')
    assert_not eligible?(early, start_at: Time.utc(2026, 9, 20, 13), end_at: Time.utc(2026, 9, 20, 14))
    assert_raises(ArgumentError) { normalize(valid_from: '2026-10-01', verified_until: '2026-09-20') }
  end

  test 'missing official expiry uses explicit verification or 90 day Soft metadata eligibility' do
    verified = register(valid_until: nil, verified_until: '2026-09-30')
    assert eligible?(verified)
    recent = register(valid_until: nil, issued_at: '2026-09-01T00:00:00Z')
    assert eligible?(recent)
    old = register(valid_until: nil, issued_at: '2026-01-01T00:00:00Z')
    assert_not eligible?(old)
    unproven = register(valid_until: nil)
    assert_not eligible?(unproven)
    future = register(valid_until: nil, issued_at: '2026-10-01T00:00:00Z')
    assert_not eligible?(future)
    deadline = recent.issued_at + 90 * 86_400
    assert_not eligible?(recent, start_at: deadline - 60, end_at: deadline + 1)
    assert_not eligible?(recent, now: deadline)
    assert_not recent.respond_to?(:hard_eligible?)
  end

  test 'undated private notes remain metadata candidates and 180 day age only requests reconfirmation' do
    note = register(source_type: 'user_note', valid_until: nil)
    assert eligible?(note)
    assert_not eligible?(note, scope: @other_user)
    boundary = note.created_at + 180 * 86_400
    assert_not SchedulingKnowledge::DocumentEligibility.reconfirmation_due?(document: note, now: boundary)
    assert SchedulingKnowledge::DocumentEligibility.reconfirmation_due?(document: note, now: boundary + 1)
    assert eligible?(note, now: boundary + 1)
  end

  test 'eligibility does not trust stale loaded lifecycle or cached active links' do
    %w[revoked expired superseded].each do |status|
      document = register
      stale = KnowledgeDocument.find(document.id)
      document.update!(status: status)
      assert_not eligible?(stale), status
    end
    document = register
    stale = KnowledgeDocument.find(document.id)
    document.update!(deleted_at: @now)
    assert_not eligible?(stale)
    linked = register
    linked.place_knowledge_link.update!(active: false)
    assert_not eligible?(linked)
  end

  test 'all three knowledge requirements are persisted without running retrieval' do
    %w[none optional required].each do |requirement|
      document = register(knowledge_requirement: requirement)
      assert_equal requirement, document.place_knowledge_link.knowledge_requirement
    end
    assert_not eligible?(register, place_ref: 'another-place')
    assert_not eligible?(register, start_at: @now, end_at: @now)
    assert_not eligible?(register, start_at: '2026-09-19', end_at: '2026-09-20')
  end

  test 'note deletion invalidates scoped chunks and link and is idempotent without changing another owner' do
    note = register(source_type: 'user_note', valid_until: nil)
    other = register(scope: @other_user, source_type: 'user_note', valid_until: nil)
    invalidate(note, 'deleted')
    first_deleted = note.reload.deleted_at
    assert_equal @now, first_deleted
    assert_not note.place_knowledge_link.reload.active?
    assert note.knowledge_chunks.all? { |chunk| chunk.invalidated_at == @now }
    assert_not eligible?(note)
    invalidate(note, 'deleted', now: @now + 1)
    assert_equal first_deleted, note.reload.deleted_at
    assert eligible?(other, scope: @other_user)
    assert_nil other.reload.deleted_at
  end

  test 'invalid deletion clock or reason cannot partially mutate document state' do
    document = register
    [nil, false, '2026-09-19'].each do |clock|
      assert_raises(ArgumentError) { invalidate(document, 'deleted', now: clock) }
    end
    assert_raises(ArgumentError) { invalidate(document, 'unknown') }
    assert_nil document.reload.deleted_at
    assert document.place_knowledge_link.active?
    assert document.knowledge_chunks.all? { |chunk| chunk.invalidated_at.nil? }
  end

  test 'version replacement atomically retires the old evidence and activates exactly one new version' do
    document = register
    replacement = replace(document)
    assert_equal document.series_ref, replacement.series_ref
    assert_equal 'v2', replacement.document_version
    assert_equal 'superseded', document.reload.status
    assert document.knowledge_chunks.all? { |chunk| chunk.invalidated_at.present? }
    assert_not document.place_knowledge_link.reload.active?
    assert_not eligible?(document)
    assert eligible?(replacement)
    assert_equal [replacement.id], @scope.owned_documents.active_version.where(series_ref: document.series_ref).pluck(:id)
    assert_raises(ArgumentError) { replace(document, document_version: 'v3') }
  end

  test 'replacement failure rolls back supersession chunk invalidation and link deactivation' do
    document = register
    counts = foundation_counts
    assert_raises(ArgumentError) { replace(document, content: 'あ' * 1201) }
    assert_equal counts, foundation_counts
    assert_equal 'active', document.reload.status
    assert document.place_knowledge_link.reload.active?
    assert document.knowledge_chunks.all? { |chunk| chunk.invalidated_at.nil? }
    assert eligible?(document)
    assert_raises(ActiveRecord::RecordInvalid) { replace(document, document_version: document.document_version) }
    assert_equal 'active', document.reload.status
    assert_equal counts, foundation_counts
  end

  test 'scope identity place and version metadata cannot be silently rebound' do
    assert_raises(ArgumentError) { SchedulingKnowledge::AccessScope.new(tenant_scope_ref: '', user_scope_ref: 'user') }
    assert_raises(ArgumentError) { register(scope: { tenant_scope_ref: 'tenant-r1', user_scope_ref: 'owner-r1' }) }
    assert_raises(ArgumentError) { register(place_ref: '東京の病院') }
    document = register
    assert_raises(ArgumentError) { replace(document, place_ref: 'another-place') }
    assert_equal 'place-hospital', document.reload.place_ref
  end

  test 'registering another version cannot rebind an existing series or reuse a foreign owners series' do
    document = register
    counts = foundation_counts
    [{ place_ref: 'place-other' }, { source_type: 'user_note' }, { visibility: 'tenant' }, { scope: @other_user }].each do |changed|
      assert_raises(ArgumentError) do
        register(series_ref: document.series_ref, document_version: 'v2', status: 'draft', **changed)
      end
    end
    assert_equal counts, foundation_counts
    assert_equal 'active', document.reload.status
    assert eligible?(document)
  end

  test 'success failure versioning and deletion never write Event or AI records' do
    writes = []
    observer = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      writes << sql if sql.match?(/\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"?(?:events|ai_\w+)/i)
    end
    ActiveSupport::Notifications.subscribed(observer, 'sql.active_record') do
      document = register
      replacement = replace(document)
      invalidate(replacement, 'deleted')
      assert_raises(ArgumentError) { register(content: 'あ' * 1201) }
    end
    assert_empty writes
  end

  private

  def register(**overrides)
    SchedulingKnowledge::DocumentRegistrar.call(**{
      scope: @scope, place_ref: 'place-hospital', source_type: 'official_facility_document',
      document_version: 'v1', title: '受付案内', content: "# 受付\n\n予約の15分前までに受付。",
      source_timezone: 'Asia/Tokyo', status: 'active', valid_until: '2026-12-31'
    }.merge(overrides))
  end

  def normalize(**overrides)
    SchedulingKnowledge::ValidityNormalizer.call(**{ source_timezone: 'Asia/Tokyo' }.merge(overrides))
  end

  def eligible?(document, scope: @scope, place_ref: 'place-hospital',
                start_at: Time.utc(2026, 9, 20, 12), end_at: Time.utc(2026, 9, 20, 13), now: @now)
    SchedulingKnowledge::DocumentEligibility.call(document: document, scope: scope, place_ref: place_ref,
                                                  target_start_at: start_at, target_end_at: end_at, now: now)
  end

  def invalidate(document, reason, now: @now)
    SchedulingKnowledge::DocumentInvalidator.call(scope: @scope, document_id: document.public_id, reason: reason, now: now)
  end

  def replace(document, **overrides)
    SchedulingKnowledge::DocumentVersioner.call(**{
      scope: @scope, document_id: document.public_id, document_version: 'v2', content: '受付は予約20分前。'
    }.merge(overrides))
  end

  def foundation_counts
    [KnowledgeDocument.count, KnowledgeChunk.count, PlaceKnowledgeLink.count]
  end
end
