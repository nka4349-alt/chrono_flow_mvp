# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class UserIdentityTest < ActiveSupport::TestCase
  PASSWORD = 'Password-123!'
  CHECK_CONSTRAINT = 'users_identity_pair_complete_and_nonblank'
  UNIQUE_INDEX = 'index_users_on_identity_issuer_and_subject_unique'

  test 'user without identity attributes is valid' do
    assert_predicate build_user, :valid?
  end

  test 'user with both identity values nil is valid' do
    assert_predicate build_user(identity_issuer: nil, identity_subject: nil), :valid?
  end

  test 'user with a complete nonblank identity pair is valid' do
    user = build_user(identity_issuer: 'issuer-a', identity_subject: 'subject-a')

    assert_predicate user, :valid?
  end

  test 'identity issuer nil with a subject is invalid' do
    assert_identity_invalid(
      { identity_issuer: nil, identity_subject: 'subject-a' },
      field: :identity_issuer
    )
  end

  test 'identity subject nil with an issuer is invalid' do
    assert_identity_invalid(
      { identity_issuer: 'issuer-a', identity_subject: nil },
      field: :identity_subject
    )
  end

  test 'empty identity issuer is invalid' do
    assert_identity_invalid(
      { identity_issuer: '', identity_subject: 'subject-a' },
      field: :identity_issuer
    )
  end

  test 'empty identity subject is invalid' do
    assert_identity_invalid(
      { identity_issuer: 'issuer-a', identity_subject: '' },
      field: :identity_subject
    )
  end

  test 'space-only identity issuer is invalid' do
    assert_identity_invalid(
      { identity_issuer: '   ', identity_subject: 'subject-a' },
      field: :identity_issuer
    )
  end

  test 'space-only identity subject is invalid' do
    assert_identity_invalid(
      { identity_issuer: 'issuer-a', identity_subject: '   ' },
      field: :identity_subject
    )
  end

  test 'tab-only identity values are invalid' do
    assert_each_identity_component_invalid("\t")
  end

  test 'newline-only identity values are invalid' do
    assert_each_identity_component_invalid("\n")
  end

  test 'mixed whitespace-only identity values are invalid' do
    assert_each_identity_component_invalid(" \t\n")
  end

  test 'opaque identity values containing non-whitespace characters are valid' do
    user = build_user(
      identity_issuer: " \thttps://Issuer.EXAMPLE/OIDC/ \n",
      identity_subject: "\n Opaque-Subject-A \t"
    )

    assert_predicate user, :valid?
  end

  test 'leading and trailing identity whitespace is preserved after reload' do
    issuer = '  https://Issuer.EXAMPLE/OIDC  '
    subject = "\tOpaque-Subject-A\n"
    user = create_user!(identity_issuer: issuer, identity_subject: subject)

    user.reload

    assert_equal issuer, user.identity_issuer
    assert_equal subject, user.identity_subject
  end

  test 'identity letter case is preserved after reload' do
    issuer = 'HTTPS://Issuer.Example/OIDC'
    subject = 'Opaque-Subject-AbC'
    user = create_user!(identity_issuer: issuer, identity_subject: subject)

    user.reload

    assert_equal issuer, user.identity_issuer
    assert_equal subject, user.identity_subject
  end

  test 'duplicate complete identity pair is rejected by the model' do
    issuer = 'issuer-duplicate'
    subject = 'subject-duplicate'
    create_user!(identity_issuer: issuer, identity_subject: subject)
    duplicate = build_user(identity_issuer: issuer, identity_subject: subject)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:identity_subject], 'has already been taken'
  end

  test 'same subject with a different issuer is allowed' do
    create_user!(identity_issuer: 'issuer-a', identity_subject: 'shared-subject')
    second = build_user(identity_issuer: 'issuer-b', identity_subject: 'shared-subject')

    assert_predicate second, :valid?
  end

  test 'same issuer with a different subject is allowed' do
    create_user!(identity_issuer: 'shared-issuer', identity_subject: 'subject-a')
    second = build_user(identity_issuer: 'shared-issuer', identity_subject: 'subject-b')

    assert_predicate second, :valid?
  end

  test 'multiple users with a null identity pair are allowed' do
    first = create_user!(identity_issuer: nil, identity_subject: nil)
    second = create_user!(identity_issuer: nil, identity_subject: nil)

    assert_nil first.reload.identity_issuer
    assert_nil first.identity_subject
    assert_nil second.reload.identity_issuer
    assert_nil second.identity_subject
  end

  test 'case-distinct identity pairs are treated as different opaque pairs' do
    create_user!(identity_issuer: 'Issuer-A', identity_subject: 'Subject-A')
    second = create_user!(identity_issuer: 'issuer-a', identity_subject: 'subject-a')

    assert_equal 'issuer-a', second.reload.identity_issuer
    assert_equal 'subject-a', second.identity_subject
  end

  test 'database check constraint rejects invalid pairs when model validation is bypassed' do
    invalid_pairs = [
      { identity_issuer: nil, identity_subject: 'subject-a' },
      { identity_issuer: 'issuer-a', identity_subject: nil },
      { identity_issuer: " \t\n", identity_subject: 'subject-a' },
      { identity_issuer: 'issuer-a', identity_subject: " \t\n" }
    ]

    invalid_pairs.each do |identity_attributes|
      user = create_user!

      assert_raises(ActiveRecord::StatementInvalid) do
        User.transaction(requires_new: true) do
          user.update_columns(identity_attributes)
        end
      end

      user.reload
      assert_nil user.identity_issuer
      assert_nil user.identity_subject
    end
  end

  test 'database partial unique index rejects a duplicate pair when model validation is bypassed' do
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
  end

  test 'database identity metadata is nullable defaultless constrained and partially unique' do
    issuer_column = User.columns_hash.fetch('identity_issuer')
    subject_column = User.columns_hash.fetch('identity_subject')

    assert_equal :string, issuer_column.type
    assert_predicate issuer_column, :null
    assert_nil issuer_column.default
    assert_equal :string, subject_column.type
    assert_predicate subject_column, :null
    assert_nil subject_column.default

    constraint = User.connection.check_constraints(:users).find { |item| item.name == CHECK_CONSTRAINT }
    assert_not_nil constraint
    assert_check_constraint_expression(constraint.expression)

    index = User.connection.indexes(:users).find { |item| item.name == UNIQUE_INDEX }
    assert_not_nil index
    assert_predicate index, :unique
    assert_equal %w[identity_issuer identity_subject], index.columns
    assert_equal(
      ['identity_issuer IS NOT NULL', 'identity_subject IS NOT NULL'],
      normalized_predicate_terms(index.where)
    )
  end

  private

  def build_user(identity_attributes = {})
    User.new(
      {
        name: 'Identity test user',
        email: "identity-#{SecureRandom.hex(8)}@example.com",
        password: PASSWORD,
        password_confirmation: PASSWORD
      }.merge(identity_attributes)
    )
  end

  def create_user!(identity_attributes = {})
    build_user(identity_attributes).tap(&:save!)
  end

  def assert_identity_invalid(identity_attributes, field:)
    user = build_user(identity_attributes)

    assert_not user.valid?
    assert_predicate user.errors[field], :any?
  end

  def assert_each_identity_component_invalid(whitespace)
    assert_identity_invalid(
      { identity_issuer: whitespace, identity_subject: 'subject-a' },
      field: :identity_issuer
    )
    assert_identity_invalid(
      { identity_issuer: 'issuer-a', identity_subject: whitespace },
      field: :identity_subject
    )
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

  def normalized_predicate_terms(predicate)
    predicate.delete('()').split(/\s+AND\s+/).map { |term| term.gsub(/\s+/, ' ').strip }.sort
  end
end
