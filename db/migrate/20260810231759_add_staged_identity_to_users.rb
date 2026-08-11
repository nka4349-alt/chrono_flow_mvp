# frozen_string_literal: true

class AddStagedIdentityToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :identity_issuer, :string
    add_column :users, :identity_subject, :string

    add_check_constraint(
      :users,
      <<~SQL.squish,
        (
          identity_issuer IS NULL
          AND identity_subject IS NULL
        )
        OR
        (
          identity_issuer IS NOT NULL
          AND identity_subject IS NOT NULL
          AND identity_issuer ~ '[^[:space:]]'
          AND identity_subject ~ '[^[:space:]]'
        )
      SQL
      name: 'users_identity_pair_complete_and_nonblank'
    )

    add_index(
      :users,
      %i[identity_issuer identity_subject],
      unique: true,
      where: <<~SQL.squish,
        identity_issuer IS NOT NULL
        AND identity_subject IS NOT NULL
      SQL
      name: 'index_users_on_identity_issuer_and_subject_unique'
    )
  end
end
