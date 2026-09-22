# frozen_string_literal: true

class SecretaryMutationOutboxEntry < ApplicationRecord
  belongs_to :secretary_mutation_proposal

  validates :public_id, :event_type, :status, :occurred_at, presence: true
  validates :status, inclusion: { in: %w[pending published discarded] }
end
