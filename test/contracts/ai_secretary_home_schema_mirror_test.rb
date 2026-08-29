# frozen_string_literal: true

require 'test_helper'
require 'digest'
require 'json'

class AiSecretaryHomeSchemaMirrorTest < ActiveSupport::TestCase
  CANONICAL_REPOSITORY = 'nka4349-alt/ai_secretary_home'
  CANONICAL_COMMIT = '7bb14e30444b7b56a31bbf5d836cdd5bc5507045'
  DRAFT_2020_12_URI = 'https://json-schema.org/draft/2020-12/schema'
  MIRROR_DIRECTORY = Rails.root.join('contracts/ai_secretary_home/v2.1')
  CANONICAL_JSON_SHA256 = {
    'specialist_request.schema.json' => '3a71db36ed228b9104162801b2717515b63108094e6dc940be736304c259a130',
    'specialist_response.schema.json' => 'b38e02a915a433f4868dda8e12b0011db9ed54b54904fe18861bab75f47df517',
    'specialist_error.schema.json' => '3c06d7e096e4962df583c99cf46ff84f9aa382453a5c864824fb81780b870cce',
    'action_proposal.schema.json' => '95adfdc50524d2a28bc035b55f00b8372cec25b75efafd49f156e85de3e07acb'
  }.freeze

  test 'contains all four mirror schemas as parseable JSON objects' do
    CANONICAL_JSON_SHA256.each_key do |schema_name|
      path = MIRROR_DIRECTORY.join(schema_name)

      assert_predicate path, :file?, "Missing mirrored schema: #{schema_name}"
      assert_instance_of Hash, JSON.parse(path.binread), "Schema must be a JSON object: #{schema_name}"
    end
  end

  test 'declares the exact Draft 2020-12 schema URI' do
    each_schema do |schema_name, schema|
      assert_equal DRAFT_2020_12_URI, schema['$schema'], "Unexpected $schema in #{schema_name}"
    end
  end

  test 'matches canonical JSON digests without mirror-only fields' do
    each_schema do |schema_name, schema|
      actual_digest = Digest::SHA256.hexdigest(canonical_json(schema).encode(Encoding::UTF_8))
      source = "#{CANONICAL_REPOSITORY}@#{CANONICAL_COMMIT}"

      assert_equal CANONICAL_JSON_SHA256.fetch(schema_name), actual_digest,
                   "#{schema_name} differs from canonical source #{source}"
    end
  end

  private

  def each_schema
    CANONICAL_JSON_SHA256.each_key do |schema_name|
      yield schema_name, JSON.parse(MIRROR_DIRECTORY.join(schema_name).binread)
    end
  end

  def canonical_json(value)
    JSON.generate(sort_object_keys(value))
  end

  def sort_object_keys(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) do |key, sorted|
        sorted[key] = sort_object_keys(value.fetch(key))
      end
    when Array
      value.map { |item| sort_object_keys(item) }
    else
      value
    end
  end
end
