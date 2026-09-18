# frozen_string_literal: true

class CreateSecretaryCreationProposals < ActiveRecord::Migration[7.1]
  def change
    create_table :secretary_creation_proposals do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.uuid :public_id, null: false
      t.uuid :home_subject, null: false
      t.string :identity_issuer, null: false
      t.string :identity_subject, null: false
      t.string :status, null: false
      t.integer :revision, null: false, default: 1
      t.datetime :expires_at, null: false
      t.jsonb :messages, null: false, default: []
      t.jsonb :details
      t.string :content_digest
      t.text :question
      t.uuid :idempotency_key
      t.uuid :result_id
      t.bigint :created_event_id
      t.datetime :completed_at
      t.timestamps
    end
    add_index :secretary_creation_proposals, :public_id, unique: true
    add_index :secretary_creation_proposals, :result_id, unique: true
    add_index :secretary_creation_proposals, [:user_id, :idempotency_key], unique: true, name: 'secretary_creation_actor_key'
    add_check_constraint :secretary_creation_proposals, "revision > 0", name: 'secretary_creation_revision_positive'
    add_check_constraint :secretary_creation_proposals,
      "status IN ('needs_clarification','ready','rejected','completed','cancelled','expired')", name: 'secretary_creation_valid_status'
    add_check_constraint :secretary_creation_proposals,
      "(status = 'completed' AND idempotency_key IS NOT NULL AND result_id IS NOT NULL AND created_event_id IS NOT NULL AND completed_at IS NOT NULL AND details IS NOT NULL AND content_digest IS NOT NULL) OR (status <> 'completed' AND idempotency_key IS NULL AND result_id IS NULL AND created_event_id IS NULL AND completed_at IS NULL)",
      name: 'secretary_creation_receipt_complete'
  end
end
