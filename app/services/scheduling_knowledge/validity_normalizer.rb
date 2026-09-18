# frozen_string_literal: true

require 'date'
require 'time'
require 'tzinfo'

module SchedulingKnowledge
  class ValidityNormalizer
    FIELDS = %i[issued_at valid_from valid_until verified_at verified_until].freeze
    END_FIELDS = %i[valid_until verified_until].freeze
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/

    def self.call(source_timezone:, **values)
      new(source_timezone).call(values)
    end

    def initialize(timezone)
      raise ArgumentError, 'a server IANA timezone is required' unless timezone.is_a?(String) && TZInfo::Timezone.all_identifiers.include?(timezone)

      @timezone = TZInfo::Timezone.get(timezone)
    end

    def call(values)
      raise ArgumentError, 'unknown temporal field' unless (values.keys - FIELDS).empty?

      normalized = FIELDS.to_h { |field| [field, normalize(field, values[field])] }
      effective_end = [normalized[:valid_until], normalized[:verified_until]].compact.min
      if normalized[:valid_from] && effective_end && normalized[:valid_from] >= effective_end
        raise ArgumentError, 'validity interval must be nonempty'
      end
      if normalized[:verified_at] && normalized[:verified_until] && normalized[:verified_at] >= normalized[:verified_until]
        raise ArgumentError, 'verification interval must be nonempty'
      end

      normalized.merge(source_timezone: @timezone.identifier,
                       source_temporal_json: FIELDS.to_h { |field| [field.to_s, values[field]] })
    end

    private

    def normalize(field, value)
      return nil if value.nil?
      raise ArgumentError, 'temporal values must be ISO dates or offset timestamps' unless value.is_a?(String)

      if DATE.match?(value)
        day = Date.iso8601(value)
        day += 1 if END_FIELDS.include?(field)
        @timezone.local_to_utc(Time.utc(day.year, day.month, day.day)).utc
      elsif TIMESTAMP.match?(value)
        Date.iso8601(value[0, 10]) # Time.iso8601 alone can normalize an invalid calendar date.
        Time.iso8601(value).utc
      else
        raise ArgumentError, 'temporal values must be ISO dates or offset timestamps'
      end
    rescue Date::Error, TZInfo::PeriodNotFound, TZInfo::AmbiguousTime
      raise ArgumentError, 'invalid or ambiguous temporal boundary'
    end
  end
end
