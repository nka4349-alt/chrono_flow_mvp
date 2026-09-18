# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientParticipantBoundaryTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-09-18T19:18:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  REPORTED_INPUTS = {
    'CF-05' => 'Please suggest a 20-minute break tomorrow at 14:00. 名前は「CF-05 テスト休憩」、説明は日本語でお願いします。候補だけを表示し、保存や通知はしないでください。',
    'CF-05R' => 'Please suggest a 20-minute break tomorrow at 14:00. 名前は「CF-05R テスト休憩」、説明は日本語でお願いします。候補の表示だけを希望します。'
  }.freeze

  CONTEXT_VARIANTS = {
    'no contacts' => {},
    'contact named k' => { contacts: [{ display_name: 'k' }] },
    'friend named k' => { friends: [{ 'name' => 'k' }] },
    'contact named a' => { contacts: [{ display_name: 'a' }] },
    'contact named at' => { contacts: [{ display_name: 'at' }] },
    '50 contacts including incidental Latin names' => {
      contacts: (%w[k a at] + (1..47).map { |number| format('SyntheticContact%02d', number) })
        .map { |name| { display_name: name } }
    }
  }.freeze

  def response_for(message, context: {})
    remote_called = false
    client = Ai::Client.new(context: BASE_CONTEXT.merge(context), user_message: message)
    client.define_singleton_method(:request_remote) do
      remote_called = true
      raise 'Unexpected remote request in participant-boundary regression'
    end

    response = nil
    assert_no_difference('Event.count', message) { response = client.call }
    refute remote_called, message
    assert_empty response.fetch(:tool_invocations), message
    response
  end

  def event_nodes(response)
    recommendation = response.fetch(:recommendations).sole
    payload = recommendation.fetch('payload')
    [recommendation, payload, *Array(payload['events'])]
  end

  def assert_standalone_candidate(response, title:, diagnostic: nil)
    assert_equal 1, response.fetch(:recommendations).length, diagnostic
    event_nodes(response).each do |node|
      assert_equal title, node.fetch('title'), diagnostic
      assert_equal Time.iso8601('2026-09-19T14:00:00+09:00'), Time.iso8601(node.fetch('start_at')), diagnostic
      assert_equal Time.iso8601('2026-09-19T14:20:00+09:00'), Time.iso8601(node.fetch('end_at')), diagnostic
      assert_equal false, node.fetch('all_day'), diagnostic
      assert node['contact_name'].blank?, "#{diagnostic}: unexpected contact_name=#{node['contact_name'].inspect}"
      assert_empty Array(node['participant_names']), diagnostic
      refute_includes Array(node['relation_tags']), 'contact', diagnostic
      refute_match(/相手\s*[:：]/, node['description'].to_s, diagnostic)
    end
    refute_match(/相手\s*[:：]/, response.fetch(:assistant_message), diagnostic)
  end

  REPORTED_INPUTS.each do |case_id, input|
    CONTEXT_VARIANTS.each do |context_label, context|
      test "#{case_id} remains a standalone break with #{context_label}" do
        response = response_for(input, context: context)

        assert_standalone_candidate(response, title: "#{case_id} テスト休憩", diagnostic: "#{case_id}: #{context_label}")
        assert_includes response.fetch(:assistant_message), "#{case_id} テスト休憩"
        refute_match(/\b(?:k|a|at)と|相手\s*[:：]\s*(?:k|a|at)/i, response.fetch(:assistant_message))
      end
    end
  end

  test 'a longer Latin contact is not inferred from a substring of an English activity' do
    message = 'Please suggest a 20-minute planning session tomorrow at 14:00. 名前は「企画確認」、説明は日本語でお願いします。候補の表示だけを希望します。'
    response = response_for(message, context: { contacts: [{ display_name: 'Ann' }] })

    assert_standalone_candidate(response, title: '企画確認', diagnostic: 'Ann within planning')
    refute_match(/annと|相手\s*[:：]\s*ann/i, response.fetch(:assistant_message))
  end

  ['K資料確認', 'Kと会議'].each do |literal_title|
    test "a contact appearing only in the explicit title #{literal_title} is not a participant" do
      response = response_for("明日14:00から20分の「#{literal_title}」の候補をください。", context: { contacts: [{ display_name: 'k' }] })

      assert_standalone_candidate(response, title: literal_title, diagnostic: literal_title)
    end
  end

  [
    ['contact', { contacts: [{ display_name: 'k' }] }],
    ['friend', { friends: [{ name: 'k' }] }]
  ].each do |label, context|
    test "an explicit K participant still matches the synthetic #{label}" do
      response = response_for('明日14時から20分、Kと会議', context: context)
      payload = response.fetch(:recommendations).sole.fetch('payload')

      assert_equal ['k'], Array(payload.fetch('participant_names')).map(&:downcase).uniq
      assert_equal 'k', payload.fetch('contact_name').downcase
      assert_includes payload.fetch('relation_tags'), 'contact'
      assert_match(/相手\s*[:：]\s*k/i, payload.fetch('description'))
      assert_equal Time.iso8601('2026-09-19T14:00:00+09:00'), Time.iso8601(payload.fetch('start_at'))
      assert_equal Time.iso8601('2026-09-19T14:20:00+09:00'), Time.iso8601(payload.fetch('end_at'))
    end
  end

  test 'an explicit longer Latin participant remains available' do
    response = response_for('明日14時から20分、Annと会議', context: { contacts: [{ display_name: 'Ann' }] })
    payload = response.fetch(:recommendations).sole.fetch('payload')

    assert_equal ['ann'], Array(payload.fetch('participant_names')).map(&:downcase).uniq
    assert_equal 'ann', payload.fetch('contact_name').downcase
    assert_includes payload.fetch('relation_tags'), 'contact'
    assert_match(/相手\s*[:：]\s*ann/i, payload.fetch('description'))
  end

  test 'an explicit English with clause preserves the requested participant' do
    message = 'Please suggest a 20-minute break with k tomorrow at 14:00. 名前は「休憩」、説明は日本語でお願いします。候補の表示だけを希望します。'
    response = response_for(message, context: { contacts: [{ display_name: 'k' }] })
    payload = response.fetch(:recommendations).sole.fetch('payload')

    assert_equal ['k'], Array(payload.fetch('participant_names')).map(&:downcase).uniq
    assert_equal 'k', payload.fetch('contact_name').downcase
    assert_includes payload.fetch('relation_tags'), 'contact'
    assert_match(/相手\s*[:：]\s*k/i, payload.fetch('description'))
    assert_equal Time.iso8601('2026-09-19T14:00:00+09:00'), Time.iso8601(payload.fetch('start_at'))
    assert_equal Time.iso8601('2026-09-19T14:20:00+09:00'), Time.iso8601(payload.fetch('end_at'))
  end

  test 'an explicit participant list preserves every named person without incidental contacts' do
    inputs = [
      'Please suggest a 20-minute break with Alice and Bob tomorrow at 14:00. 名前は「休憩」、説明は日本語でお願いします。候補の表示だけを希望します。',
      '明日14時から20分、Alice、Bobと会議'
    ]
    context = { contacts: %w[Alice Bob k a at].map { |name| { display_name: name } } }

    inputs.each do |input|
      response = response_for(input, context: context)
      payload = response.fetch(:recommendations).sole.fetch('payload')
      [payload, *Array(payload['events'])].each do |event|
        assert_equal %w[Alice Bob], event.fetch('participant_names'), input
        assert_equal 'Alice', event.fetch('contact_name'), input
        assert_equal Time.iso8601('2026-09-19T14:00:00+09:00'), Time.iso8601(event.fetch('start_at')), input
        assert_equal Time.iso8601('2026-09-19T14:20:00+09:00'), Time.iso8601(event.fetch('end_at')), input
      end
    end
  end

  test 'a quoted explicitly designated participant is kept separate from a quoted activity title' do
    response = response_for('明日14時から20分、相手は「Alice」で会議',
                            context: { contacts: [{ display_name: 'Alice' }] })
    payload = response.fetch(:recommendations).sole.fetch('payload')

    assert_equal ['Alice'], payload.fetch('participant_names')
    assert_equal 'Alice', payload.fetch('contact_name')
    assert_includes payload.fetch('description'), '相手: Alice'
  end

  test 'an explicit Japanese participant remains available with and without a saved contact' do
    [{}, { contacts: [{ display_name: '田中' }] }].each do |context|
      response = response_for('明日14時から20分、田中さんと会議', context: context)
      payload = response.fetch(:recommendations).sole.fetch('payload')

      assert_equal ['田中'], payload.fetch('participant_names')
      assert_equal '田中', payload.fetch('contact_name')
      assert_includes payload.fetch('relation_tags'), 'contact'
      assert_includes payload.fetch('description'), '相手: 田中'
      assert_equal Time.iso8601('2026-09-19T14:00:00+09:00'), Time.iso8601(payload.fetch('start_at'))
      assert_equal Time.iso8601('2026-09-19T14:20:00+09:00'), Time.iso8601(payload.fetch('end_at'))
    end
  end
end
