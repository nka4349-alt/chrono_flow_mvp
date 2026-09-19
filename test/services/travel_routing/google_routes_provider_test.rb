# frozen_string_literal: true

require "test_helper"

class TravelRoutingGoogleRoutesProviderTest < ActiveSupport::TestCase
  Provider = TravelRouting::GoogleRoutesProvider
  DEPARTURE = "2026-09-20T10:00:00+09:00"

  class FakeResponse < Net::HTTPOK
    attr_reader :chunks_read

    def initialize(chunks:, status: 200, headers: {})
      super("1.1", status.to_s, "status")
      self["Content-Type"] = "application/json"
      headers.each { |key, value| self[key] = value }
      @chunks = chunks
      @chunks_read = 0
    end

    def read_body
      @chunks.each do |chunk|
        @chunks_read += 1
        yield chunk
      end
    end
  end

  class FakeHttp
    attr_accessor :use_ssl, :verify_mode, :min_version, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :request_value, :request_count

    def initialize(response)
      @response = response
      @request_count = 0
    end

    def start
      yield self
    end

    def request(value)
      @request_value = value
      @request_count += 1
      yield @response
    end
  end

  test "serializes explicit addresses to one fixed HTTPS endpoint with key only in header" do
    captured = nil
    result = call_provider(transport: lambda { |**request|
      captured = request
      response_for(route)
    })

    assert result.success?
    assert_equal Provider::ENDPOINT, captured[:uri].to_s
    assert_nil captured[:uri].query
    assert_equal "private-test-key", captured[:headers]["X-Goog-Api-Key"]
    assert_equal Provider::FIELD_MASK, captured[:headers]["X-Goog-FieldMask"]
    assert_equal "identity", captured[:headers]["Accept-Encoding"]
    assert_equal({ "origin" => { "address" => "東京駅" }, "destination" => { "address" => "品川駅" },
      "travelMode" => "DRIVE", "computeAlternativeRoutes" => false,
      "languageCode" => "ja", "units" => "METRIC", "departureTime" => "2026-09-20T01:00:00Z",
      "routingPreference" => "TRAFFIC_AWARE" }, JSON.parse(captured[:body]))
    refute_includes captured[:body], "private-test-key"
    assert_equal 601, result.duration_seconds
    assert_equal 2500, result.distance_meters
    assert_equal 0, result.walking_seconds
    assert_equal "2026-09-20T01:10:00.100000000Z", result.arrival_time
    assert_equal "Google Maps", result.attribution
  end

  test "supports bounded place IDs and numeric canonical coordinates" do
    captured = nil
    result = call_provider(origin: { place_id: "ChIJ_test-place" },
      destination: { "latitude" => 35.6, "longitude" => 139.7 }, transport: lambda { |**request|
        captured = JSON.parse(request[:body])
        response_for(route)
      })

    assert result.success?
    assert_equal({ "placeId" => "ChIJ_test-place" }, captured["origin"])
    assert_equal({ "location" => { "latLng" => { "latitude" => 35.6, "longitude" => 139.7 } } }, captured["destination"])
  end

  test "success and failure results are immutable and failure has no zero-valued travel estimate" do
    success = call_provider
    failure = call_provider(api_key: nil)

    [success, failure].each do |result|
      assert result.frozen?
      assert result.code.frozen?
      assert_raises(FrozenError) { result.code = "changed" }
      assert_raises(FrozenError) { result.code << "changed" }
    end
    assert success.arrival_time.frozen?
    assert_nil failure.duration_seconds
    assert_nil failure.walking_seconds
    assert_nil failure.distance_meters
    assert_nil failure.departure_time
    assert_nil failure.arrival_time
    assert_nil failure.attribution
  end

  test "missing or malformed credentials make no transport attempt" do
    [nil, "", " ", "secret\r\ninjected", "a" * 257].each do |key|
      result = call_provider(api_key: key, transport: ->(**) { flunk "must not call external transport" })
      assert_equal "not_configured", result.code
    end
  end

  test "rejects arbitrary URLs empty addresses control characters and overlong input before HTTP" do
    [nil, "", " \t ", "https://example.test", "www.example.test", "a\naddress", "x" * 513, "東" * 342].each do |origin|
      result = call_provider(origin: origin, transport: ->(**) { flunk "invalid input must not send HTTP" })
      assert_equal "invalid_request", result.code, origin.inspect
    end
  end

  test "rejects ambiguous waypoint shapes and invalid coordinates before HTTP" do
    [{ address: "東京駅" }, { place_id: "a", "place_id" => "b" }, { place_id: "https://example.test" },
      { latitude: "35", longitude: 139 }, { latitude: 91, longitude: 139 },
      { latitude: 35, longitude: Float::INFINITY }, { latitude: Float::NAN, longitude: 0 },
      { latitude: 35, longitude: 139, url: "https://example.test" }, {}].each do |origin|
      result = call_provider(origin: origin, transport: ->(**) { flunk "invalid waypoint must not send HTTP" })
      assert_equal "invalid_request", result.code, origin.inspect
    end
  end

  test "rejects unsupported modes both time anchors and arrival for non transit" do
    ["BICYCLE", "walk", nil, :WALK].each do |mode|
      assert_equal "invalid_request", call_provider(mode: mode).code
    end
    assert_equal "invalid_request", call_provider(arrival_time: DEPARTURE).code
    %w[WALK DRIVE].each do |mode|
      result = call_provider(mode: mode, departure_time: nil, arrival_time: DEPARTURE,
        transport: ->(**) { flunk "unsupported arrival must not send HTTP" })
      assert_equal "unsupported_arrival_mode", result.code
    end
  end

  test "requires strict real dates and an explicit offset on string timestamps" do
    ["2026-09-20", "2026-09-20T10:00:00", "2026-02-30T10:00:00Z", "2026-09-20T24:00:00Z",
      "2026-09-20T10:60:00Z", "2026-09-20T10:00:60Z", "2026-09-20T10:00:00+25:00", 0].each do |value|
      result = call_provider(departure_time: value, transport: ->(**) { flunk "bad time must not send HTTP" })
      assert_equal "invalid_request", result.code, value.inspect
    end
    assert call_provider(departure_time: Time.iso8601(DEPARTURE)).success?
  end

  test "walking reports the full route duration rounded conservatively" do
    result = call_provider(mode: "WALK")

    assert result.success?
    assert_equal 601, result.walking_seconds
    assert_equal result.duration_seconds, result.walking_seconds
  end

  test "transit uses actual train times with approach and exit walking instead of requested departure" do
    result = call_provider(mode: "TRANSIT", transport: ->(**) { response_for(transit_route) })

    assert result.success?
    assert_equal 1800, result.duration_seconds
    assert_equal 900, result.walking_seconds
    assert_equal "2026-09-20T01:05:00Z", result.departure_time
    assert_equal "2026-09-20T01:35:00Z", result.arrival_time
  end

  test "transit arrival request preserves actual arrival earlier than deadline" do
    captured = nil
    result = call_provider(mode: "TRANSIT", departure_time: nil, arrival_time: "2026-09-20T10:40:00+09:00",
      transport: lambda { |**request|
        captured = JSON.parse(request[:body])
        response_for(transit_route)
      })

    assert result.success?
    assert_equal "2026-09-20T01:40:00Z", captured["arrivalTime"]
    refute captured.key?("departureTime")
    refute captured.key?("routingPreference")
    assert_equal "2026-09-20T01:05:00Z", result.departure_time
    assert_equal "2026-09-20T01:35:00Z", result.arrival_time
    refute captured.key?("transitPreferences")
  end

  test "rail and bus preferences serialize and verify every supported vehicle type" do
    Provider::TRANSIT_VEHICLES.each do |submode, vehicles|
      vehicles.each do |vehicle|
        captured = nil
        result = call_provider(mode: "TRANSIT", transit_mode: submode, transport: lambda { |**request|
          captured = JSON.parse(request[:body])
          response_for(transit_route_with_vehicle(vehicle))
        })

        assert result.success?, "#{submode}: #{vehicle}"
        assert_equal({ "allowedTravelModes" => [submode] }, captured["transitPreferences"])
      end
    end
    assert_includes Provider::FIELD_MASK, "routes.legs.steps.transitDetails.transitLine.vehicle.type"
  end

  test "specific transit submode rejects missing mismatched and unknown vehicles" do
    { "RAIL" => [nil, "BUS", "FERRY", "FUNICULAR", "OTHER", "NEW_UNKNOWN_TYPE"],
      "BUS" => [nil, "RAIL", "FERRY", "SHARE_TAXI", "OTHER", "NEW_UNKNOWN_TYPE"] }.each do |submode, vehicles|
      vehicles.each do |vehicle|
        result = call_provider(mode: "TRANSIT", transit_mode: submode,
          transport: ->(**) { response_for(transit_route_with_vehicle(vehicle)) })
        assert_equal "invalid_response", result.code, "#{submode}: #{vehicle}"
        assert_nil result.duration_seconds
      end
    end
    assert call_provider(mode: "TRANSIT", transport: ->(**) { response_for(transit_route_with_vehicle("BUS")) }).success?
  end

  test "rail submode cannot accept a later bus transfer or a walking-only route" do
    mixed = { "duration" => "2700s", "distanceMeters" => 8000, "legs" => [{ "steps" => [
      walk_step("300s"), transit_step("01:10:00", "01:25:00", vehicle: "SUBWAY"), walk_step("120s"),
      transit_step("01:30:00", "01:45:00", vehicle: "BUS"), walk_step("300s")
    ] }] }
    walking_only = { "duration" => "600s", "distanceMeters" => 800, "legs" => [{ "steps" => [walk_step("600s")] }] }
    [mixed, walking_only].each do |route|
      result = call_provider(mode: "TRANSIT", transit_mode: "RAIL", transport: ->(**) { response_for(route) })
      assert_equal "invalid_response", result.code
    end
  end

  test "specific transit submode must be a supported string and only applies to transit" do
    ["TRAIN", "SHINKANSEN", "", false, :RAIL, 1].each do |submode|
      result = call_provider(mode: "TRANSIT", transit_mode: submode,
        transport: ->(**) { flunk "invalid submode must not send HTTP" })
      assert_equal "invalid_request", result.code
    end
    %w[DRIVE WALK].each do |mode|
      result = call_provider(mode: mode, transit_mode: "RAIL",
        transport: ->(**) { flunk "invalid submode must not send HTTP" })
      assert_equal "invalid_request", result.code
    end
  end

  test "transit transfer walking and waiting are included in actual endpoint times" do
    value = { "duration" => "2700s", "distanceMeters" => 8000, "legs" => [{ "steps" => [
      walk_step("300s"), transit_step("01:10:00", "01:25:00"), walk_step("120s"),
      transit_step("01:30:00", "01:45:00"), walk_step("300s")
    ] }] }
    result = call_provider(mode: "TRANSIT", transport: ->(**) { response_for(value) })

    assert result.success?
    assert_equal 720, result.walking_seconds
    assert_equal "2026-09-20T01:05:00Z", result.departure_time
    assert_equal "2026-09-20T01:50:00Z", result.arrival_time
  end

  test "pure walking transit route derives times using selected time direction" do
    value = { "duration" => "600s", "distanceMeters" => 800,
      "legs" => [{ "steps" => [walk_step("300s"), walk_step("300s")] }] }
    transport = ->(**) { response_for(value) }
    departure_result = call_provider(mode: "TRANSIT", transport: transport)
    arrival_result = call_provider(mode: "TRANSIT", departure_time: nil,
      arrival_time: "2026-09-20T10:30:00+09:00", transport: transport)

    assert departure_result.success?
    assert_equal "2026-09-20T01:10:00Z", departure_result.arrival_time
    assert arrival_result.success?
    assert_equal "2026-09-20T01:20:00Z", arrival_result.departure_time
    assert_equal 600, arrival_result.walking_seconds
  end

  test "rejects transit that departs too early arrives too late or cannot make transfer" do
    early = call_provider(mode: "TRANSIT", departure_time: "2026-09-20T10:06:00+09:00",
      transport: ->(**) { response_for(transit_route) })
    late = call_provider(mode: "TRANSIT", departure_time: nil, arrival_time: "2026-09-20T10:34:00+09:00",
      transport: ->(**) { response_for(transit_route) })
    impossible = transit_route
    impossible["legs"][0]["steps"] += [transit_step("01:34:00", "01:40:00")]

    assert_equal "invalid_response", early.code
    assert_equal "invalid_response", late.code
    assert_equal "invalid_response", call_provider(mode: "TRANSIT", transport: ->(**) { response_for(impossible) }).code
  end

  test "rejects incomplete or inconsistent transit timing and walking metadata" do
    variants = [transit_route.merge("legs" => nil), transit_route.merge("legs" => []),
      transit_route.merge("duration" => "1200s")]
    [[], [{}], [walk_step(nil)], [transit_step("01:30:00", "01:25:00")],
      [transit_step("01:10:00", "01:25:00").merge("transitDetails" => {})],
      [{ "travelMode" => "DRIVE", "staticDuration" => "1800s" }],
      [walk_step("1800s"), walk_step("1s")], Array.new(513) { walk_step("1s") }].each do |steps|
      variants << transit_route.merge("legs" => [{ "steps" => steps }])
    end
    variants.each do |value|
      result = call_provider(mode: "TRANSIT", transport: ->(**) { response_for(value) })
      assert_equal "invalid_response", result.code
      assert_nil result.duration_seconds
    end
  end

  test "malformed impossible or zero duration never becomes a route estimate" do
    [nil, "", "0s", "0.0s", "-1s", "NaNs", "Infinitys", "1e3s", "604801s", "1000000s", "1.1234567890s", 100].each do |duration|
      result = call_provider(transport: ->(**) { response_for(route.merge("duration" => duration)) })
      assert_equal "invalid_response", result.code, duration.inspect
      assert_nil result.duration_seconds
    end
    assert_equal 1, call_provider(transport: ->(**) { response_for(route.merge("duration" => "0.000000001s")) }).duration_seconds
  end

  test "distance must be a bounded nonnegative integer" do
    [nil, "2500", -1, 1.2, 20_000_001].each do |distance|
      result = call_provider(transport: ->(**) { response_for(route.merge("distanceMeters" => distance)) })
      assert_equal "invalid_response", result.code
    end
  end

  test "empty route set safely reports no route" do
    [{}, { "routes" => [] }, { "geocodingResults" => { "origin" => { "geocoderStatus" => { "code" => 5 } } } }].each do |document|
      result = call_provider(transport: ->(**) { response_for_document(document) })
      assert_equal "no_route", result.code
      assert_nil result.duration_seconds
    end
  end

  test "address routes require geocoding evidence and reject partial matches and failed geocoding" do
    [nil, {}, { "origin" => exact_geocode }, exact_geocoding.merge("destination" => nil),
      exact_geocoding.merge("origin" => exact_geocode.merge("partialMatch" => true)),
      exact_geocoding.merge("origin" => exact_geocode.merge("partialMatch" => "false")),
      exact_geocoding.merge("destination" => exact_geocode.merge("geocoderStatus" => { "code" => 5 })),
      exact_geocoding.merge("destination" => exact_geocode.merge("geocoderStatus" => { "code" => 0.0 })),
      exact_geocoding.merge("destination" => exact_geocode.merge("geocoderStatus" => nil)),
      exact_geocoding.merge("destination" => exact_geocode.merge("placeId" => ""))].each do |geocoding|
      result = call_provider(transport: ->(**) { response_for_document("routes" => [route], "geocodingResults" => geocoding) })
      assert_equal "invalid_response", result.code
      assert_nil result.duration_seconds
    end
  end

  test "geocoding default scalars may be omitted and explicit waypoints need no geocoding" do
    default_scalars = { "origin" => { "placeId" => "ChIJ_origin" }, "destination" => { "placeId" => "ChIJ_destination", "geocoderStatus" => {} } }
    assert call_provider(transport: ->(**) { response_for_document("routes" => [route], "geocodingResults" => default_scalars) }).success?
    assert call_provider(origin: { place_id: "ChIJ_origin" }, destination: { latitude: 35, longitude: 139 },
      transport: ->(**) { response_for_document("routes" => [route]) }).success?
  end

  test "rejects provider routing fallback even when a usable duration was returned" do
    [{ "routingMode" => "FALLBACK_TRAFFIC_UNAWARE", "reason" => "SERVER_ERROR" }, {}, nil].each do |fallback|
      result = call_provider(transport: ->(**) { response_for_document("routes" => [route],
        "geocodingResults" => exact_geocoding, "fallbackInfo" => fallback) })
      assert_equal "invalid_response", result.code
      assert_nil result.duration_seconds
    end
  end

  test "rejects malformed JSON duplicate keys NaN excessive nesting and invalid route shape" do
    ["{", "null", "[]", '{"routes":[],"routes":[]}', '{"value":NaN}', "{\"routes\":[],\"value\":\"\xFF\"}".b,
      JSON.generate("routes" => [route, route]), JSON.generate("routes" => [nil]),
      JSON.generate("routes" => {}), JSON.generate("error" => { "message" => "secret" }),
      '[' * 21 + '0' + ']' * 21].each do |body|
      result = call_provider(transport: ->(**) { { status: 200, headers: json_headers, body: body } })
      assert_equal "invalid_response", result.code, body
      refute_includes result.inspect, "secret"
    end
  end

  test "rejects response body length and response encoding content type" do
    [{ "Content-Type" => "text/html" }, { "Content-Type" => "application/json", "Content-Encoding" => "gzip" },
      json_headers.merge("Content-Length" => "262145"), json_headers.merge("Content-Length" => "invalid")].each do |headers|
      result = call_provider(transport: ->(**) { { status: 200, headers: headers, body: JSON.generate("routes" => [route]) } })
      assert_equal "invalid_response", result.code
    end
    result = call_provider(transport: ->(**) { { status: 200, headers: json_headers, body: " " * 262_145 } })
    assert_equal "invalid_response", result.code
  end

  test "provider errors rate limits redirects and network failures return no raw content" do
    [301, 400, 401, 403, 429, 500, 503].each do |status|
      result = call_provider(transport: ->(**) { { status: status, headers: json_headers, body: "private-test-key 東京駅" } })
      assert_equal "unavailable", result.code
      refute_includes result.inspect, "private-test-key"
      refute_includes result.inspect, "東京駅"
    end
    [Timeout::Error, IOError, SocketError, OpenSSL::SSL::SSLError].each do |error|
      result = call_provider(transport: ->(**) { raise error, "private-test-key 東京駅" })
      assert_equal "unavailable", result.code
      refute_includes result.inspect, "private-test-key"
    end
  end

  test "default transport verifies TLS disables retries and proxies and streams one bounded POST" do
    body = JSON.generate("routes" => [route], "geocodingResults" => exact_geocoding)
    response = FakeResponse.new(chunks: [body.byteslice(0, 12), body.byteslice(12..)])
    http = FakeHttp.new(response)
    arguments = nil
    result = replace_http_new(->(*args) { arguments = args; http }) do
      Provider.new(api_key: "private-test-key").call(origin: "東京駅", destination: "品川駅", mode: "DRIVE", departure_time: DEPARTURE)
    end

    assert result.success?
    assert_equal ["routes.googleapis.com", 443, nil], arguments
    assert_equal true, http.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal OpenSSL::SSL::TLS1_2_VERSION, http.min_version
    assert_equal 0, http.max_retries
    assert_equal 2, http.open_timeout
    assert_equal 3, http.read_timeout
    assert_equal 3, http.write_timeout
    assert_equal 10, Provider::OVERALL_TIMEOUT_SECONDS
    assert_equal 1, http.request_count
    assert_equal "POST", http.request_value.method
    assert_equal "/directions/v2:computeRoutes", http.request_value.path
    assert_equal "private-test-key", http.request_value["X-Goog-Api-Key"]
    assert_equal 2, response.chunks_read
  end

  test "default transport aborts streaming at body bound and never follows redirect" do
    oversized = FakeResponse.new(chunks: ["a" * 262_144, "b", "unread"])
    redirect = FakeResponse.new(chunks: ["unread"], status: 302, headers: { "Location" => "https://example.test" })
    [oversized, redirect].each do |response|
      http = FakeHttp.new(response)
      result = replace_http_new(->(*) { http }) do
        Provider.new(api_key: "private-test-key").call(origin: "東京駅", destination: "品川駅", mode: "WALK", departure_time: DEPARTURE)
      end
      assert_equal response == oversized ? "invalid_response" : "unavailable", result.code
      assert_equal 1, http.request_count
    end
    assert_equal 2, oversized.chunks_read
    assert_equal 0, redirect.chunks_read
  end

  private

  def call_provider(api_key: "private-test-key", transport: nil, **arguments)
    Provider.new(api_key: api_key, transport: transport || ->(**) { response_for(route) }).call(
      **{ origin: "東京駅", destination: "品川駅", mode: "DRIVE", departure_time: DEPARTURE }.merge(arguments))
  end

  def route
    { "duration" => "600.1s", "distanceMeters" => 2500 }
  end

  def transit_route
    { "duration" => "1800s", "distanceMeters" => 6000,
      "legs" => [{ "steps" => [walk_step("300s"), transit_step("01:10:00", "01:25:00"), walk_step("600s")] }] }
  end

  def walk_step(duration)
    { "travelMode" => "WALK", "staticDuration" => duration }
  end

  def transit_step(departure, arrival, vehicle: nil)
    step = { "travelMode" => "TRANSIT", "transitDetails" => { "stopDetails" => {
      "departureTime" => "2026-09-20T#{departure}Z", "arrivalTime" => "2026-09-20T#{arrival}Z"
    } } }
    step["transitDetails"]["transitLine"] = { "vehicle" => { "type" => vehicle } } if vehicle
    step
  end

  def transit_route_with_vehicle(vehicle)
    value = transit_route
    value["legs"][0]["steps"][1] = transit_step("01:10:00", "01:25:00", vehicle: vehicle)
    value
  end

  def response_for(route)
    response_for_document("routes" => [route], "geocodingResults" => exact_geocoding)
  end

  def response_for_document(document)
    { status: 200, headers: json_headers, body: JSON.generate(document) }
  end

  def json_headers
    { "Content-Type" => "application/json; charset=UTF-8" }
  end

  def exact_geocoding
    { "origin" => exact_geocode, "destination" => exact_geocode }
  end

  def exact_geocode
    { "placeId" => "ChIJ_exact-match", "partialMatch" => false, "geocoderStatus" => { "code" => 0 } }
  end

  def replace_http_new(replacement)
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new, &replacement)
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, &original)
  end
end
