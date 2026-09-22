# frozen_string_literal: true

require 'base64'
require 'openssl'
require 'securerandom'

module SecretaryMutation
  class Versioner
    def initialize(configuration:)
      @keys = configuration.hmac_keys
      @active_kid = configuration.active_hmac_kid
    end

    def target_version(event, time_zone:, reference: nil)
      kid = reference ? reference_kid(reference, 'sv1') : @active_kid
      sign('target-version', {
        'target_type' => 'event', 'target_id' => event.id, 'owner_id' => event.created_by_id,
        'snapshot' => EventProjection.snapshot(event, time_zone: time_zone),
        'relationships' => EventProjection.related_tuples(event),
        'updated_at' => event.updated_at.utc.iso8601(6)
      }, prefix: 'sv1', kid: kid)
    end

    def relationship_fingerprint(event, reference: nil)
      kid = reference ? reference_kid(reference, 'sr1') : @active_kid
      sign('relationship-fingerprint', {
        'target_type' => 'event', 'target_id' => event.id,
        'relationships' => EventProjection.related_tuples(event)
      }, prefix: 'sr1', kid: kid)
    end

    def security_context_digest(user:, home_subject:)
      key = @keys.fetch(@active_kid) { raise Error.new(:unavailable) }
      context = {
        'provider' => 'chrono_flow', 'user_id' => user.id, 'home_subject' => home_subject,
        'identity_issuer' => user.identity_issuer, 'identity_subject' => user.identity_subject,
        'user_status' => user.status, 'user_version' => user.updated_at.utc.iso8601(6)
      }
      input = SecretaryMutation::Contract.canonical_json(
        'domain' => 'chrono_flow.mutation.security-context.v1', 'value' => context
      )
      OpenSSL::HMAC.hexdigest('SHA256', key, input)
    rescue SecretaryMutation::Contract::Invalid
      raise Error.new(:unavailable), cause: nil
    end

    def opaque_ref(prefix)
      "#{prefix}_#{SecureRandom.urlsafe_base64(32, false)}"
    end

    private

    def sign(domain, value, prefix:, kid:)
      key = @keys.fetch(kid) { raise Error.new(:unavailable) }
      bytes = SecretaryMutation::Contract.canonical_json(value)
      mac = OpenSSL::HMAC.digest('SHA256', key, "#{domain}\0#{bytes}")
      "#{prefix}_#{kid}_#{Base64.urlsafe_encode64(mac, padding: false)}"
    rescue SecretaryMutation::Contract::Invalid
      raise Error.new(:unavailable), cause: nil
    end


    def reference_kid(reference, prefix)
      match = /\A#{Regexp.escape(prefix)}_([A-Za-z0-9_-]{1,16})_[A-Za-z0-9_-]{43}\z/.match(reference.to_s)
      raise Error.new(:unavailable) unless match

      match[1]
    end
  end
end
