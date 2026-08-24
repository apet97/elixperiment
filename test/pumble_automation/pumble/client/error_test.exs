defmodule PumbleAutomation.Pumble.Client.ErrorTest do
  use ExUnit.Case, async: true

  alias PumbleAutomation.Error, as: DomainError
  alias PumbleAutomation.Pumble.Client.Error

  describe "from_status/3 classification" do
    test "400 is a validation failure and never retryable" do
      error = Error.from_status(400, %{"message" => "bad channel"})

      assert error.class == :validation
      assert error.status == 400
      refute Error.retryable?(error)
    end

    test "401 is authentication and is never transient" do
      error = Error.from_status(401, "")

      assert error.class == :authentication
      refute Error.retryable?(error)
    end

    test "403 with a mapped scope is a missing scope" do
      error = Error.from_status(403, "", scope: "messages:write")

      assert error.class == :missing_scope
      refute Error.retryable?(error)
    end

    test "403 with no mapped scope stays authorization" do
      assert Error.from_status(403, "").class == :authorization
    end

    test "404 is not found and 409 is a conflict" do
      assert Error.from_status(404, "").class == :not_found
      assert Error.from_status(409, "").class == :conflict
    end

    test "429 is rate limited and retryable" do
      error = Error.from_status(429, "", retry_after_header: ["30"])

      assert error.class == :rate_limited
      assert error.retry_after == 30
      assert Error.retryable?(error)
    end

    test "5xx on an idempotent effect is remote transient" do
      error = Error.from_status(503, "", idempotent_effect?: true)

      assert error.class == :remote_transient
      assert Error.retryable?(error)
    end

    test "5xx on a write is uncertain, not transient" do
      error = Error.from_status(500, "", idempotent_effect?: false)

      assert error.class == :side_effect_uncertain
      refute Error.retryable?(error)
    end

    test "an unlisted 4xx is remote permanent" do
      assert Error.from_status(418, "").class == :remote_permanent
    end

    test "the operation and the provider request id are carried" do
      error = Error.from_status(500, "", operation: :post_message, provider_request_id: "req-1")

      assert error.operation == :post_message
      assert error.provider_request_id == "req-1"
    end
  end

  describe "parse_retry_after/1" do
    test "reads the delay-seconds form" do
      assert Error.parse_retry_after("12") == 12
      assert Error.parse_retry_after(["12"]) == 12
      assert Error.parse_retry_after(" 12 ") == 12
    end

    test "clamps a value outside the bounds instead of trusting it" do
      assert Error.parse_retry_after("0") == 1
      assert Error.parse_retry_after("86400") == 900
    end

    test "refuses an HTTP-date, a malformed value, and an absent header" do
      assert Error.parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT") == nil
      assert Error.parse_retry_after("soon") == nil
      assert Error.parse_retry_after("12s") == nil
      assert Error.parse_retry_after(nil) == nil
      assert Error.parse_retry_after([]) == nil
    end

    test "a 429 with no header carries no hint" do
      assert Error.from_status(429, "").retry_after == nil
    end
  end

  describe "from_transport/2" do
    test "a failure that cannot have written is transient" do
      assert Error.from_transport(:econnrefused).class == :transient_transport
    end

    test "a timeout on a write is ambiguous, because dispatch may have begun" do
      error = Error.from_transport(:timeout, idempotent_effect?: false)

      assert error.class == :ambiguous_transport
      refute Error.retryable?(error)
    end

    test "a timeout on an idempotent effect is safe to repeat" do
      error = Error.from_transport(:timeout, idempotent_effect?: true)

      assert error.class == :transient_transport
      assert Error.retryable?(error)
    end

    test "a closed connection is treated like a timeout" do
      assert Error.from_transport(:closed).class == :ambiguous_transport
    end
  end

  describe "from_credential_error/2" do
    test "maps each credential failure into the taxonomy" do
      assert class_of(:installation_not_found) == :not_found
      assert class_of(:installation_revoked) == :installation_revoked
      assert class_of(:bot_credential_missing) == :authentication
      assert class_of(:user_credential_missing) == :authentication
    end

    test "carries no status, because nothing was sent" do
      error = Error.from_credential_error(DomainError.new(:permission, :installation_revoked))

      assert error.status == nil
    end
  end

  describe "body summaries" do
    test "a secret-looking key in a JSON body is redacted" do
      error = Error.from_status(400, %{"token" => "s3cret", "message" => "no"})

      refute error.body_summary =~ "s3cret"
      assert error.body_summary =~ "REDACTED"
      assert error.body_summary =~ "no"
    end

    test "a long body is truncated to the cap" do
      error = Error.from_status(500, String.duplicate("x", 10_000))

      assert byte_size(error.body_summary) <= Error.max_summary_bytes()
    end

    test "control characters are collapsed, so one error is one log line" do
      error = Error.from_status(400, "line one\nline two\r\n")

      assert error.body_summary == "line one line two"
    end

    test "a non-text body is described rather than printed" do
      error = Error.from_status(500, <<0xFF, 0xFE, 0xFD>>)

      assert error.body_summary =~ "non-text body"
    end

    test "an empty body carries no summary" do
      assert Error.from_status(404, "").body_summary == nil
    end
  end

  defp class_of(code) do
    :permission
    |> DomainError.new(code)
    |> Error.from_credential_error()
    |> Map.fetch!(:class)
  end
end
