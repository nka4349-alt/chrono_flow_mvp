# frozen_string_literal: true

class SecretaryCreationProposal < ApplicationRecord
  belongs_to :user
  validates :public_id, :home_subject, :identity_issuer, :identity_subject, :status, :expires_at, presence: true
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  # Executed markers/receipts are permanent. Do not add a TTL cleanup or dependent destroy.
  def terminal?
    %w[completed cancelled expired rejected].include?(status)
  end
end
