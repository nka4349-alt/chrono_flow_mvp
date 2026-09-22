# frozen_string_literal: true

class SecretaryMutationAudit < ApplicationRecord
  belongs_to :secretary_mutation_proposal

  validates :event_type, :revision, :occurred_at, presence: true

  before_update { throw(:abort) }
  before_destroy { throw(:abort) }
end
