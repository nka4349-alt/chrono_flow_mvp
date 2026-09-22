# frozen_string_literal: true

require 'test_helper'

class SecretaryCreationEventWriterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      name: 'Writer owner',
      email: "writer-#{SecureRandom.uuid}@example.test",
      password: 'Password-123!',
      identity_issuer: 'https://identity.example.test/',
      identity_subject: SecureRandom.uuid
    )
    @details = {
      'kind' => 'event',
      'title' => 'Canonical title',
      'description' => '',
      'location' => 'Room A',
      'start_at' => '2026-09-21T09:00:00+09:00',
      'end_at' => '2026-09-21T10:00:00+09:00',
      'all_day' => false,
      'time_zone' => 'Asia/Tokyo'
    }
  end

  test 'rejects noncanonical title and location before either domain row is written' do
    invalid_values = [
      ['title', "Meeting\nroom"],
      ['title', "  Meeting"],
      ['title', "\t\r\n"],
      ['location', "Room\tA"],
      ['location', "Room  A"]
    ]

    invalid_values.each do |field, value|
      assert_no_difference ['Event.count', 'EventParticipant.count'], "#{field}=#{value.inspect}" do
        assert_raises(SecretaryCreation::Contract::Invalid) do
          SecretaryCreation::EventWriter.call(user: @user, details: @details.merge(field => value))
        end
      end
    end
  end

  test 'rejects invalid UTF-8 before either domain row is written' do
    invalid_title = "bad\xFF".b.force_encoding(Encoding::UTF_8)

    assert_no_difference ['Event.count', 'EventParticipant.count'] do
      assert_raises(SecretaryCreation::Contract::Invalid) do
        SecretaryCreation::EventWriter.call(user: @user, details: @details.merge('title' => invalid_title))
      end
    end
  end
end
