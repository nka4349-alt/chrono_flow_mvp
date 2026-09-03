# frozen_string_literal: true

require 'test_helper'
require 'securerandom'
require 'stringio'
require Rails.root.join('db/migrate/20260830183002_add_specialist_identity_and_status_to_users').to_s

class UserIdentityTest < ActiveSupport::TestCase
  PASSWORD = 'Password-123!'
  IDENTITY_CHECK_CONSTRAINT = 'users_identity_pair_complete_and_nonblank'
  STATUS_CHECK_CONSTRAINT = 'users_status_active_or_suspended'
  UNIQUE_INDEX = 'index_users_on_identity_issuer_and_subject_unique'
  MIGRATION_TEST_TABLE = :specialist_identity_migration_test_users

  class TemporaryTableMigration < AddSpecialistIdentityAndStatusToUsers
    private

    def users_table
      UserIdentityTest::MIGRATION_TEST_TABLE
    end

    def identity_pair_constraint_name
      'test_users_identity_pair_complete_and_nonblank'
    end

    def status_constraint_name
      'test_users_status_active_or_suspended'
    end

    def identity_index_name
      'index_test_users_on_specialist_identity_unique'
    end
  end

  test 'user without a specialist identity keeps the active default' do
    user = create_user!

    assert_nil user.identity_issuer
    assert_nil user.identity_subject
    assert_equal 'active', user.status
    assert_predicate user, :active_for_specialist?
  end

  test 'specialist identity requires both nonblank opaque values' do
    invalid_attributes = [
      { identity_issuer: nil, identity_subject: 'subject-a' },
      { identity_issuer: 'issuer-a', identity_subject: nil },
      { identity_issuer: '', identity_subject: 'subject-a' },
      { identity_issuer: 'issuer-a', identity_subject: '' },
      { identity_issuer: " \t\n", identity_subject: 'subject-a' },
      { identity_issuer: 'issuer-a', identity_subject: " \t\n" }
    ]

    invalid_attributes.each do |attributes|
      assert_not build_user(attributes).valid?, attributes.inspect
    end
  end

  test 'specialist identity preserves case and surrounding whitespace' do
    issuer = '  HTTPS://Issuer.Example/OIDC  '
    subject = "\tOpaque-Subject-AbC\n"
    user = create_user!(identity_issuer: issuer, identity_subject: subject)

    user.reload

    assert_equal issuer, user.identity_issuer
    assert_equal subject, user.identity_subject
  end

  test 'specialist identity pair uniqueness is exact and case sensitive' do
    create_user!(identity_issuer: 'Issuer-A', identity_subject: 'Subject-A')
    duplicate = build_user(identity_issuer: 'Issuer-A', identity_subject: 'Subject-A')

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:identity_subject], 'has already been taken'
    assert_predicate build_user(identity_issuer: 'issuer-a', identity_subject: 'Subject-A'), :valid?
    assert_predicate build_user(identity_issuer: 'Issuer-A', identity_subject: 'subject-a'), :valid?
  end

  test 'multiple users may omit the specialist identity pair' do
    first = create_user!
    second = create_user!

    assert_nil first.reload.identity_issuer
    assert_nil second.reload.identity_subject
  end

  test 'status accepts only active and suspended' do
    assert_predicate build_user(status: 'active'), :valid?
    assert_predicate build_user(status: 'suspended'), :valid?

    invalid = build_user(status: 'disabled')
    assert_not invalid.valid?
    assert_includes invalid.errors[:status], 'is not included in the list'
  end

  test 'active scope and active_for_specialist are exact status checks' do
    active_user = create_user!(status: 'active')
    suspended_user = create_user!(status: 'suspended')

    assert_includes User.active, active_user
    refute_includes User.active, suspended_user
    assert_predicate active_user, :active_for_specialist?
    refute_predicate suspended_user, :active_for_specialist?
  end

  test 'identity attributes are filtered from model inspection' do
    issuer = 'https://issuer.example/private'
    subject = 'private-subject-value'
    user = build_user(identity_issuer: issuer, identity_subject: subject)

    assert_includes ActiveRecord::Base.filter_attributes.map(&:to_s), 'identity_issuer'
    assert_includes ActiveRecord::Base.filter_attributes.map(&:to_s), 'identity_subject'
    assert_includes User.filter_attributes.map(&:to_s), 'identity_issuer'
    assert_includes User.filter_attributes.map(&:to_s), 'identity_subject'
    refute_includes user.inspect, issuer
    refute_includes user.inspect, subject
  end

  test 'identity bind values are filtered from Active Record SQL logs' do
    issuer = 'https://issuer.example/private-bind'
    subject = 'private-bind-subject-value'
    user = create_user!(identity_issuer: issuer, identity_subject: subject)
    output = StringIO.new
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(output)
    ActiveRecord::Base.logger.level = Logger::DEBUG

    User.uncached do
      User.where(identity_issuer: issuer, identity_subject: subject).find(user.id)
    end

    refute_includes output.string, issuer
    refute_includes output.string, subject
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  test 'password authentication remains unchanged with specialist attributes' do
    user = create_user!(
      identity_issuer: 'https://issuer.example',
      identity_subject: 'opaque-subject',
      status: 'active'
    )

    assert_equal user, user.authenticate(PASSWORD)
    assert_not user.authenticate('incorrect-password')
  end

  test 'database rejects incomplete and whitespace-only identity pairs' do
    invalid_pairs = [
      { identity_issuer: nil, identity_subject: 'subject-a' },
      { identity_issuer: 'issuer-a', identity_subject: nil },
      { identity_issuer: '', identity_subject: 'subject-a' },
      { identity_issuer: 'issuer-a', identity_subject: '' },
      { identity_issuer: " \t\n", identity_subject: 'subject-a' },
      { identity_issuer: 'issuer-a', identity_subject: " \t\n" }
    ]

    invalid_pairs.each do |attributes|
      user = create_user!

      assert_raises(ActiveRecord::StatementInvalid) do
        User.transaction(requires_new: true) { user.update_columns(attributes) }
      end

      assert_nil user.reload.identity_issuer
      assert_nil user.identity_subject
    end
  end

  test 'database partial index enforces exact pair uniqueness' do
    issuer = 'issuer-db-duplicate'
    subject = 'subject-db-duplicate'
    create_user!(identity_issuer: issuer, identity_subject: subject)
    duplicate = create_user!

    assert_raises(ActiveRecord::RecordNotUnique) do
      User.transaction(requires_new: true) do
        duplicate.update_columns(identity_issuer: issuer, identity_subject: subject)
      end
    end

    duplicate.reload
    assert_nil duplicate.identity_issuer
    assert_nil duplicate.identity_subject

    duplicate.update_columns(identity_issuer: issuer.swapcase, identity_subject: subject)
    assert_equal issuer.swapcase, duplicate.reload.identity_issuer
  end

  test 'database rejects status outside the closed set' do
    user = create_user!

    user.update_columns(status: 'suspended')
    assert_equal 'suspended', user.reload.status
    user.update_columns(status: 'active')

    assert_raises(ActiveRecord::StatementInvalid) do
      User.transaction(requires_new: true) { user.update_columns(status: 'disabled') }
    end

    assert_equal 'active', user.reload.status
  end

  test 'database metadata defines nullable defaultless identity and constrained active status' do
    issuer_column = User.columns_hash.fetch('identity_issuer')
    subject_column = User.columns_hash.fetch('identity_subject')
    status_column = User.columns_hash.fetch('status')

    assert_equal :string, issuer_column.type
    assert_predicate issuer_column, :null
    assert_nil issuer_column.default
    assert_equal :string, subject_column.type
    assert_predicate subject_column, :null
    assert_nil subject_column.default
    assert_equal :string, status_column.type
    assert_not status_column.null
    assert_equal 'active', status_column.default

    constraints = User.connection.check_constraints(:users).index_by(&:name)
    assert_check_constraint_expression(constraints.fetch(IDENTITY_CHECK_CONSTRAINT).expression)
    assert_status_constraint_expression(constraints.fetch(STATUS_CHECK_CONSTRAINT).expression)

    index = User.connection.indexes(:users).find { |candidate| candidate.name == UNIQUE_INDEX }
    assert_not_nil index
    assert_predicate index, :unique
    assert_equal %w[identity_issuer identity_subject], index.columns
    assert_equal(
      ['identity_issuer IS NOT NULL', 'identity_subject IS NOT NULL'],
      normalized_predicate_terms(index.where)
    )
    refute_match(/lower/i, index.where)
  end

  test 'migration explicitly backfills existing rows and reverses cleanly' do
    connection = ActiveRecord::Base.connection
    connection.drop_table(MIGRATION_TEST_TABLE, if_exists: true)
    connection.create_table(MIGRATION_TEST_TABLE) do |table|
      table.string :email, null: false
    end
    quoted_table = connection.quote_table_name(MIGRATION_TEST_TABLE)
    connection.execute("INSERT INTO #{quoted_table} (email) VALUES ('before-migration@example.com')")
    migration = TemporaryTableMigration.new

    migration.migrate(:up)

    assert_equal 'active', connection.select_value("SELECT status FROM #{quoted_table} LIMIT 1")
    assert_nil connection.select_value("SELECT identity_issuer FROM #{quoted_table} LIMIT 1")
    assert_nil connection.select_value("SELECT identity_subject FROM #{quoted_table} LIMIT 1")
    status_column = connection.columns(MIGRATION_TEST_TABLE).find { |column| column.name == 'status' }
    assert_not status_column.null
    assert_equal 'active', status_column.default

    migration.migrate(:down)

    remaining_columns = connection.columns(MIGRATION_TEST_TABLE).map(&:name)
    refute_includes remaining_columns, 'identity_issuer'
    refute_includes remaining_columns, 'identity_subject'
    refute_includes remaining_columns, 'status'
  ensure
    connection&.drop_table(MIGRATION_TEST_TABLE, if_exists: true)
  end

  private

  def build_user(attributes = {})
    User.new(
      {
        name: 'Identity test user',
        email: "identity-#{SecureRandom.hex(8)}@example.com",
        password: PASSWORD,
        password_confirmation: PASSWORD
      }.merge(attributes)
    )
  end

  def create_user!(attributes = {})
    build_user(attributes).tap(&:save!)
  end

  def assert_check_constraint_expression(expression)
    normalized = expression.gsub(/\s+/, ' ')
    assert_includes normalized, 'identity_issuer IS NULL'
    assert_includes normalized, 'identity_subject IS NULL'
    assert_includes normalized, 'identity_issuer IS NOT NULL'
    assert_includes normalized, 'identity_subject IS NOT NULL'
    assert_match(/identity_issuer.*~.*\[\^\[:space:\]\]/, normalized)
    assert_match(/identity_subject.*~.*\[\^\[:space:\]\]/, normalized)
  end

  def assert_status_constraint_expression(expression)
    normalized = expression.delete('()').gsub(/\s+/, ' ').strip
    assert_match(/\bstatus\b/, normalized)
    assert_equal 1, normalized.scan(/'active'/).size
    assert_equal 1, normalized.scan(/'suspended'/).size
  end

  def normalized_predicate_terms(predicate)
    predicate.delete('()').split(/\s+AND\s+/).map { |term| term.gsub(/\s+/, ' ').strip }.sort
  end
end
