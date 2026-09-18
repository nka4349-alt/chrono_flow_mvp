# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "securerandom"
require_relative "../../../lib/secretary_creation/contract"

class SecretaryCreationContractTest < Minitest::Test
  Contract = SecretaryCreation::Contract

  def fixture(provider = "chrono_flow")
    JSON.parse(File.read(File.expand_path("../../fixtures/secretary_creation/v1/#{provider}_ready.json", __dir__), encoding: "UTF-8"))
  end

  def request
    { "version" => "1.0", "request_id" => SecureRandom.uuid, "trace_id" => SecureRandom.uuid,
      "message" => "今日18時から18時半に来客を予定に追加", "locale" => "ja-JP", "time_zone" => "Asia/Tokyo",
      "proposal_id" => nil, "expected_revision" => nil }
  end

  def test_both_providers_accept_cross_language_canonical_digests
    %w[chrono_flow chrono_task].each do |provider|
      payload = fixture(provider)
      assert_same payload, Contract.validate_response!(payload)
      assert_equal payload["content_digest"], Contract.digest(**%w[provider proposal_id revision expires_at details].reverse.to_h { |key| [ key.to_sym, payload[key] ] })
    end
  end

  def test_omitted_or_injected_request_fields_are_rejected
    request.each_key do |key|
      bad = request
      bad.delete(key)
      assert_raises(Contract::Invalid) { Contract.validate_request!(:propose, bad) }
    end
    %w[user_id workspace_id endpoint action_type].each do |key|
      assert_raises(Contract::Invalid) { Contract.validate_request!(:propose, request.merge(key => "attacker")) }
    end
  end

  def test_revision_and_candidate_binding_is_required_for_followups
    assert Contract.validate_request!(:propose, request)
    assert_raises(Contract::Invalid) { Contract.validate_request!(:propose, request.merge("expected_revision" => 1)) }
    assert_raises(Contract::Invalid) { Contract.validate_request!(:propose, request.merge("proposal_id" => SecureRandom.uuid)) }
    assert Contract.validate_request!(:propose, request.merge("proposal_id" => SecureRandom.uuid, "expected_revision" => 1))
  end

  def test_confirmation_only_accepts_bound_candidate_identifiers
    payload = fixture
    confirm = request.slice("version", "request_id", "trace_id").merge(payload.slice("proposal_id", "revision", "content_digest"))
    confirm["idempotency_key"] = SecureRandom.uuid
    assert Contract.validate_request!(:confirm, confirm)
    [ { "title" => "差し替え" }, { "revision" => "1" }, { "revision" => 0 }, { "content_digest" => "invalid" } ].each do |change|
      assert_raises(Contract::Invalid) { Contract.validate_request!(:confirm, confirm.merge(change)) }
    end
  end

  def test_title_revision_expiry_and_provider_cannot_be_substituted
    [ [ "revision", 2 ], [ "expires_at", "2026-09-20T10:15:00Z" ], [ "provider", "chrono_task" ] ].each do |key, value|
      assert_raises(Contract::Invalid) { Contract.validate_response!(fixture.merge(key => value)) }
    end
    payload = fixture
    payload["details"]["title"] = "別の予定"
    assert_raises(Contract::Invalid) { Contract.validate_response!(payload) }
  end

  def test_invalid_dates_are_not_normalized_and_times_are_not_guessed
    details = fixture("chrono_task")["details"]
    assert Contract.validate_details!(details, provider: "chrono_task")
    assert_nil details["due_time"]
    assert_raises(Contract::Invalid) { Contract.validate_details!(details.merge("due_date" => "2026-02-30")) }
    assert_raises(Contract::Invalid) { Contract.validate_details!(details.merge("due_date" => nil, "due_time" => "18:00")) }
    assert_raises(Contract::Invalid) { Contract.validate_details!(details.merge("due_time" => "24:00")) }
    assert Contract.validate_details!(details.merge("due_date" => nil), provider: "chrono_task")
  end

  def test_event_interval_and_all_day_boundaries_are_validated
    details = fixture["details"]
    assert_raises(Contract::Invalid) { Contract.validate_details!(details.merge("end_at" => details["start_at"])) }
    assert_raises(Contract::Invalid) { Contract.validate_details!(details.merge("start_at" => "2026-02-30T18:00:00+09:00")) }
    assert_raises(Contract::Invalid) { Contract.validate_details!(details.merge("all_day" => true)) }
    assert Contract.validate_details!(details.merge("all_day" => true,
      "start_at" => "2026-09-20T00:00:00+09:00", "end_at" => "2026-09-21T00:00:00+09:00"))
  end

  def test_completion_requires_actual_receipt_identity_and_time
    payload = fixture.merge("status" => "completed")
    assert_raises(Contract::Invalid) { Contract.validate_response!(payload) }
    payload.merge!("result_id" => SecureRandom.uuid, "completed_at" => "2026-09-20T09:02:00Z")
    assert Contract.validate_response!(payload)
    assert_raises(Contract::Invalid) { Contract.validate_response!(payload.merge("status" => "ready")) }
  end

  def test_clarification_cannot_smuggle_executable_details
    payload = fixture.merge("status" => "needs_clarification", "question" => "何時までですか？")
    assert_raises(Contract::Invalid) { Contract.validate_response!(payload) }
    assert Contract.validate_response!(payload.merge("details" => nil, "content_digest" => nil))
  end

  def test_whitespace_controls_oversize_and_unsupported_timezones_are_rejected
    [ "　\n\t", "x\u0000y", "x" * 4_001 ].each do |message|
      assert_raises(Contract::Invalid) { Contract.validate_request!(:propose, request.merge("message" => message)) }
    end
    assert_raises(Contract::Invalid) { Contract.validate_request!(:propose, request.merge("time_zone" => "UTC")) }
    assert_raises(Contract::Invalid) { Contract.canonical_json({ unsafe_symbol: 1 }) }
    assert_raises(Contract::Invalid) { Contract.canonical_json({ "float" => Float::INFINITY }) }
  end

  def test_safe_error_envelope_is_strict
    error = { "version" => "1.0", "request_id" => nil, "trace_id" => nil,
      "error" => { "code" => "unavailable", "message" => "現在利用できません。", "retryable" => true } }
    assert Contract.validate_error!(error)
    assert_raises(Contract::Invalid) { Contract.validate_error!(error.merge("token" => "secret")) }
    error["error"]["code"] = "raw_exception"
    assert_raises(Contract::Invalid) { Contract.validate_error!(error) }
  end
end
