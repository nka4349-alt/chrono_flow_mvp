# frozen_string_literal: true

require 'digest'

module SecretaryMutation
  module AdvisoryLock
    module_function

    def acquire_session!(user_id:, home_subject:)
      acquire!(key("session\0#{user_id}\0#{home_subject}"))
    end

    def acquire_target!(event_id:)
      acquire!(key("event\0#{event_id}"))
    end

    def acquire_proposal!(public_id:)
      acquire!(key("proposal\0#{public_id}"))
    end

    def try_target(event_id:)
      try_acquire(key("event\0#{event_id}"))
    end

    def try_proposal(public_id:)
      try_acquire(key("proposal\0#{public_id}"))
    end

    def acquire!(value)
      sql = ActiveRecord::Base.send(:sanitize_sql_array, ['SELECT pg_advisory_xact_lock(?)', value])
      ActiveRecord::Base.connection.execute(sql)
      true
    end

    def try_acquire(value)
      sql = ActiveRecord::Base.send(:sanitize_sql_array, ['SELECT pg_try_advisory_xact_lock(?)', value])
      ActiveModel::Type::Boolean.new.cast(ActiveRecord::Base.connection.select_value(sql))
    end

    def key(value)
      Digest::SHA256.digest("secretary-mutation-flow-lock-v1\0#{value}").byteslice(0, 8).unpack1('q>')
    end
    private_class_method :key
  end
end
