# frozen_string_literal: true

class SecretaryMutationRetentionCleanupJob < ApplicationJob
  queue_as :default

  def perform(batch_size: SecretaryMutation::RetentionCleanup::DEFAULT_BATCH_SIZE)
    SecretaryMutation::RetentionCleanup.call(batch_size: batch_size)
  end
end
