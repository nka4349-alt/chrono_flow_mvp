# frozen_string_literal: true

require 'securerandom'

module Specialists
  module ChronoFlow
    class ReadScheduleContext
      VERSION = '2.1'
      SPECIALIST = 'chrono_flow_ai'
      MODE = 'read'
      CAPABILITY = 'schedule_context'
      EMPTY_SUMMARY = '今日・明日の予定はありません。'

      class ValidationError < StandardError
        attr_reader :field

        def initialize(message, field:)
          @field = field
          super(message)
        end
      end

      def self.call(...)
        new(...).call
      end

      def initialize(user:, payload:, now: Time.current)
        @user = user
        @payload = normalize_payload(payload)
        @now = now
      end

      def call
        validate!

        facts = events.map { |event| fact_for(event) }
        generated_at = timestamp(@now)

        {
          version: VERSION,
          response_id: "chrono_flow_response_#{SecureRandom.uuid}",
          request_id: payload.fetch('request_id'),
          call_id: payload.fetch('call_id'),
          trace_id: payload.fetch('trace_id'),
          specialist: SPECIALIST,
          status: 'completed',
          summary: summary_for(facts.length),
          facts: facts,
          proposals: [],
          clarification: nil,
          warnings: [],
          confidence: 1.0,
          generated_at: generated_at,
          stale_at: timestamp(@now + 10.minutes)
        }
      end

      private

      attr_reader :user, :payload, :now, :zone

      def validate!
        validate_equal!('version', VERSION)
        validate_presence!('request_id')
        validate_presence!('call_id')
        validate_presence!('trace_id')
        validate_equal!('specialist', SPECIALIST)
        validate_equal!('mode', MODE)
        validate_equal!('capability', CAPABILITY)

        @zone = Time.find_zone(payload['time_zone'].to_s)
        raise_validation!('time_zone', 'time_zone is invalid') unless @zone
      end

      def validate_presence!(field)
        raise_validation!(field, "#{field} is required") if payload[field].blank?
      end

      def validate_equal!(field, expected)
        actual = payload[field]
        raise_validation!(field, "#{field} is invalid") unless actual.to_s == expected
      end

      def raise_validation!(field, message)
        raise ValidationError.new(message, field: field)
      end

      def events
        @events ||= begin
          start_at, end_at = range
          home_events_scope
            .where('events.start_at < ? AND events.end_at > ?', end_at, start_at)
            .distinct
            .order(start_at: :asc, id: :asc)
            .readonly
            .to_a
        end
      end

      def range
        range_start = now.in_time_zone(zone).beginning_of_day
        range_end = (range_start.to_date + 2).in_time_zone(zone)

        [range_start, range_end]
      end

      def home_events_scope
        uid = user.id
        scope = Event.all

        if table_exists?('event_participants')
          scope = scope.left_outer_joins(:event_participants)

          if table_exists?('event_groups')
            scope.where(
              'event_participants.user_id = :uid OR (events.created_by_id = :uid AND NOT EXISTS (SELECT 1 FROM event_groups eg WHERE eg.event_id = events.id))',
              uid: uid
            )
          else
            scope.where('event_participants.user_id = :uid OR events.created_by_id = :uid', uid: uid)
          end
        else
          scope.where(created_by_id: uid)
        end
      end

      def fact_for(event)
        {
          id: "chrono_flow_event_#{event.id}",
          fact_type: 'schedule_snapshot',
          fields: {
            title: event.title,
            start_at: timestamp(event.start_at),
            end_at: timestamp(event.end_at),
            all_day: !!event.try(:all_day),
            location: event.respond_to?(:location) ? event.location : nil
          },
          source_updated_at: timestamp(event.updated_at)
        }
      end

      def summary_for(count)
        return EMPTY_SUMMARY if count.zero?

        "今日・明日の予定を#{count}件取得しました。"
      end

      def timestamp(value)
        value&.in_time_zone(zone)&.iso8601
      end

      def normalize_payload(value)
        hash = value.respond_to?(:to_h) ? value.to_h : {}
        hash.stringify_keys
      rescue StandardError
        {}
      end

      def table_exists?(name)
        ActiveRecord::Base.connection.data_source_exists?(name)
      rescue StandardError
        false
      end
    end
  end
end
