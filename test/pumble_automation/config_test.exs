defmodule PumbleAutomation.ConfigTest do
  use ExUnit.Case, async: true

  alias PumbleAutomation.Config

  # A value that must never appear in an error message.
  @sentinel "sup3r-sekrit-sentinel"

  @required_vars ~w(
    DATABASE_URL
    PUBLIC_BASE_URL
    SECRET_KEY_BASE
    SESSION_SIGNING_SALT
    PUMBLE_CLIENT_ID
    PUMBLE_CLIENT_SECRET
    PUMBLE_APP_KEY
    PUMBLE_SIGNING_SECRET
    ENCRYPTION_KEY
  )

  defp valid_env do
    %{
      "DATABASE_URL" => "ecto://user:pass@db.internal:5432/pumble_automation",
      "PUBLIC_BASE_URL" => "https://automation.example.com",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "SESSION_SIGNING_SALT" => String.duplicate("t", 16),
      "PUMBLE_CLIENT_ID" => "client-id",
      "PUMBLE_CLIENT_SECRET" => String.duplicate("c", 32),
      "PUMBLE_APP_KEY" => String.duplicate("k", 32),
      "PUMBLE_SIGNING_SECRET" => String.duplicate("g", 32),
      "ENCRYPTION_KEY" => Base.encode64(:binary.copy(<<7>>, 32), padding: false)
    }
  end

  describe "fetch_string!/2" do
    test "returns the trimmed value" do
      assert Config.fetch_string!(%{"A" => "  value  "}, "A") == "value"
    end

    test "treats an unset or blank variable as missing" do
      assert_raise ArgumentError, ~r/A is missing/, fn -> Config.fetch_string!(%{}, "A") end

      assert_raise ArgumentError, ~r/A is missing/, fn ->
        Config.fetch_string!(%{"A" => " "}, "A")
      end
    end
  end

  describe "fetch_secret!/3" do
    test "accepts a value at the minimum length" do
      assert Config.fetch_secret!(%{"A" => "12345678"}, "A", 8) == "12345678"
    end

    test "rejects a short value without echoing it" do
      message = assert_error(fn -> Config.fetch_secret!(%{"A" => @sentinel}, "A", 999) end)

      assert message =~ "A is invalid"
      assert message =~ "at least 999 characters"
      refute message =~ @sentinel
    end
  end

  describe "fetch_integer!/3" do
    test "parses an integer" do
      assert Config.fetch_integer!(%{"A" => "42"}, "A") == 42
    end

    test "uses the default when unset" do
      assert Config.fetch_integer!(%{}, "A", default: 10) == 10
    end

    test "requires the variable when there is no default" do
      assert_raise ArgumentError, ~r/A is missing/, fn -> Config.fetch_integer!(%{}, "A") end
    end

    test "rejects a non-integer, a trailing suffix, and out-of-range values" do
      assert_raise ArgumentError, ~r/A is invalid/, fn ->
        Config.fetch_integer!(%{"A" => "ten"}, "A")
      end

      assert_raise ArgumentError, ~r/A is invalid/, fn ->
        Config.fetch_integer!(%{"A" => "10x"}, "A")
      end

      assert_raise ArgumentError, ~r/between 1 and 5/, fn ->
        Config.fetch_integer!(%{"A" => "9"}, "A", min: 1, max: 5)
      end

      assert_raise ArgumentError, ~r/between 1 and 5/, fn ->
        Config.fetch_integer!(%{"A" => "0"}, "A", min: 1, max: 5)
      end
    end
  end

  describe "fetch_boolean!/3" do
    test "accepts the documented spellings" do
      for value <- ~w(true TRUE 1 yes) do
        assert Config.fetch_boolean!(%{"A" => value}, "A") == true
      end

      for value <- ~w(false FALSE 0 no) do
        assert Config.fetch_boolean!(%{"A" => value}, "A") == false
      end
    end

    test "uses the default when unset" do
      assert Config.fetch_boolean!(%{}, "A", default: true) == true
    end

    test "rejects anything else" do
      assert_raise ArgumentError, ~r/A is invalid/, fn ->
        Config.fetch_boolean!(%{"A" => "maybe"}, "A")
      end
    end
  end

  describe "fetch_url!/2" do
    test "splits a canonical https URL" do
      env = %{"A" => "https://automation.example.com"}

      assert Config.fetch_url!(env, "A") == %{
               scheme: "https",
               host: "automation.example.com",
               port: 443,
               url: "https://automation.example.com"
             }
    end

    test "keeps a non-default port in the canonical URL" do
      assert %{port: 8443, url: "https://example.com:8443"} =
               Config.fetch_url!(%{"A" => "https://example.com:8443"}, "A")
    end

    test "accepts a bare trailing slash" do
      assert %{url: "https://example.com"} =
               Config.fetch_url!(%{"A" => "https://example.com/"}, "A")
    end

    test "rejects malformed URLs" do
      for value <- [
            "example.com",
            "ftp://example.com",
            "https://",
            "https://user:pass@example.com",
            "https://example.com/base",
            "https://example.com?a=1",
            "https://example.com#frag"
          ] do
        assert_raise ArgumentError, ~r/A is invalid/, fn ->
          Config.fetch_url!(%{"A" => value}, "A")
        end
      end
    end
  end

  describe "fetch_base64_key!/3" do
    test "decodes a key of the expected byte length" do
      key = :binary.copy(<<9>>, 32)

      assert Config.fetch_base64_key!(%{"A" => Base.encode64(key)}, "A", 32) == key
    end

    test "rejects a wrong length or non-Base64 value without echoing it" do
      short = Base.encode64(:binary.copy(<<9>>, 16))

      assert_raise ArgumentError, ~r/32 Base64 encoded bytes/, fn ->
        Config.fetch_base64_key!(%{"A" => short}, "A", 32)
      end

      message = assert_error(fn -> Config.fetch_base64_key!(%{"A" => @sentinel}, "A", 32) end)

      assert message =~ "A is invalid"
      refute message =~ @sentinel
    end
  end

  describe "fetch_queue_concurrency!/1" do
    test "falls back to the documented starting limits" do
      assert Config.fetch_queue_concurrency!(%{}) == Config.queue_defaults()
    end

    test "reads per-queue overrides" do
      assert Config.fetch_queue_concurrency!(%{"QUEUE_CONCURRENCY_INGRESS" => "5"})[:ingress] == 5
    end
  end

  describe "fetch_encryption_key_version!/1" do
    test "defaults to the first version" do
      assert Config.fetch_encryption_key_version!(%{}) == 1
    end

    test "refuses a version the envelope byte cannot hold" do
      message =
        assert_error(fn ->
          Config.fetch_encryption_key_version!(%{"ENCRYPTION_KEY_VERSION" => "256"})
        end)

      assert message =~ "between 1 and 255"
    end
  end

  describe "fetch_encryption_legacy_keys!/1" do
    test "returns no keys when no rotation is in progress" do
      assert Config.fetch_encryption_legacy_keys!(%{}) == %{}
      assert Config.fetch_encryption_legacy_keys!(%{"ENCRYPTION_LEGACY_KEYS" => " "}) == %{}
    end

    test "parses versioned keys" do
      first = :binary.copy(<<1>>, 32)
      second = :binary.copy(<<2>>, 32)

      env = %{"ENCRYPTION_LEGACY_KEYS" => "1:#{encode(first)}, 2:#{encode(second)}"}

      assert Config.fetch_encryption_legacy_keys!(env) == %{1 => first, 2 => second}
    end

    test "refuses a malformed entry without echoing it" do
      for value <- [
            "1",
            "1:not-base64!",
            "#{encode(:binary.copy(<<1>>, 32))}",
            "0:#{encode(:binary.copy(<<1>>, 32))}",
            "1:#{encode("short")}",
            "1:#{@sentinel}"
          ] do
        message =
          assert_error(fn ->
            Config.fetch_encryption_legacy_keys!(%{"ENCRYPTION_LEGACY_KEYS" => value})
          end)

        assert message =~ "ENCRYPTION_LEGACY_KEYS is invalid"
        refute message =~ @sentinel
      end
    end

    test "refuses a repeated version" do
      key = encode(:binary.copy(<<1>>, 32))

      message =
        assert_error(fn ->
          Config.fetch_encryption_legacy_keys!(%{"ENCRYPTION_LEGACY_KEYS" => "1:#{key},1:#{key}"})
        end)

      assert message =~ "one entry per key version"
    end
  end

  describe "load_prod!/1" do
    test "reads the legacy keys kept for a rotation" do
      legacy = :binary.copy(<<5>>, 32)

      env =
        Map.merge(valid_env(), %{
          "ENCRYPTION_KEY_VERSION" => "2",
          "ENCRYPTION_LEGACY_KEYS" => "1:#{encode(legacy)}"
        })

      assert Config.load_prod!(env).encryption_legacy_keys == %{1 => legacy}
    end

    test "refuses a legacy key that claims the current version" do
      legacy = encode(:binary.copy(<<5>>, 32))
      env = Map.put(valid_env(), "ENCRYPTION_LEGACY_KEYS", "1:#{legacy}")

      message = assert_error(fn -> Config.load_prod!(env) end)

      assert message =~ "versions other than the current ENCRYPTION_KEY_VERSION"
    end

    test "returns every validated setting" do
      settings = Config.load_prod!(valid_env())

      assert settings.database_url == "ecto://user:pass@db.internal:5432/pumble_automation"
      assert settings.database_ssl == true
      assert settings.database_ipv6 == false
      assert settings.pool_size == 10
      assert settings.port == 4000
      assert settings.public_url.url == "https://automation.example.com"
      assert byte_size(settings.encryption_key) == 32
      assert settings.encryption_key_version == 1
      assert settings.queue_concurrency == Config.queue_defaults()
      assert settings.limits.max_request_body_bytes == 1_048_576
      assert settings.limits.pumble_callback_body_bytes == 1_048_576
      assert settings.limits.workflow_nodes == 50
      assert settings.limits.redirects == 3
      assert settings.limits.retries == 5
      assert settings.limits.outbound_http_timeout_ms == 10_000
      assert settings.trusted_proxies == []
      assert settings.dns_cluster_query == nil
      assert settings.log_level == :info
    end

    test "applies optional overrides" do
      env =
        Map.merge(valid_env(), %{
          "DATABASE_SSL" => "false",
          "ECTO_IPV6" => "true",
          "POOL_SIZE" => "25",
          "PORT" => "8080",
          "ENCRYPTION_KEY_VERSION" => "3",
          "QUEUE_CONCURRENCY_EXECUTIONS" => "40",
          "OUTBOUND_HTTP_TIMEOUT_MS" => "5000",
          "DNS_CLUSTER_QUERY" => "app.internal"
        })

      settings = Config.load_prod!(env)

      assert settings.database_ssl == false
      assert settings.database_ipv6 == true
      assert settings.pool_size == 25
      assert settings.port == 8080
      assert settings.encryption_key_version == 3
      assert settings.queue_concurrency[:executions] == 40
      assert settings.limits.outbound_http_timeout_ms == 5_000
      assert settings.dns_cluster_query == "app.internal"
    end

    test "LOG_LEVEL is configurable without echoing an invalid value" do
      assert Config.load_prod!(Map.put(valid_env(), "LOG_LEVEL", "warning")).log_level ==
               :warning

      message =
        assert_error(fn -> Config.load_prod!(Map.put(valid_env(), "LOG_LEVEL", @sentinel)) end)

      assert message =~ "LOG_LEVEL is invalid"
      refute message =~ @sentinel
    end

    test "applies typed limit overrides up to the hard cap" do
      env =
        Map.merge(valid_env(), %{
          "LIMIT_WORKFLOW_NODES" => "40",
          "TRUSTED_PROXIES" => "10.0.0.1/32, 192.168.0.0/16"
        })

      settings = Config.load_prod!(env)

      assert settings.limits.workflow_nodes == 40
      assert settings.trusted_proxies == [{{10, 0, 0, 1}, 32}, {{192, 168, 0, 0}, 16}]
    end

    test "refuses a limit override above the hard cap without echoing the value" do
      message =
        assert_error(fn -> Config.load_prod!(Map.put(valid_env(), "LIMIT_REDIRECTS", "4")) end)

      assert message =~ "LIMIT_REDIRECTS is invalid"
      refute message =~ "4"
    end

    test "fails closed when any required variable is absent" do
      for name <- @required_vars do
        env = Map.delete(valid_env(), name)
        message = assert_error(fn -> Config.load_prod!(env) end)

        assert message =~ "environment variable #{name} is missing",
               "expected load_prod!/1 to report #{name} as missing, got: #{message}"
      end
    end

    test "reports the variable name but never the value when a secret is malformed" do
      for name <- @required_vars do
        env = Map.put(valid_env(), name, @sentinel)

        case safe_error(fn -> Config.load_prod!(env) end) do
          nil ->
            :ok

          message ->
            assert message =~ name
            refute message =~ @sentinel
        end
      end
    end
  end

  defp encode(key), do: Base.encode64(key, padding: false)

  defp assert_error(fun) do
    error = assert_raise ArgumentError, fun
    Exception.message(error)
  end

  defp safe_error(fun) do
    fun.()
    nil
  rescue
    error in ArgumentError -> Exception.message(error)
  end
end
