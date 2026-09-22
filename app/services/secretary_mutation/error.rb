# frozen_string_literal: true

module SecretaryMutation
  class Error < StandardError
    DEFINITIONS = {
      'invalid_request' => [400, '操作リクエストを確認できませんでした。', false],
      'unauthenticated' => [401, '認証を確認できませんでした。', false],
      'forbidden' => [403, 'この操作は実行できません。', false],
      'not_found' => [404, '操作対象を確認できませんでした。', false],
      'proposal_changed' => [409, '確認内容が変わりました。もう一度確認してください。', false],
      'target_changed' => [409, '対象が確認後に変わりました。', false],
      'idempotency_conflict' => [409, '同じ確認操作を安全に照合できませんでした。', false],
      'conflict' => [409, '操作が競合しました。', false],
      'expired' => [410, '確認期限が切れました。', false],
      'unsupported' => [415, 'この形式は利用できません。', false],
      'in_progress' => [202, '操作結果を確認中です。', true],
      'unavailable' => [503, '操作機能を一時的に利用できません。', true],
      'outcome_unknown' => [503, '操作結果を確認できません。状態を照会してください。', false]
    }.freeze

    attr_reader :code, :status

    def initialize(code, status: nil)
      @code = code.to_s
      definition = DEFINITIONS.fetch(@code)
      @status = status || definition[0]
      @retryable = definition[2]
      super(definition[1])
    end

    def retryable? = @retryable
  end
end
