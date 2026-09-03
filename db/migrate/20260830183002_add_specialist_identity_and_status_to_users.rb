# frozen_string_literal: true

class AddSpecialistIdentityAndStatusToUsers < ActiveRecord::Migration[7.1]
  IDENTITY_PAIR_CHECK = <<~SQL.squish.freeze
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
  STATUS_CHECK = "status IN ('active', 'suspended')".freeze

  def up
    add_column users_table, :identity_issuer, :string
    add_column users_table, :identity_subject, :string
    add_column users_table, :status, :string

    backfill_active_status
    change_column_default users_table, :status, from: nil, to: 'active'
    change_column_null users_table, :status, false

    add_check_constraint(
      users_table,
      IDENTITY_PAIR_CHECK,
      name: identity_pair_constraint_name
    )
    add_check_constraint(
      users_table,
      STATUS_CHECK,
      name: status_constraint_name
    )
    add_index(
      users_table,
      %i[identity_issuer identity_subject],
      unique: true,
      where: 'identity_issuer IS NOT NULL AND identity_subject IS NOT NULL',
      name: identity_index_name
    )
  end

  def down
    remove_index users_table, name: identity_index_name
    remove_check_constraint users_table, name: status_constraint_name
    remove_check_constraint users_table, name: identity_pair_constraint_name
    remove_column users_table, :status
    remove_column users_table, :identity_subject
    remove_column users_table, :identity_issuer
  end

  private

  def backfill_active_status
    table = connection.quote_table_name(users_table)
    status = connection.quote_column_name(:status)
    active = connection.quote('active')

    execute("UPDATE #{table} SET #{status} = #{active} WHERE #{status} IS NULL")
  end

  def users_table
    :users
  end

  def identity_pair_constraint_name
    'users_identity_pair_complete_and_nonblank'
  end

  def status_constraint_name
    'users_status_active_or_suspended'
  end

  def identity_index_name
    'index_users_on_identity_issuer_and_subject_unique'
  end
end
