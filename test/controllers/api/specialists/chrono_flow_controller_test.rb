# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class ApiSpecialistsChronoFlowControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  ENDPOINT = '/api/specialists/chrono_flow/context'
  PASSWORD = 'Password-123!'
  READONLY_TABLES = %w[
    events
    event_participants
    event_groups
    event_access_grants
    group_access_grants
    ai_conversations
    ai_messages
    ai_recommendations
    ai_recommendation_feedbacks
    ai_recommendation_impressions
    ai_policy_runs
    ai_tool_invocations
    ai_context_access_logs
    ai_usage_events
  ].freeze

  setup do
    @tokyo = Time.find_zone!('Asia/Tokyo')
    travel_to @tokyo.local(2026, 5, 18, 12, 0, 0)

    @user = create_user('chrono-flow-user')
    @other = create_user('chrono-flow-other')
  end

  teardown do
    travel_back
  end

  test 'valid v2.1 request returns today and tomorrow schedule facts and keeps IDs' do
    login_as(@user)
    today = create_event!(
      title: '今日の会議',
      start_at: @tokyo.local(2026, 5, 18, 10, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 11, 0, 0),
      created_by: @other,
      participant_users: [@user],
      location: '東京'
    )
    tomorrow = create_event!(
      title: '明日の終日予定',
      start_at: @tokyo.local(2026, 5, 19, 0, 0, 0),
      end_at: @tokyo.local(2026, 5, 20, 0, 0, 0),
      created_by: @user,
      all_day: true,
      location: '大阪'
    )
    duplicate_candidate = create_event!(
      title: '本人作成かつ参加',
      start_at: @tokyo.local(2026, 5, 19, 13, 0, 0),
      end_at: @tokyo.local(2026, 5, 19, 14, 0, 0),
      created_by: @user,
      participant_users: [@user, @other]
    )

    post ENDPOINT, params: valid_payload, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal '2.1', body.fetch('version')
    assert_match(/\Achrono_flow_response_[0-9a-f-]{36}\z/, body.fetch('response_id'))
    assert_equal 'request-d001', body.fetch('request_id')
    assert_equal 'call-d001', body.fetch('call_id')
    assert_equal 'trace-d001', body.fetch('trace_id')
    assert_equal 'chrono_flow_ai', body.fetch('specialist')
    assert_equal 'completed', body.fetch('status')
    assert_equal '今日・明日の予定を3件取得しました。', body.fetch('summary')
    assert_equal [], body.fetch('proposals')
    assert_nil body.fetch('clarification')
    assert_equal [], body.fetch('warnings')
    assert_equal 1.0, body.fetch('confidence')
    assert_equal '2026-05-18T12:00:00+09:00', body.fetch('generated_at')
    assert_equal '2026-05-18T12:10:00+09:00', body.fetch('stale_at')

    fact_ids = body.fetch('facts').map { |fact| fact.fetch('id') }
    assert_equal [
      "chrono_flow_event_#{today.id}",
      "chrono_flow_event_#{tomorrow.id}",
      "chrono_flow_event_#{duplicate_candidate.id}"
    ], fact_ids
    assert_equal fact_ids.uniq, fact_ids

    today_fact = body.fetch('facts').first
    assert_equal 'schedule_snapshot', today_fact.fetch('fact_type')
    assert_equal '今日の会議', today_fact.fetch('fields').fetch('title')
    assert_equal '2026-05-18T10:00:00+09:00', today_fact.fetch('fields').fetch('start_at')
    assert_equal '2026-05-18T11:00:00+09:00', today_fact.fetch('fields').fetch('end_at')
    assert_equal false, today_fact.fetch('fields').fetch('all_day')
    assert_equal '東京', today_fact.fetch('fields').fetch('location')
    assert_equal '2026-05-18T12:00:00+09:00', today_fact.fetch('source_updated_at')

    tomorrow_fact = body.fetch('facts').second
    assert_equal true, tomorrow_fact.fetch('fields').fetch('all_day')
    assert_equal '大阪', tomorrow_fact.fetch('fields').fetch('location')
  end

  test 'excludes future ended unrelated and non participant group events' do
    login_as(@user)
    included = create_event!(
      title: '本人個人予定',
      start_at: @tokyo.local(2026, 5, 18, 9, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 10, 0, 0),
      created_by: @user
    )
    create_event!(
      title: '明後日以降',
      start_at: @tokyo.local(2026, 5, 20, 9, 0, 0),
      end_at: @tokyo.local(2026, 5, 20, 10, 0, 0),
      created_by: @user
    )
    create_event!(
      title: '終了済み',
      start_at: @tokyo.local(2026, 5, 17, 9, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 0, 0, 0),
      created_by: @user
    )
    create_event!(
      title: '他ユーザー予定',
      start_at: @tokyo.local(2026, 5, 18, 11, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 12, 0, 0),
      created_by: @other
    )
    group = Group.create!(name: '非参加グループ', owner_id: @user.id)
    create_event!(
      title: '本人作成グループ予定',
      start_at: @tokyo.local(2026, 5, 18, 13, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 14, 0, 0),
      created_by: @user,
      group: group
    )

    post ENDPOINT, params: valid_payload, as: :json

    assert_response :success
    facts = JSON.parse(response.body).fetch('facts')
    assert_equal ["chrono_flow_event_#{included.id}"], facts.map { |fact| fact.fetch('id') }
  end

  test 'returns events crossing the requested two day range' do
    login_as(@user)
    crossing = create_event!(
      title: '日跨ぎ予定',
      start_at: @tokyo.local(2026, 5, 17, 23, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 1, 0, 0),
      created_by: @user
    )

    post ENDPOINT, params: valid_payload, as: :json

    assert_response :success
    facts = JSON.parse(response.body).fetch('facts')
    assert_equal ["chrono_flow_event_#{crossing.id}"], facts.map { |fact| fact.fetch('id') }
  end
  test 'uses second calendar midnight in request time zone for range end' do
    login_as(@user)
    new_york = Time.find_zone!('America/New_York')
    travel_to new_york.local(2026, 3, 8, 12, 0, 0)

    included = create_event!(
      title: 'DST in-range event',
      start_at: new_york.local(2026, 3, 9, 23, 0, 0),
      end_at: new_york.local(2026, 3, 9, 23, 30, 0),
      created_by: @user
    )
    create_event!(
      title: 'calendar boundary event',
      start_at: new_york.local(2026, 3, 10, 0, 0, 0),
      end_at: new_york.local(2026, 3, 10, 0, 30, 0),
      created_by: @user
    )

    post ENDPOINT, params: valid_payload(time_zone: 'America/New_York'), as: :json

    assert_response :success
    facts = JSON.parse(response.body).fetch('facts')
    assert_equal ["chrono_flow_event_#{included.id}"], facts.map { |fact| fact.fetch('id') }
  end

  test 'uses request time zone for range and timestamp serialization' do
    login_as(@user)
    event = create_event!(
      title: '時差予定',
      start_at: @tokyo.local(2026, 5, 18, 10, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 11, 30, 0),
      created_by: @user,
      location: 'ニューヨーク',
      all_day: false
    )

    post ENDPOINT, params: valid_payload(time_zone: 'America/New_York'), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    fact = body.fetch('facts').first
    assert_equal "chrono_flow_event_#{event.id}", fact.fetch('id')
    assert_equal '2026-05-17T21:00:00-04:00', fact.fetch('fields').fetch('start_at')
    assert_equal '2026-05-17T22:30:00-04:00', fact.fetch('fields').fetch('end_at')
    assert_equal 'ニューヨーク', fact.fetch('fields').fetch('location')
    assert_equal false, fact.fetch('fields').fetch('all_day')
    assert_equal '2026-05-17T23:00:00-04:00', body.fetch('generated_at')
    assert_equal '2026-05-17T23:10:00-04:00', body.fetch('stale_at')
  end

  test 'returns completed empty response when no events exist' do
    login_as(@user)

    post ENDPOINT, params: valid_payload, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'completed', body.fetch('status')
    assert_equal [], body.fetch('facts')
    assert_equal '今日・明日の予定はありません。', body.fetch('summary')
    assert_equal [], body.fetch('proposals')
    assert_nil body.fetch('clarification')
  end
  test 'rejects invalid mode capability and time zone' do
    login_as(@user)

    post ENDPOINT, params: valid_payload(version: '2.0'), as: :json
    assert_response :unprocessable_entity
    assert_equal 'version', JSON.parse(response.body).fetch('field')

    post ENDPOINT, params: valid_payload(specialist: 'other_ai'), as: :json
    assert_response :unprocessable_entity
    assert_equal 'specialist', JSON.parse(response.body).fetch('field')

    post ENDPOINT, params: valid_payload(mode: 'write'), as: :json
    assert_response :unprocessable_entity
    assert_equal 'mode', JSON.parse(response.body).fetch('field')

    post ENDPOINT, params: valid_payload(capability: 'event_write'), as: :json
    assert_response :unprocessable_entity
    assert_equal 'capability', JSON.parse(response.body).fetch('field')

    post ENDPOINT, params: valid_payload(time_zone: 'Mars/Olympus'), as: :json
    assert_response :unprocessable_entity
    assert_equal 'time_zone', JSON.parse(response.body).fetch('field')
  end


  test 'rejects blank request call and trace IDs' do
    login_as(@user)

    post ENDPOINT, params: valid_payload(request_id: ''), as: :json
    assert_response :unprocessable_entity
    assert_equal 'request_id', JSON.parse(response.body).fetch('field')

    post ENDPOINT, params: valid_payload(call_id: nil), as: :json
    assert_response :unprocessable_entity
    assert_equal 'call_id', JSON.parse(response.body).fetch('field')

    post ENDPOINT, params: valid_payload(trace_id: ' '), as: :json
    assert_response :unprocessable_entity
    assert_equal 'trace_id', JSON.parse(response.body).fetch('field')
  end

  test 'rejects unauthenticated request' do
    post ENDPOINT, params: valid_payload, as: :json

    assert_response :unauthorized
    assert_equal 'unauthorized', JSON.parse(response.body).fetch('error')
  end

  test 'ignores body user_id and uses authenticated current user' do
    login_as(@user)
    mine = create_event!(
      title: '本人予定',
      start_at: @tokyo.local(2026, 5, 18, 8, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 9, 0, 0),
      created_by: @user
    )
    create_event!(
      title: '別ユーザー予定',
      start_at: @tokyo.local(2026, 5, 18, 8, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 9, 0, 0),
      created_by: @other
    )

    post ENDPOINT, params: valid_payload(user_id: @other.id), as: :json

    assert_response :success
    facts = JSON.parse(response.body).fetch('facts')
    assert_equal ["chrono_flow_event_#{mine.id}"], facts.map { |fact| fact.fetch('id') }
  end

  test 'does not change event AI or audit table counts' do
    login_as(@user)
    create_event!(
      title: '読み取り対象',
      start_at: @tokyo.local(2026, 5, 18, 15, 0, 0),
      end_at: @tokyo.local(2026, 5, 18, 16, 0, 0),
      created_by: @user
    )
    before_counts = readonly_table_counts

    post ENDPOINT, params: valid_payload, as: :json

    assert_response :success
    assert_equal before_counts, readonly_table_counts
  end

  private

  def create_user(prefix)
    User.create!(
      name: prefix,
      email: "#{prefix}-#{SecureRandom.hex(6)}@example.com",
      password: PASSWORD,
      password_confirmation: PASSWORD
    )
  end

  def login_as(user)
    post login_path, params: { email: user.email, password: PASSWORD }
    assert_response :redirect
  end

  def valid_payload(overrides = {})
    {
      version: '2.1',
      request_id: 'request-d001',
      call_id: 'call-d001',
      trace_id: 'trace-d001',
      specialist: 'chrono_flow_ai',
      mode: 'read',
      capability: 'schedule_context',
      time_zone: 'Asia/Tokyo'
    }.merge(overrides)
  end

  def create_event!(title:, start_at:, end_at:, created_by:, participant_users: [], all_day: false, location: nil, group: nil)
    event = Event.create!(
      title: title,
      start_at: start_at,
      end_at: end_at,
      all_day: all_day,
      created_by: created_by,
      location: location
    )

    Array(participant_users).each do |participant|
      EventParticipant.create!(event: event, user: participant)
    end

    EventGroup.create!(event: event, group: group) if group
    event
  end

  def readonly_table_counts
    READONLY_TABLES.each_with_object({}) do |table, counts|
      next unless ActiveRecord::Base.connection.data_source_exists?(table)

      counts[table] = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
    end
  end
end
