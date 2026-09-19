# frozen_string_literal: true

require "bigdecimal"
require "date"
require "json"
require "net/http"
require "openssl"
require "time"
require "timeout"
require "uri"

module TravelRouting
  # Only this adapter knows the external HTTP contract. Nothing returned to callers
  # contains provider error bodies, credentials, addresses, or raw route geometry.
  class GoogleRoutesProvider
    ENDPOINT = "https://routes.googleapis.com/directions/v2:computeRoutes".freeze
    MODES = %w[WALK DRIVE TRANSIT].freeze
    TRANSIT_VEHICLES = {
      "RAIL" => %w[COMMUTER_TRAIN HEAVY_RAIL HIGH_SPEED_TRAIN LONG_DISTANCE_TRAIN METRO_RAIL MONORAIL RAIL SUBWAY TRAM].freeze,
      "BUS" => %w[BUS INTERCITY_BUS TROLLEYBUS].freeze
    }.freeze
    FIELD_MASK = %w[
      routes.duration routes.distanceMeters
      routes.legs.steps.travelMode routes.legs.steps.staticDuration
      routes.legs.steps.transitDetails.stopDetails.departureTime
      routes.legs.steps.transitDetails.stopDetails.arrivalTime
      routes.legs.steps.transitDetails.transitLine.vehicle.type
      fallbackInfo.routingMode fallbackInfo.reason
      geocodingResults.origin.placeId geocodingResults.origin.partialMatch geocodingResults.origin.geocoderStatus.code
      geocodingResults.destination.placeId geocodingResults.destination.partialMatch geocodingResults.destination.geocoderStatus.code
    ].join(",").freeze
    MAX_BODY_BYTES = 262_144
    MAX_DURATION_SECONDS = 604_800
    MAX_DISTANCE_METERS = 20_000_000
    MAX_STEPS = 512
    OPEN_TIMEOUT_SECONDS = 2
    READ_TIMEOUT_SECONDS = 3
    WRITE_TIMEOUT_SECONDS = 3
    OVERALL_TIMEOUT_SECONDS = 10

    Result = Struct.new(:code, :duration_seconds, :distance_meters, :walking_seconds,
      :departure_time, :arrival_time, :attribution, keyword_init: true) do
      def initialize(**attributes)
        super
        each_pair { |_key, value| value.freeze unless value.nil? }
        freeze
      end

      def success?
        code == "ok"
      end
    end

    class InvalidResponse < StandardError; end
    class InvalidRequest < StandardError; end
    class ProviderFailure < StandardError; end
    class DuplicateAwareHash < Hash
      def []=(key, value)
        raise InvalidResponse if key?(key)

        super
      end
    end

    def initialize(api_key: ENV["GOOGLE_ROUTES_API_KEY"], transport: nil)
      @api_key = api_key
      @transport = transport || method(:default_transport)
    end

    def call(origin:, destination:, mode:, departure_time: nil, arrival_time: nil, transit_mode: nil)
      return failure("not_configured") unless configured?
      return failure("invalid_request") unless MODES.include?(mode)
      return failure("invalid_request") unless transit_mode.nil? || (mode == "TRANSIT" && TRANSIT_VEHICLES.key?(transit_mode))
      return failure("invalid_request") if departure_time && arrival_time
      return failure("unsupported_arrival_mode") if arrival_time && mode != "TRANSIT"

      departure = departure_time ? timestamp(departure_time, InvalidRequest) : nil
      arrival = arrival_time ? timestamp(arrival_time, InvalidRequest) : nil
      departure ||= Time.now.utc unless arrival
      body = {
        "origin" => waypoint(origin), "destination" => waypoint(destination),
        "travelMode" => mode, "computeAlternativeRoutes" => false,
        "languageCode" => "ja", "units" => "METRIC"
      }
      body["departureTime"] = iso8601(departure) if departure
      body["arrivalTime"] = iso8601(arrival) if arrival
      body["routingPreference"] = "TRAFFIC_AWARE" if mode == "DRIVE"
      body["transitPreferences"] = { "allowedTravelModes" => [transit_mode] } if transit_mode

      response = Timeout.timeout(OVERALL_TIMEOUT_SECONDS) do
        @transport.call(uri: URI(ENDPOINT), headers: request_headers, body: JSON.generate(body))
      end
      return failure("unavailable") unless response.is_a?(Hash) && response[:status] == 200

      validate_headers!(response[:headers])
      document = parse_document(response[:body])
      raise InvalidResponse if document.key?("fallbackInfo")

      routes = document["routes"]
      # Protobuf JSON can omit an empty repeated field such as routes.
      return failure("no_route") if !document.key?("routes") && (document.keys - ["geocodingResults"]).empty?
      return failure("no_route") if routes == []
      raise InvalidResponse unless routes.is_a?(Array) && routes.one? && routes.first.is_a?(Hash)

      validate_geocoding!(document["geocodingResults"], body)
      route = routes.first
      duration = duration_value(route["duration"], positive: true)
      distance = route["distanceMeters"]
      raise InvalidResponse unless distance.is_a?(Integer) && distance.between?(0, MAX_DISTANCE_METERS)

      walking, actual_departure, actual_arrival = route_times(route, mode, duration, departure, arrival, transit_mode)
      raise InvalidResponse if actual_arrival <= actual_departure
      raise InvalidResponse if departure && actual_departure < departure - 1
      raise InvalidResponse if arrival && actual_arrival > arrival + 1

      Result.new(code: "ok", duration_seconds: duration.ceil, distance_meters: distance,
        walking_seconds: walking.ceil, departure_time: iso8601(actual_departure),
        arrival_time: iso8601(actual_arrival), attribution: "Google Maps")
    rescue InvalidRequest
      failure("invalid_request")
    rescue InvalidResponse, JSON::ParserError, EncodingError
      failure("invalid_response")
    rescue StandardError
      # Do not expose exception messages: HTTP errors may contain input or credentials.
      failure("unavailable")
    end

    private

    def configured?
      @api_key.is_a?(String) && @api_key.match?(/\A[A-Za-z0-9_-]{1,256}\z/)
    end

    def failure(code)
      Result.new(code: code)
    end

    def request_headers
      { "Content-Type" => "application/json", "Accept" => "application/json",
        "Accept-Encoding" => "identity", "X-Goog-Api-Key" => @api_key,
        "X-Goog-FieldMask" => FIELD_MASK }
    end

    def waypoint(value)
      if value.is_a?(String)
        raise InvalidRequest unless value.valid_encoding? && value.bytesize <= 1024

        address = value.strip
        raise InvalidRequest if address.empty? || address.length > 512 || address.match?(/[[:cntrl:]]/)
        raise InvalidRequest if address.match?(/\A(?:[a-z][a-z0-9+.-]*:\/\/|www\.)/i)

        return { "address" => address }
      end
      raise InvalidRequest unless value.is_a?(Hash)
      raise InvalidRequest unless value.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }

      normalized = value.transform_keys(&:to_s)
      raise InvalidRequest unless normalized.length == value.length

      if normalized.keys == ["place_id"]
        place_id = normalized["place_id"]
        raise InvalidRequest unless place_id.is_a?(String) && place_id.match?(/\A[A-Za-z0-9_-]{1,256}\z/)

        return { "placeId" => place_id }
      end
      raise InvalidRequest unless normalized.keys.sort == %w[latitude longitude]

      latitude, longitude = normalized.values_at("latitude", "longitude")
      [[latitude, 90], [longitude, 180]].each do |coordinate, limit|
        raise InvalidRequest unless (coordinate.is_a?(Integer) || coordinate.is_a?(Float)) &&
          coordinate.finite? && coordinate.between?(-limit, limit)
      end
      { "location" => { "latLng" => { "latitude" => latitude, "longitude" => longitude } } }
    end

    def timestamp(value, error_class)
      return value.getutc if value.is_a?(Time)
      raise error_class unless value.is_a?(String) && value.bytesize <= 40

      match = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\z/.match(value)
      raise error_class unless match && Date.valid_date?(*match.captures.first(3).map(&:to_i))
      raise error_class unless match[4].to_i < 24 && match[5].to_i < 60 && match[6].to_i < 60
      if match[7] != "Z"
        raise error_class unless match[7][1, 2].to_i < 24 && match[7][4, 2].to_i < 60
      end
      Time.iso8601(value).utc
    rescue ArgumentError
      raise error_class
    end

    def iso8601(time)
      time.utc.iso8601(time.subsec.zero? ? 0 : 9)
    end

    def duration_value(value, positive: false)
      raise InvalidResponse unless value.is_a?(String) && value.match?(/\A\d{1,6}(?:\.\d{1,9})?s\z/)

      duration = BigDecimal(value.delete_suffix("s"))
      raise InvalidResponse unless duration <= MAX_DURATION_SECONDS && (positive ? duration.positive? : duration >= 0)

      duration
    end

    def route_times(route, mode, duration, requested_departure, requested_arrival, transit_mode)
      unless mode == "TRANSIT"
        return [mode == "WALK" ? duration : 0, requested_departure, requested_departure + duration.to_r]
      end

      legs = route["legs"]
      raise InvalidResponse unless legs.is_a?(Array) && legs.one? && legs.first.is_a?(Hash)

      steps = legs.first["steps"]
      raise InvalidResponse unless steps.is_a?(Array) && steps.length.between?(1, MAX_STEPS)

      walking = BigDecimal("0")
      pending_walk = BigDecimal("0")
      actual_departure = nil
      last_arrival = nil
      steps.each do |step|
        raise InvalidResponse unless step.is_a?(Hash)

        case step["travelMode"]
        when "WALK"
          step_duration = duration_value(step["staticDuration"])
          walking += step_duration
          pending_walk += step_duration
        when "TRANSIT"
          details = step["transitDetails"]
          stops = details.is_a?(Hash) ? details["stopDetails"] : nil
          raise InvalidResponse unless stops.is_a?(Hash)
          validate_transit_vehicle!(details, transit_mode) if transit_mode

          leaves = timestamp(stops["departureTime"], InvalidResponse)
          reaches = timestamp(stops["arrivalTime"], InvalidResponse)
          raise InvalidResponse unless reaches > leaves && reaches - leaves <= MAX_DURATION_SECONDS
          raise InvalidResponse if last_arrival && leaves < last_arrival + pending_walk.to_r

          actual_departure ||= leaves - pending_walk.to_r
          last_arrival = reaches
          pending_walk = BigDecimal("0")
        else
          raise InvalidResponse
        end
      end
      raise InvalidResponse if walking > duration

      if last_arrival
        actual_arrival = last_arrival + pending_walk.to_r
        # Route duration includes transfer waits, but not waiting before the trip.
        raise InvalidResponse if ((actual_arrival - actual_departure).to_r - duration.to_r).abs > 1
      else
        raise InvalidResponse if transit_mode
        raise InvalidResponse if (walking - duration).abs > 1

        actual_departure = requested_departure || requested_arrival - duration.to_r
        actual_arrival = actual_departure + duration.to_r
      end
      [walking, actual_departure, actual_arrival]
    end

    def validate_transit_vehicle!(details, transit_mode)
      line = details["transitLine"]
      vehicle = line.is_a?(Hash) ? line["vehicle"] : nil
      raise InvalidResponse unless vehicle.is_a?(Hash) && TRANSIT_VEHICLES.fetch(transit_mode).include?(vehicle["type"])
    end

    def parse_document(body)
      raise InvalidResponse unless body.is_a?(String) && body.bytesize <= MAX_BODY_BYTES

      source = body.dup.force_encoding(Encoding::UTF_8)
      raise InvalidResponse unless source.valid_encoding?

      document = JSON.parse(source, object_class: DuplicateAwareHash, create_additions: false,
        allow_nan: false, max_nesting: 20)
      raise InvalidResponse unless document.is_a?(Hash)

      document
    end

    def validate_geocoding!(results, request)
      address_roles = %w[origin destination].select { |role| request.fetch(role).key?("address") }
      return if address_roles.empty? && results.nil?

      raise InvalidResponse unless results.is_a?(Hash)

      address_roles.each do |role|
        match = results[role]
        raise InvalidResponse unless match.is_a?(Hash)
        raise InvalidResponse unless match["placeId"].is_a?(String) && match["placeId"].match?(/\A[A-Za-z0-9_-]{1,256}\z/)
        # A protobuf false/zero scalar may be absent even when its field is masked.
        raise InvalidResponse if match.key?("partialMatch") && match["partialMatch"] != false
        next unless match.key?("geocoderStatus")

        status = match["geocoderStatus"]
        raise InvalidResponse unless status.is_a?(Hash)
        raise InvalidResponse if status.key?("code") && (!status["code"].is_a?(Integer) || status["code"] != 0)
      end
    end

    def validate_headers!(headers)
      raise InvalidResponse unless headers.is_a?(Hash)

      values = headers.transform_keys { |key| key.to_s.downcase }
      raise InvalidResponse unless values["content-type"].to_s.split(";", 2).first.to_s.downcase == "application/json"
      raise InvalidResponse unless [nil, "", "identity"].include?(values["content-encoding"])

      length = values["content-length"]
      return if length.nil?

      raise InvalidResponse unless length.to_s.match?(/\A\d+\z/) && length.to_i <= MAX_BODY_BYTES
    end

    def default_transport(uri:, headers:, body:)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.min_version = OpenSSL::SSL::TLS1_2_VERSION if http.respond_to?(:min_version=)
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      http.write_timeout = WRITE_TIMEOUT_SECONDS
      http.max_retries = 0
      request = Net::HTTP::Post.new(uri.request_uri, headers)
      request.body = body
      result = nil
      http.start do |connection|
        connection.request(request) do |response|
          response_headers = response.to_hash.transform_values(&:first)
          # A redirect is returned as a failure; it is never followed with the key.
          # Raise inside the block so Net::HTTP does not automatically buffer an
          # unbounded error body when the block returns without reading it.
          raise ProviderFailure unless response.code == "200"

          result = { status: response.code.to_i, headers: response_headers, body: +"".b }
          validate_headers!(response_headers)
          response.read_body do |chunk|
            raise InvalidResponse if result[:body].bytesize + chunk.bytesize > MAX_BODY_BYTES

            result[:body] << chunk.b
          end
        end
      end
      result
    end
  end
end
