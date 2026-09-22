# frozen_string_literal: true

class AddStatusPurgedAtToSecretaryMutationProposals < ActiveRecord::Migration[7.1]
  def change
    add_column :secretary_mutation_proposals, :status_purged_at, :datetime
    add_index :secretary_mutation_proposals, %i[status_available_until id],
      where: 'status_purged_at IS NULL', name: 'idx_mutation_proposals_pending_status_purge'
  end
end
