# frozen_string_literal: true

module ChronoFlowSpecialist
  class UserResolver
    def resolve(identity_issuer:, identity_subject:)
      users = User.where(identity_issuer: identity_issuer, identity_subject: identity_subject).limit(2).to_a
      user = users.one? ? users.first : nil
      raise Errors::Error.new(:inactive_user) unless user&.active_for_specialist?

      user
    end
  end
end
