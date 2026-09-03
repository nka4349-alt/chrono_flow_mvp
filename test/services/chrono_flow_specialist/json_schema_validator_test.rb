# frozen_string_literal: true

require "test_helper"

class ChronoFlowSpecialistJsonSchemaValidatorTest < ActiveSupport::TestCase
  test "validates required types and closed object keys" do
    schema = {
      "type" => "object",
      "required" => ["name"],
      "properties" => { "name" => { "type" => "string", "minLength" => 1 } },
      "additionalProperties" => false
    }
    validator = ChronoFlowSpecialist::JsonSchemaValidator.new(schema)

    assert validator.valid?({ "name" => "calendar" })
    assert_equal %w[required], validator.validate({}).map(&:keyword)
    assert_equal %w[additionalProperties], validator.validate({ "name" => "ok", "extra" => true }).map(&:keyword)
  end

  test "supports oneOf local refs arrays and date-time format" do
    schema = {
      "$defs" => { "timestamp" => { "type" => "string", "format" => "date-time" } },
      "type" => "object",
      "required" => %w[at choice values],
      "properties" => {
        "at" => { "$ref" => "#/$defs/timestamp" },
        "choice" => { "oneOf" => [{ "type" => "null" }, { "const" => "selected" }] },
        "values" => { "type" => "array", "items" => { "type" => "integer" }, "uniqueItems" => true }
      },
      "additionalProperties" => false
    }
    validator = ChronoFlowSpecialist::JsonSchemaValidator.new(schema)

    assert validator.valid?({ "at" => "2026-08-30T12:00:00+09:00", "choice" => nil, "values" => [1, 2] })
    refute validator.valid?({ "at" => "not-time", "choice" => true, "values" => [1, 1] })
  end
end
