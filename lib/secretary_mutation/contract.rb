# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "time"
require "tzinfo"

module SecretaryMutation
  # Runtime wire validator and canonical digest implementation shared byte-for-byte
  # by Home, ChronoFlow, and ChronoTask. It is deliberately independent of Rails.
  module Contract
    class Invalid < ArgumentError
      def initialize
        super("secretary mutation contract is invalid")
      end
    end

    class DuplicateKey < StandardError; end

    class DuplicateCheckingHash < Hash
      def []=(key, value)
        raise DuplicateKey if key?(key)

        super
      end
    end

    VERSION = "draft-0.1"
    PROVIDERS = %w[chrono_flow chrono_task].freeze
    OPERATIONS = %w[event.update event.delete task.update task.delete task.complete task.postpone].freeze
    STATUSES = %w[needs_target needs_clarification ready rejected completed completed_tombstone cancelled expired conflicted].freeze
    REJECTED_REASONS = %w[already_completed no_effect unsupported_change ineligible_shared_event
      ineligible_recurring_event ineligible_relationships ineligible_other_assignee
      ineligible_notification_history reminder_consistency_requires_gate].freeze
    TERMINAL_REASONS = %w[user_cancelled execution_expired target_changed relationships_changed
      proposal_changed receipt_detail_expired].freeze
    ERROR_CODES = %w[invalid_request unauthenticated forbidden not_found target_changed proposal_changed
      idempotency_conflict expired unsupported conflict in_progress unavailable outcome_unknown].freeze
    RETRYABLE_ERROR_CODES = %w[in_progress unavailable].freeze
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    SHA256 = /\A[0-9a-f]{64}\z/
    CANDIDATE_REF = /\Asc1_[A-Za-z0-9_-]{43}\z/
    TARGET_REF = /\Ast1_[A-Za-z0-9_-]{43}\z/
    SCOPE_REF = /\Ars1_[A-Za-z0-9_-]{43}\z/
    TARGET_VERSION = /\Asv1_[A-Za-z0-9_-]{1,16}_[A-Za-z0-9_-]{43}\z/
    RELATIONSHIP_FINGERPRINT = /\Asr1_[A-Za-z0-9_-]{1,16}_[A-Za-z0-9_-]{43}\z/
    TIMESTAMP = /\A(\d{4}-\d{2}-\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.(\d{1,6}))?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/
    EXECUTION_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\dZ\z/
    LOCALE = /\A[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*\z/
    ASCII_KEY = /\A[\x20-\x7E]+\z/
    CONTROL_CHARACTER = /[\u0000-\u001F\u007F-\u009F]/
    MULTILINE_DISALLOWED_CONTROL_CHARACTER = /[\u0000-\u0009\u000B-\u001F\u007F-\u009F]/

    REQUEST_KEYS = {
      "propose" => %w[version request_id trace_id operation message locale time_zone proposal_id expected_revision candidate_ref],
      "confirm" => %w[version request_id trace_id proposal_id revision operation target_ref target_version content_digest idempotency_key],
      "cancel" => %w[version request_id trace_id proposal_id revision operation]
    }.freeze
    SUCCESS_KEYS = %w[version request_id trace_id provider operation proposal_id revision status reason_code
      execution_expires_at status_available_until receipt_detail_available_until idempotency_available_until
      question candidates target before after changed_fields relationship_fingerprint planned_related_effects
      content_digest receipt refresh_scope].freeze
    DIGEST_KEYS = %w[provider proposal_id revision execution_expires_at operation target_ref target_version
      relationship_fingerprint planned_related_effects before after changed_fields].freeze
    EVENT_KEYS = %w[kind title description location schedule].freeze
    TASK_KEYS = %w[kind title description status priority deadline].freeze
    OPERATION_POLICY = {
      "event.update" => { provider: "chrono_flow", kind: "event", fields: %w[description location schedule title], plan: "none" },
      "event.delete" => { provider: "chrono_flow", kind: "event", fields: [ "$record" ], plan: "event_delete" },
      "task.update" => { provider: "chrono_task", kind: "task", fields: %w[deadline description priority title], plan: "none" },
      "task.delete" => { provider: "chrono_task", kind: "task", fields: [ "$record" ], plan: "task_delete" },
      "task.complete" => { provider: "chrono_task", kind: "task", fields: [ "status" ], plan: "none" },
      "task.postpone" => { provider: "chrono_task", kind: "task", fields: [ "deadline" ], plan: "none" }
    }.freeze
    DOMAIN_OUTCOMES = {
      "event.update" => "event_updated",
      "event.delete" => "event_deleted",
      "task.update" => "task_updated",
      "task.delete" => "task_deleted",
      "task.complete" => "task_completed",
      "task.postpone" => "deadline_changed"
    }.freeze

    module_function

    def parse_json!(raw, max_bytes:)
      invalid! unless raw.instance_of?(String) && max_bytes.instance_of?(Integer) && max_bytes.positive?
      invalid! if raw.bytesize > max_bytes
      invalid! unless [ Encoding::UTF_8, Encoding::US_ASCII, Encoding::ASCII_8BIT ].include?(raw.encoding)

      source = raw.dup.force_encoding(Encoding::UTF_8)
      invalid! unless source.valid_encoding?
      invalid! if source.start_with?("\uFEFF")

      JSON.parse(source, create_additions: false, allow_nan: false, allow_duplicate_key: false,
        max_nesting: 64, object_class: DuplicateCheckingHash)
    rescue JSON::ParserError, DuplicateKey, EncodingError
      invalid!
    end

    def validate_request!(phase, payload)
      case phase.to_s
      when "propose" then validate_propose_request!(payload)
      when "confirm" then validate_confirm_request!(payload)
      when "cancel" then validate_cancel_request!(payload)
      else invalid!
      end
    end

    def validate_propose_request!(payload)
      exact!(payload, REQUEST_KEYS.fetch("propose"))
      common_request!(payload)
      operation!(payload["operation"])
      locale!(payload["locale"])
      time_zone!(payload["time_zone"])

      if payload["proposal_id"].nil?
        invalid! unless payload["expected_revision"].nil? && payload["candidate_ref"].nil?
        user_message!(payload["message"], maximum: 4_000)
      else
        uuid!(payload["proposal_id"])
        revision!(payload["expected_revision"])
        candidate_ref!(payload["candidate_ref"]) unless payload["candidate_ref"].nil?
        user_message!(payload["message"], maximum: 2_000)
      end
      payload
    end

    def validate_confirm_request!(payload)
      exact!(payload, REQUEST_KEYS.fetch("confirm"))
      common_request!(payload)
      uuid!(payload["proposal_id"])
      revision!(payload["revision"])
      operation!(payload["operation"])
      target_ref!(payload["target_ref"])
      target_version!(payload["target_version"])
      sha256!(payload["content_digest"])
      uuid!(payload["idempotency_key"])
      payload
    end

    def validate_cancel_request!(payload)
      exact!(payload, REQUEST_KEYS.fetch("cancel"))
      common_request!(payload)
      uuid!(payload["proposal_id"])
      revision!(payload["revision"])
      operation!(payload["operation"])
      payload
    end

    def validate_success_response!(payload)
      exact!(payload, SUCCESS_KEYS)
      common_request!(payload)
      operation_allowed_for_provider!(payload["provider"], payload["operation"])
      uuid!(payload["proposal_id"])
      revision!(payload["revision"])
      invalid! unless STATUSES.include?(payload["status"])
      timestamp!(payload["status_available_until"])
      execution_timestamp!(payload["execution_expires_at"]) unless payload["execution_expires_at"].nil?
      optional_timestamp!(payload["receipt_detail_available_until"])
      optional_timestamp!(payload["idempotency_available_until"])
      provider_generated_text!(payload["question"]) unless payload["question"].nil?
      validate_candidates!(payload["candidates"], provider: payload["provider"]) unless payload["candidates"].nil?
      validate_target!(payload["target"], provider: payload["provider"]) unless payload["target"].nil?
      validate_snapshot!(payload["before"], provider: payload["provider"]) unless payload["before"].nil?
      validate_snapshot!(payload["after"], provider: payload["provider"]) unless payload["after"].nil?
      validate_changed_fields_array!(payload["changed_fields"], allow_empty: true)
      relationship_fingerprint!(payload["relationship_fingerprint"]) unless payload["relationship_fingerprint"].nil?
      validate_planned_effects!(payload["planned_related_effects"]) unless payload["planned_related_effects"].nil?
      sha256!(payload["content_digest"]) unless payload["content_digest"].nil?

      validate_status_invariants!(payload)
      payload
    end

    def validate_response!(payload)
      validate_success_response!(payload)
    end

    def validate_error_response!(payload)
      exact!(payload, %w[version request_id trace_id error])
      invalid! unless payload["version"] == VERSION
      uuid!(payload["request_id"]) unless payload["request_id"].nil?
      uuid!(payload["trace_id"]) unless payload["trace_id"].nil?
      error = payload["error"]
      exact!(error, %w[code message retryable])
      invalid! unless ERROR_CODES.include?(error["code"])
      provider_generated_text!(error["message"])
      invalid! unless [ true, false ].include?(error["retryable"])
      invalid! unless error["retryable"] == RETRYABLE_ERROR_CODES.include?(error["code"])
      payload
    end

    def validate_digest_input!(payload)
      exact!(payload, DIGEST_KEYS)
      operation_allowed_for_provider!(payload["provider"], payload["operation"])
      uuid!(payload["proposal_id"])
      revision!(payload["revision"])
      execution_timestamp!(payload["execution_expires_at"])
      target_ref!(payload["target_ref"])
      target_version!(payload["target_version"])
      relationship_fingerprint!(payload["relationship_fingerprint"])
      validate_snapshot!(payload["before"], provider: payload["provider"])
      validate_snapshot!(payload["after"], provider: payload["provider"]) unless payload["after"].nil?
      validate_planned_effects!(payload["planned_related_effects"])
      validate_changed_fields!(payload)
      payload
    end

    def canonical_json(value)
      JSON.generate(canonical_value(value, 0), quirks_mode: false)
    rescue JSON::GeneratorError, EncodingError
      invalid!
    end

    def digest(payload)
      validate_digest_input!(payload)
      Digest::SHA256.hexdigest(canonical_json(payload))
    end

    def digest_matches!(payload, expected_digest)
      sha256!(expected_digest)
      invalid! unless secure_equal?(digest(payload), expected_digest)
      expected_digest
    end

    def provider_for_operation(operation)
      operation!(operation)
      OPERATION_POLICY.fetch(operation).fetch(:provider)
    end

    def operation_allowed_for_provider!(provider, operation)
      invalid! unless PROVIDERS.include?(provider)
      invalid! unless provider_for_operation(operation) == provider
      true
    end

    def contract_root
      File.expand_path("../../contracts/secretary_mutation/v1", __dir__)
    end

    def validate_status_invariants!(payload)
      case payload["status"]
      when "needs_target"
        nulls!(payload, %w[reason_code target before after relationship_fingerprint planned_related_effects content_digest receipt refresh_scope receipt_detail_available_until idempotency_available_until])
        required!(payload, %w[execution_expires_at question candidates])
        invalid! unless payload["changed_fields"].empty?
      when "needs_clarification"
        nulls!(payload, %w[reason_code candidates after content_digest receipt refresh_scope receipt_detail_available_until idempotency_available_until])
        required!(payload, %w[execution_expires_at question target before relationship_fingerprint planned_related_effects])
        invalid! unless payload["changed_fields"].empty? && payload["planned_related_effects"] == { "type" => "none" }
      when "ready"
        nulls!(payload, %w[reason_code candidates receipt refresh_scope receipt_detail_available_until idempotency_available_until])
        required!(payload, %w[execution_expires_at question target before relationship_fingerprint planned_related_effects content_digest])
        validate_bound_digest!(payload)
      when "rejected"
        invalid! unless REJECTED_REASONS.include?(payload["reason_code"])
        nulls!(payload, %w[candidates after content_digest receipt refresh_scope receipt_detail_available_until idempotency_available_until])
        required!(payload, %w[execution_expires_at question])
        invalid! unless payload["changed_fields"].empty?
        validate_resolved_rejected_shape!(payload)
      when "completed"
        nulls!(payload, %w[reason_code question candidates])
        required!(payload, %w[execution_expires_at target before relationship_fingerprint planned_related_effects content_digest receipt refresh_scope receipt_detail_available_until idempotency_available_until])
        validate_bound_digest!(payload)
        validate_full_receipt!(payload)
      when "completed_tombstone"
        invalid! unless payload["reason_code"] == "receipt_detail_expired"
        nulls!(payload, %w[execution_expires_at question candidates target before after relationship_fingerprint planned_related_effects content_digest refresh_scope])
        required!(payload, %w[receipt receipt_detail_available_until idempotency_available_until])
        invalid! unless payload["changed_fields"].empty?
        validate_tombstone_receipt!(payload)
      when "cancelled", "expired", "conflicted"
        expected_reasons = payload["status"] == "cancelled" ? [ "user_cancelled" ] :
          (payload["status"] == "expired" ? [ "execution_expired" ] : %w[target_changed relationships_changed proposal_changed])
        invalid! unless expected_reasons.include?(payload["reason_code"])
        nulls!(payload, %w[candidates receipt refresh_scope receipt_detail_available_until idempotency_available_until])
        required!(payload, %w[execution_expires_at])
        validate_terminal_detail_shape!(payload)
      else
        invalid!
      end
      validate_unexecuted_retention!(payload) unless %w[completed completed_tombstone].include?(payload["status"])
    end

    def validate_resolved_rejected_shape!(payload)
      if payload["target"].nil?
        nulls!(payload, %w[before relationship_fingerprint planned_related_effects])
      else
        required!(payload, %w[before relationship_fingerprint planned_related_effects])
        invalid! unless payload["planned_related_effects"] == { "type" => "none" }
      end
    end

    def validate_terminal_detail_shape!(payload)
      detail_values = %w[target before relationship_fingerprint planned_related_effects content_digest].map { |key| payload[key] }
      if detail_values.all?(&:nil?)
        invalid! unless payload["after"].nil? && payload["changed_fields"].empty?
      else
        required!(payload, %w[target before relationship_fingerprint planned_related_effects content_digest])
        validate_bound_digest!(payload)
      end
    end

    def validate_bound_digest!(payload)
      input = DIGEST_KEYS.to_h do |key|
        value = case key
        when "target_ref", "target_version" then payload.fetch("target").fetch(key)
        else payload.fetch(key)
        end
        [ key, value ]
      end
      digest_matches!(input, payload["content_digest"])
    end

    def validate_unexecuted_retention!(payload)
      execution = execution_timestamp!(payload["execution_expires_at"])
      status_until = timestamp!(payload["status_available_until"])
      invalid! unless status_until - execution == 30 * 86_400
      invalid! unless timestamp_fraction(payload["status_available_until"]) == timestamp_fraction(payload["execution_expires_at"])
    end

    def validate_full_receipt!(payload)
      receipt = payload["receipt"]
      exact!(receipt, %w[result_id operation target_ref target_version_before target_version_after completed_at domain_outcome related_effects executed_snapshot])
      uuid!(receipt["result_id"])
      invalid! unless receipt["operation"] == payload["operation"]
      invalid! unless receipt["target_ref"] == payload.dig("target", "target_ref")
      invalid! unless receipt["target_version_before"] == payload.dig("target", "target_version")
      invalid! unless receipt["domain_outcome"] == DOMAIN_OUTCOMES.fetch(payload["operation"])
      validate_related_effects!(receipt["related_effects"])
      validate_effect_correspondence!(payload["planned_related_effects"], receipt["related_effects"])

      if payload["operation"].end_with?(".delete")
        invalid! unless receipt["target_version_after"].nil? && payload["after"].nil?
      else
        target_version!(receipt["target_version_after"])
        invalid! if payload["after"].nil?
      end

      completed_at = timestamp!(receipt["completed_at"])
      validate_executed_snapshot!(receipt["executed_snapshot"], operation: payload["operation"], completed_at: receipt["completed_at"])
      validate_completion_retention!(payload, completed_at: completed_at, completed_at_text: receipt["completed_at"])
      validate_refresh_scope!(payload["refresh_scope"], provider: payload["provider"], completed_at: completed_at, completed_at_text: receipt["completed_at"])
    end

    def validate_tombstone_receipt!(payload)
      receipt = payload["receipt"]
      exact!(receipt, %w[kind result_id operation completed_at domain_outcome])
      invalid! unless receipt["kind"] == "tombstone" && receipt["operation"] == payload["operation"]
      invalid! unless receipt["domain_outcome"] == DOMAIN_OUTCOMES.fetch(payload["operation"])
      uuid!(receipt["result_id"])
      completed_at = timestamp!(receipt["completed_at"])
      validate_completion_retention!(payload, completed_at: completed_at, completed_at_text: receipt["completed_at"])
    end

    def validate_completion_retention!(payload, completed_at:, completed_at_text:)
      {
        "receipt_detail_available_until" => 30 * 86_400,
        "status_available_until" => 400 * 86_400,
        "idempotency_available_until" => 400 * 86_400
      }.each do |key, delta|
        derived = timestamp!(payload[key])
        invalid! unless derived - completed_at == delta
        invalid! unless timestamp_fraction(payload[key]) == timestamp_fraction(completed_at_text)
      end
    end

    def validate_refresh_scope!(value, provider:, completed_at:, completed_at_text:)
      exact!(value, %w[capability scope_ref expires_at security_context_digest])
      expected = provider == "chrono_flow" ? "schedule_context" : "task_today_summary"
      invalid! unless value["capability"] == expected
      reference!(value["scope_ref"], SCOPE_REF)
      sha256!(value["security_context_digest"])
      expiry = timestamp!(value["expires_at"])
      invalid! unless expiry - completed_at == 600
      invalid! unless timestamp_fraction(value["expires_at"]) == timestamp_fraction(completed_at_text)
    end

    def validate_executed_snapshot!(value, operation:, completed_at:)
      if operation == "task.complete"
        exact!(value, %w[kind status completed_at])
        invalid! unless value["kind"] == "task_completion" && value["status"] == "done" && value["completed_at"] == completed_at
        timestamp!(value["completed_at"])
      else
        invalid! unless value.nil?
      end
    end

    def validate_candidates!(value, provider:)
      exact!(value, %w[truncated items])
      invalid! unless [ true, false ].include?(value["truncated"])
      items = value["items"]
      invalid! unless items.instance_of?(Array) && items.length <= 5
      expected_kind = provider == "chrono_flow" ? "event" : "task"
      items.each do |candidate|
        exact!(candidate, %w[candidate_ref kind display target_version])
        candidate_ref!(candidate["candidate_ref"])
        invalid! unless candidate["kind"] == expected_kind
        target_version!(candidate["target_version"])
        validate_display!(candidate["display"], kind: candidate["kind"])
      end
    end

    def validate_target!(value, provider:)
      exact!(value, %w[target_ref target_version kind display])
      target_ref!(value["target_ref"])
      target_version!(value["target_version"])
      expected_kind = provider == "chrono_flow" ? "event" : "task"
      invalid! unless value["kind"] == expected_kind
      validate_display!(value["display"], kind: value["kind"])
    end

    def validate_display!(value, kind:)
      allowed = %w[title start_at end_at start_on end_on all_day status deadline]
      invalid! unless value.instance_of?(Hash) && (value.keys - allowed).empty? && value.key?("title")
      display_title!(value["title"])
      if kind == "event"
        invalid! if value.key?("status") || value.key?("deadline")
        validate_event_display_time!(value) if value.keys.any? { |key| %w[start_at end_at start_on end_on all_day].include?(key) }
      elsif kind == "task"
        invalid! if value.keys.any? { |key| %w[start_at end_at start_on end_on all_day].include?(key) }
        invalid! if value.key?("status") && !%w[todo doing done canceled].include?(value["status"])
        validate_deadline!(value["deadline"]) if value.key?("deadline") && !value["deadline"].nil?
      else
        invalid!
      end
    end

    def validate_event_display_time!(value)
      invalid! unless [ true, false ].include?(value["all_day"])
      if value["all_day"]
        invalid! unless value["start_at"].nil? && value["end_at"].nil?
        invalid! unless date!(value["end_on"]) > date!(value["start_on"])
      else
        invalid! unless value["start_on"].nil? && value["end_on"].nil?
        invalid! unless timestamp!(value["end_at"]) > timestamp!(value["start_at"])
      end
    end

    def validate_snapshot!(value, provider:)
      invalid! unless value.instance_of?(Hash)
      if provider == "chrono_flow"
        exact!(value, EVENT_KEYS)
        invalid! unless value["kind"] == "event"
        event_title!(value["title"])
        description!(value["description"]) unless value["description"].nil?
        event_location!(value["location"]) unless value["location"].nil?
        validate_schedule!(value["schedule"])
      else
        exact!(value, TASK_KEYS)
        invalid! unless value["kind"] == "task"
        task_title!(value["title"])
        description!(value["description"]) unless value["description"].nil?
        invalid! unless %w[todo doing done canceled].include?(value["status"])
        invalid! unless %w[low normal high urgent].include?(value["priority"])
        validate_deadline!(value["deadline"])
      end
      value
    end

    def validate_schedule!(value)
      exact!(value, %w[precision start_at end_at start_on end_on time_zone end_exclusive])
      invalid! unless value["end_exclusive"] == true
      time_zone!(value["time_zone"])
      case value["precision"]
      when "datetime"
        invalid! unless value["start_on"].nil? && value["end_on"].nil?
        invalid! unless timestamp!(value["end_at"]) > timestamp!(value["start_at"])
      when "date"
        invalid! unless value["start_at"].nil? && value["end_at"].nil?
        invalid! unless date!(value["end_on"]) > date!(value["start_on"])
      else
        invalid!
      end
    end

    def validate_deadline!(value)
      exact!(value, %w[precision due_on due_at time_zone])
      time_zone!(value["time_zone"])
      case value["precision"]
      when "none" then invalid! unless value["due_on"].nil? && value["due_at"].nil?
      when "date"
        invalid! unless value["due_at"].nil?
        date!(value["due_on"])
      when "datetime"
        invalid! unless value["due_on"].nil?
        timestamp!(value["due_at"])
      else invalid!
      end
    end

    def validate_changed_fields!(payload)
      fields = validate_changed_fields_array!(payload["changed_fields"], allow_empty: false)
      policy = OPERATION_POLICY.fetch(payload["operation"])
      invalid! unless (fields - policy.fetch(:fields)).empty?
      invalid! unless fields == [ "$record" ] if payload["operation"].end_with?(".delete")
      invalid! unless payload["planned_related_effects"]["type"] == policy.fetch(:plan)

      before = payload["before"]
      after = payload["after"]
      case payload["operation"]
      when "event.delete", "task.delete"
        invalid! unless after.nil?
      when "event.update"
        invalid! unless fields == semantic_differences(before, after, %w[title description location schedule])
      when "task.update"
        invalid! unless %w[todo doing].include?(before["status"]) && before["status"] == after["status"]
        invalid! unless fields == semantic_differences(before, after, %w[title description priority deadline])
      when "task.complete"
        invalid! unless fields == [ "status" ] && %w[todo doing].include?(before["status"]) && after["status"] == "done"
        invalid! unless semantic_differences(before, after, TASK_KEYS - [ "kind" ]) == [ "status" ]
      when "task.postpone"
        invalid! unless fields == [ "deadline" ] && %w[todo doing].include?(before["status"]) && before["status"] == after["status"]
        invalid! unless semantic_differences(before, after, %w[title description status priority deadline]) == [ "deadline" ]
        validate_postponed_deadline!(before["deadline"], after["deadline"])
      end
    end

    def semantic_differences(before, after, keys)
      invalid! if after.nil?
      keys.select { |key| canonical_json(before[key]) != canonical_json(after[key]) }.sort
    end

    def validate_postponed_deadline!(before, after)
      invalid! unless %w[date datetime].include?(before["precision"]) && before["precision"] == after["precision"]
      if before["precision"] == "date"
        invalid! unless date!(after["due_on"]) > date!(before["due_on"])
      else
        invalid! unless timestamp!(after["due_at"]) > timestamp!(before["due_at"])
      end
    end

    def validate_changed_fields_array!(value, allow_empty:)
      invalid! unless value.instance_of?(Array) && (allow_empty || !value.empty?) && value.length <= 4
      value.each { |field| text!(field, maximum: 20, nonblank: true) }
      invalid! unless value == value.sort && value.uniq == value
      value
    end

    def validate_planned_effects!(value)
      invalid! unless value.instance_of?(Hash)
      case value["type"]
      when "none"
        exact!(value, %w[type])
      when "event_delete"
        exact!(value, %w[type self_participants_to_delete reminders_to_delete chat_rooms_to_delete chat_messages_to_delete ai_recommendation_refs_to_nullify ai_context_log_refs_to_nullify])
        %w[self_participants_to_delete chat_rooms_to_delete chat_messages_to_delete ai_recommendation_refs_to_nullify ai_context_log_refs_to_nullify].each { |key| count!(value[key]) }
        validate_reminder_counts!(value["reminders_to_delete"])
      when "task_delete"
        exact!(value, %w[type task_sources_to_delete calendar_event_candidates_to_delete])
        count!(value["task_sources_to_delete"])
        count!(value["calendar_event_candidates_to_delete"])
      else invalid!
      end
    end

    def validate_related_effects!(value)
      invalid! unless value.instance_of?(Hash)
      case value["type"]
      when "none" then exact!(value, %w[type])
      when "event_delete"
        exact!(value, %w[type self_participants_deleted reminders_deleted chat_rooms_deleted chat_messages_deleted ai_recommendation_refs_nullified ai_context_log_refs_nullified])
        %w[self_participants_deleted chat_rooms_deleted chat_messages_deleted ai_recommendation_refs_nullified ai_context_log_refs_nullified].each { |key| count!(value[key]) }
        validate_reminder_counts!(value["reminders_deleted"])
      when "task_delete"
        exact!(value, %w[type task_sources_deleted calendar_event_candidates_deleted])
        count!(value["task_sources_deleted"])
        count!(value["calendar_event_candidates_deleted"])
      else invalid!
      end
    end

    def validate_effect_correspondence!(planned, actual)
      expected = case planned["type"]
      when "none" then { "type" => "none" }
      when "event_delete"
        {
          "type" => "event_delete",
          "self_participants_deleted" => planned["self_participants_to_delete"],
          "reminders_deleted" => planned["reminders_to_delete"],
          "chat_rooms_deleted" => planned["chat_rooms_to_delete"],
          "chat_messages_deleted" => planned["chat_messages_to_delete"],
          "ai_recommendation_refs_nullified" => planned["ai_recommendation_refs_to_nullify"],
          "ai_context_log_refs_nullified" => planned["ai_context_log_refs_to_nullify"]
        }
      when "task_delete"
        {
          "type" => "task_delete",
          "task_sources_deleted" => planned["task_sources_to_delete"],
          "calendar_event_candidates_deleted" => planned["calendar_event_candidates_to_delete"]
        }
      end
      invalid! unless canonical_json(actual) == canonical_json(expected)
    end

    def validate_reminder_counts!(value)
      exact!(value, %w[pending delivered cancelled])
      value.each_value { |count| count!(count) }
    end

    def canonical_value(value, depth)
      invalid! if depth > 64
      case value
      when Hash
        invalid! unless value.is_a?(Hash)
        value.keys.each do |key|
          text!(key, maximum: 200)
          invalid! unless ASCII_KEY.match?(key)
        end
        value.keys.sort_by { |key| key.encode(Encoding::UTF_8).bytes }.to_h do |key|
          [ key, canonical_value(value.fetch(key), depth + 1) ]
        end
      when Array
        value.map { |item| canonical_value(item, depth + 1) }
      when String
        text!(value, maximum: 65_536)
        value
      when Integer, TrueClass, FalseClass, NilClass
        value
      else
        invalid!
      end
    end

    def common_request!(payload)
      invalid! unless payload["version"] == VERSION
      uuid!(payload["request_id"])
      uuid!(payload["trace_id"])
    end

    def operation!(value)
      invalid! unless OPERATIONS.include?(value)
      value
    end

    def exact!(value, keys)
      invalid! unless value.is_a?(Hash) && value.keys.sort == keys.sort
    rescue ArgumentError
      invalid!
    end

    def required!(payload, keys)
      invalid! unless keys.all? { |key| !payload[key].nil? }
    end

    def nulls!(payload, keys)
      invalid! unless keys.all? { |key| payload[key].nil? }
    end

    def text!(value, maximum:, nonblank: false)
      invalid! unless value.instance_of?(String) && value.valid_encoding? && [ Encoding::UTF_8, Encoding::US_ASCII ].include?(value.encoding)
      invalid! if value.each_codepoint.count > maximum
      invalid! if nonblank && !value.match?(/[^\p{Space}]/u)
      value
    rescue ArgumentError
      invalid!
    end

    def optional_text!(value, maximum:, nonblank: false)
      text!(value, maximum: maximum, nonblank: nonblank) unless value.nil?
    end

    # Field-specific validation deliberately preserves the exact String. These
    # helpers never strip, normalize, case-fold, or replace characters, so the
    # value shown for confirmation can be the value bound into the digest and
    # rechecked immediately before an exact domain write.
    def control_free_text!(value, maximum:, nonblank: false)
      text!(value, maximum: maximum, nonblank: nonblank)
      invalid! if CONTROL_CHARACTER.match?(value)
      value
    end

    # Multiline fields permit LF only. Tabs, NUL, CR (including CRLF), the
    # remaining C0 range, DEL, and C1 controls are rejected without rewriting.
    def multiline_text!(value, maximum:, nonblank: false)
      text!(value, maximum: maximum, nonblank: nonblank)
      invalid! if MULTILINE_DISALLOWED_CONTROL_CHARACTER.match?(value)
      value
    end

    def user_message!(value, maximum:)
      multiline_text!(value, maximum: maximum, nonblank: true)
    end

    def event_title!(value)
      control_free_text!(value, maximum: 200, nonblank: true)
    end

    def event_location!(value)
      control_free_text!(value, maximum: 200)
    end

    def task_title!(value)
      control_free_text!(value, maximum: 200, nonblank: true)
    end

    def display_title!(value)
      control_free_text!(value, maximum: 200, nonblank: true)
    end

    def provider_generated_text!(value)
      control_free_text!(value, maximum: 1_000, nonblank: true)
    end

    def description!(value)
      multiline_text!(value, maximum: 4_000)
    end

    def uuid!(value)
      text!(value, maximum: 36, nonblank: true)
      invalid! unless UUID.match?(value)
      value
    end

    def sha256!(value)
      text!(value, maximum: 64, nonblank: true)
      invalid! unless SHA256.match?(value)
      value
    end

    def candidate_ref!(value)
      reference!(value, CANDIDATE_REF)
    end

    def target_ref!(value)
      reference!(value, TARGET_REF)
    end

    def target_version!(value)
      reference!(value, TARGET_VERSION)
    end

    def relationship_fingerprint!(value)
      reference!(value, RELATIONSHIP_FINGERPRINT)
    end

    def reference!(value, pattern)
      text!(value, maximum: 64, nonblank: true)
      invalid! unless pattern.match?(value)
      value
    end

    def revision!(value)
      invalid! unless value.instance_of?(Integer) && value.between?(1, 2_147_483_647)
      value
    end

    def count!(value)
      invalid! unless value.instance_of?(Integer) && value.between?(0, 2_147_483_647)
      value
    end

    def locale!(value)
      text!(value, maximum: 35, nonblank: true)
      invalid! unless value.length >= 2 && LOCALE.match?(value)
      value
    end

    def time_zone!(value)
      text!(value, maximum: 64, nonblank: true)
      TZInfo::Timezone.get(value)
      value
    rescue TZInfo::InvalidTimezoneIdentifier
      invalid!
    end

    def date!(value)
      text!(value, maximum: 10, nonblank: true)
      invalid! unless /\A\d{4}-\d{2}-\d{2}\z/.match?(value)
      Date.iso8601(value)
    rescue Date::Error
      invalid!
    end

    def timestamp!(value)
      text!(value, maximum: 40, nonblank: true)
      match = TIMESTAMP.match(value)
      invalid! unless match
      date!(match[1])
      Time.iso8601(value)
    rescue ArgumentError
      invalid!
    end

    def optional_timestamp!(value)
      timestamp!(value) unless value.nil?
    end

    def execution_timestamp!(value)
      invalid! unless value.instance_of?(String) && EXECUTION_TIMESTAMP.match?(value)
      timestamp!(value)
    end

    def timestamp_fraction(value)
      match = TIMESTAMP.match(value)
      invalid! unless match
      match[2]
    end

    def secure_equal?(left, right)
      return false unless left.bytesize == right.bytesize

      left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
    end

    def invalid!
      raise Invalid.new, cause: nil
    end
  end
end
