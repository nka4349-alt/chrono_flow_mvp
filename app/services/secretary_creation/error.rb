# frozen_string_literal: true

module SecretaryCreation
  class Error < StandardError
    STATUSES = { 'invalid_request' => 400, 'unauthenticated' => 401, 'forbidden' => 403, 'not_found' => 404,
      'proposal_changed' => 409, 'already_completed' => 409, 'idempotency_conflict' => 409,
      'expired' => 410, 'unsupported' => 422, 'unavailable' => 503, 'outcome_unknown' => 503 }.freeze
    attr_reader :code
    def initialize(code)
      @code = code.to_s
      super('登録処理を完了できませんでした。内容と接続状態を確認してください。')
    end
    def status = STATUSES.fetch(code)
    def retryable? = %w[unavailable outcome_unknown].include?(code)
  end
end
