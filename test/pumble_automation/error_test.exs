defmodule PumbleAutomation.ErrorTest do
  use ExUnit.Case, async: true

  alias PumbleAutomation.Error

  doctest PumbleAutomation.Error

  describe "new/3" do
    test "carries the class, the code, and a safe message" do
      error = Error.new(:validation, :bad_action, message: "The action code is not valid.")

      assert error.class == :validation
      assert error.code == :bad_action
      assert error.message == "The action code is not valid."
      assert error.details == %{}
      assert error.cause == nil
    end

    test "defaults retryability from the class" do
      refute Error.retryable?(Error.new(:validation, :bad_action))
      refute Error.retryable?(Error.new(:permission, :forbidden))
      assert Error.retryable?(Error.new(:dependency, :database_unavailable))
      assert Error.retryable?(Error.new(:timeout, :slow))
      assert Error.retryable?(Error.new(:rate_limited, :quota))
    end

    test "an explicit retryability wins over the class default" do
      assert Error.retryable?(Error.new(:validation, :bad_action, retryable?: true))
      refute Error.retryable?(Error.new(:dependency, :gone_forever, retryable?: false))
    end

    test "every class has a safe default message" do
      for class <- [
            :validation,
            :not_found,
            :conflict,
            :permission,
            :dependency,
            :timeout,
            :rate_limited,
            :internal
          ] do
        assert is_binary(Error.new(class, :some_code).message)
      end
    end

    test "sanitizes details on the way in" do
      error =
        Error.new(:dependency, :call_failed,
          details: %{token: "abc123", status: 500, nested: %{"client_secret" => "shhh"}}
        )

      assert error.details == %{
               token: "[REDACTED]",
               status: 500,
               nested: %{"client_secret" => "[REDACTED]"}
             }
    end
  end

  describe "sanitize/1" do
    test "redacts every secret-looking key name" do
      secret_keys = [
        :token,
        :access_token,
        :refresh_token,
        :secret,
        :client_secret,
        :signing_secret,
        :code,
        :authorization_code,
        :password,
        :passwd,
        :credential,
        :api_key,
        :"api-key",
        :apikey,
        :signature,
        :cookie,
        :authorization,
        :bearer
      ]

      for key <- secret_keys do
        assert Error.sanitize(%{key => "sensitive"}) == %{key => "[REDACTED]"},
               "expected #{key} to be redacted"
      end
    end

    test "matches key names case-insensitively and inside longer names" do
      assert Error.sanitize(%{"X-Addon-Token" => "abc"}) == %{"X-Addon-Token" => "[REDACTED]"}

      assert Error.sanitize(%{"PUMBLE_CLIENT_SECRET" => "abc"}) == %{
               "PUMBLE_CLIENT_SECRET" => "[REDACTED]"
             }
    end

    test "keeps values whose keys are not secret-looking" do
      details = %{status: 500, installation_id: "abc", retry: true, ratio: 0.5}

      assert Error.sanitize(details) == details
    end

    test "walks nested maps, lists, and keyword lists" do
      details = %{
        request: %{headers: %{authorization: "Bearer x"}, path: "/oauth/callback"},
        attempts: [%{code: "one"}, %{reason: "two"}],
        opts: [token: "x", timeout: 10]
      }

      assert Error.sanitize(details) == %{
               request: %{headers: %{authorization: "[REDACTED]"}, path: "/oauth/callback"},
               attempts: [%{code: "[REDACTED]"}, %{reason: "two"}],
               opts: [token: "[REDACTED]", timeout: 10]
             }
    end

    test "returns scalars and structs unchanged" do
      now = DateTime.utc_now()

      assert Error.sanitize("plain") == "plain"
      assert Error.sanitize(42) == 42
      assert Error.sanitize(nil) == nil
      assert Error.sanitize(now) == now
    end

    test "ignores keys that are neither atoms nor strings" do
      assert Error.sanitize(%{1 => "one"}) == %{1 => "one"}
    end
  end

  describe "the no-web-types invariant" do
    test "the error module names no Plug or Phoenix type" do
      source = File.read!("lib/pumble_automation/error.ex")

      refute source =~ "Plug."
      refute source =~ "Phoenix."
    end

    test "the struct holds no process, port, or reference by construction" do
      error = Error.new(:internal, :defect, cause: %RuntimeError{message: "boom"})

      assert %RuntimeError{} = error.cause

      assert Enum.sort(Map.keys(error)) == [
               :__struct__,
               :cause,
               :class,
               :code,
               :details,
               :message,
               :retryable?
             ]
    end
  end
end
