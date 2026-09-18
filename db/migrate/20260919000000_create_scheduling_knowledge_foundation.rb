# frozen_string_literal: true

class CreateSchedulingKnowledgeFoundation < ActiveRecord::Migration[7.1]
  def change
    create_table :knowledge_documents do |t|
      t.string :public_id, null: false, limit: 64
      t.string :series_ref, null: false, limit: 200
      t.string :document_version, null: false, limit: 200
      t.string :tenant_scope_ref, null: false, limit: 200
      t.string :user_scope_ref, null: false, limit: 200
      t.string :place_ref, null: false, limit: 200
      t.string :source_type, null: false
      t.string :visibility, null: false, default: 'private'
      t.string :title, null: false, limit: 500
      t.string :language, null: false, limit: 32
      t.string :status, null: false, default: 'draft'
      t.text :canonical_text, null: false
      t.string :content_sha256, null: false, limit: 64
      t.string :source_sha256, null: false, limit: 64
      t.string :source_timezone, null: false, limit: 100
      t.jsonb :source_temporal_json, null: false, default: {}
      t.datetime :issued_at
      t.datetime :valid_from
      t.datetime :valid_until
      t.datetime :verified_at
      t.datetime :verified_until
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :knowledge_documents, :public_id, unique: true
    add_index :knowledge_documents, %i[tenant_scope_ref user_scope_ref series_ref document_version],
              unique: true, name: 'index_knowledge_documents_on_scoped_version'
    add_index :knowledge_documents, %i[tenant_scope_ref user_scope_ref series_ref], unique: true,
              where: "status = 'active' AND deleted_at IS NULL", name: 'index_knowledge_documents_on_one_active_version'
    add_index :knowledge_documents, %i[tenant_scope_ref user_scope_ref place_ref status],
              name: 'index_knowledge_documents_on_owner_place_status'
    add_check_constraint :knowledge_documents, "source_type IN ('official_facility_document', 'user_note')", name: 'knowledge_documents_source_type_closed'
    add_check_constraint :knowledge_documents, "status IN ('draft', 'active', 'superseded', 'revoked', 'expired')", name: 'knowledge_documents_status_closed'
    add_check_constraint :knowledge_documents, "visibility IN ('private', 'tenant') AND (source_type <> 'user_note' OR visibility = 'private')", name: 'knowledge_documents_visibility_closed'
    add_check_constraint :knowledge_documents, "content_sha256 ~ '^[0-9a-f]{64}$' AND source_sha256 ~ '^[0-9a-f]{64}$'", name: 'knowledge_documents_hashes_valid'
    add_check_constraint :knowledge_documents, "content_sha256 = encode(sha256(convert_to(canonical_text, 'UTF8')), 'hex')", name: 'knowledge_documents_content_hash_matches'
    add_check_constraint :knowledge_documents, "char_length(canonical_text) > 0 AND position(chr(13) in canonical_text) = 0", name: 'knowledge_documents_canonical_text_valid'
    add_check_constraint :knowledge_documents, "jsonb_typeof(source_temporal_json) = 'object'", name: 'knowledge_documents_temporal_object'
    add_check_constraint :knowledge_documents, 'valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from', name: 'knowledge_documents_validity_ordered'
    add_check_constraint :knowledge_documents, 'verified_until IS NULL OR verified_at IS NULL OR verified_until > verified_at', name: 'knowledge_documents_verification_ordered'
    add_check_constraint :knowledge_documents, 'valid_from IS NULL OR ((valid_until IS NULL OR valid_from < valid_until) AND (verified_until IS NULL OR valid_from < verified_until))', name: 'knowledge_documents_effective_interval_ordered'
    add_nonblank_constraint :knowledge_documents, %w[public_id series_ref document_version tenant_scope_ref user_scope_ref place_ref title language source_timezone]

    create_table :knowledge_chunks do |t|
      t.references :knowledge_document, null: false, foreign_key: { on_delete: :cascade }
      t.string :public_id, null: false, limit: 64
      t.integer :sequence, null: false
      t.jsonb :section_path_json, null: false, default: []
      t.integer :page_number, null: false
      t.integer :character_start, null: false
      t.integer :character_end, null: false
      t.text :content, null: false
      t.string :content_sha256, null: false, limit: 64
      t.datetime :invalidated_at
      t.timestamps
    end
    add_index :knowledge_chunks, :public_id, unique: true
    add_index :knowledge_chunks, %i[knowledge_document_id sequence], unique: true, name: 'index_knowledge_chunks_on_document_sequence'
    add_index :knowledge_chunks, %i[knowledge_document_id character_start character_end], unique: true, name: 'index_knowledge_chunks_on_document_interval'
    add_check_constraint :knowledge_chunks, 'sequence >= 0 AND page_number > 0', name: 'knowledge_chunks_position_valid'
    add_check_constraint :knowledge_chunks, 'character_start >= 0 AND character_end > character_start AND character_end - character_start = char_length(content) AND char_length(content) <= 1200', name: 'knowledge_chunks_interval_valid'
    add_check_constraint :knowledge_chunks, "content_sha256 ~ '^[0-9a-f]{64}$' AND content_sha256 = encode(sha256(convert_to(content, 'UTF8')), 'hex')", name: 'knowledge_chunks_content_hash_matches'
    add_check_constraint :knowledge_chunks, "jsonb_typeof(section_path_json) = 'array'", name: 'knowledge_chunks_section_path_array'

    create_table :place_knowledge_links do |t|
      t.references :knowledge_document, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :tenant_scope_ref, null: false, limit: 200
      t.string :user_scope_ref, null: false, limit: 200
      t.string :place_ref, null: false, limit: 200
      t.string :knowledge_requirement, null: false, default: 'optional'
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :place_knowledge_links, %i[tenant_scope_ref user_scope_ref place_ref], name: 'index_place_knowledge_links_on_owner_place'
    add_check_constraint :place_knowledge_links, "knowledge_requirement IN ('none', 'optional', 'required')", name: 'place_knowledge_links_requirement_closed'
    add_nonblank_constraint :place_knowledge_links, %w[tenant_scope_ref user_scope_ref place_ref]
  end

  private

  def add_nonblank_constraint(table, columns)
    expression = columns.map { |column| "#{column} ~ '[^[:space:]]'" }.join(' AND ')
    add_check_constraint table, expression, name: "#{table}_identity_nonblank"
  end
end
