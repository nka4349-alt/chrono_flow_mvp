# frozen_string_literal: true

class CreateSecretaryMutationRecords < ActiveRecord::Migration[7.1]
  def change
    create_table :secretary_mutation_proposals do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.uuid :public_id, null: false
      t.uuid :home_subject, null: false
      t.string :identity_issuer, null: false
      t.string :identity_subject, null: false
      t.string :operation, null: false
      t.string :locale, null: false
      t.string :time_zone, null: false
      t.string :status, null: false
      t.string :reason_code
      t.integer :revision, null: false, default: 1
      t.datetime :execution_expires_at, null: false
      t.datetime :status_available_until, null: false
      t.datetime :receipt_detail_available_until
      t.datetime :idempotency_available_until
      t.jsonb :messages, null: false, default: []
      t.text :question
      t.jsonb :candidate_mappings, null: false, default: []
      t.string :target_ref
      t.bigint :target_event_id
      t.string :target_version
      t.string :relationship_fingerprint
      t.jsonb :target_display
      t.jsonb :before_snapshot
      t.jsonb :after_snapshot
      t.jsonb :changed_fields, null: false, default: []
      t.jsonb :planned_related_effects
      t.string :content_digest
      t.string :idempotency_key_digest
      t.uuid :result_id
      t.jsonb :receipt
      t.jsonb :refresh_scope
      t.datetime :completed_at
      t.datetime :cancelled_at
      t.datetime :conflicted_at
      t.datetime :expired_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :secretary_mutation_proposals, :public_id, unique: true
    add_index :secretary_mutation_proposals, :result_id, unique: true
    add_index :secretary_mutation_proposals, :target_event_id
    add_foreign_key :secretary_mutation_proposals, :events, column: :target_event_id, on_delete: :nullify
    add_index :secretary_mutation_proposals, %i[user_id idempotency_key_digest], unique: true,
      where: 'idempotency_key_digest IS NOT NULL', name: 'secretary_mutation_actor_idempotency'
    add_check_constraint :secretary_mutation_proposals, 'revision > 0', name: 'secretary_mutation_revision_positive'
    add_check_constraint :secretary_mutation_proposals,
      "operation IN ('event.update','event.delete')", name: 'secretary_mutation_flow_operation'
    add_check_constraint :secretary_mutation_proposals,
      "status IN ('needs_target','needs_clarification','ready','rejected','completed','completed_tombstone','cancelled','expired','conflicted')",
      name: 'secretary_mutation_status_closed'

    create_table :secretary_mutation_audits do |t|
      t.references :secretary_mutation_proposal, null: false,
        foreign_key: { on_delete: :cascade }, index: { name: 'idx_mutation_audits_proposal' }
      t.string :event_type, null: false
      t.integer :revision, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end

    create_table :secretary_mutation_outbox_entries do |t|
      t.references :secretary_mutation_proposal, null: false,
        foreign_key: { on_delete: :cascade }, index: { name: 'idx_mutation_outbox_proposal' }
      t.uuid :public_id, null: false
      t.string :event_type, null: false
      t.string :status, null: false, default: 'pending'
      t.jsonb :payload, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.datetime :published_at
      t.timestamps
    end

    add_index :secretary_mutation_outbox_entries, :public_id, unique: true,
      name: 'idx_mutation_outbox_public_id'
    add_check_constraint :secretary_mutation_outbox_entries,
      "status IN ('pending','published','discarded')", name: 'secretary_mutation_outbox_status_closed'
  end
end
