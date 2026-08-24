defmodule PumbleAutomation.Config do
  @moduledoc """
  Typed parsing and validation of runtime configuration.

  Every function takes an environment map, usually the result of
  `System.get_env/0`. Nothing here reads process or application state, so the
  parsers stay pure and testable.

  Validation errors name the offending variable and the expected shape. They
  never contain the value, because most of these variables hold secrets.

  `load_prod!/1` is the single entry point used by `config/runtime.exs`. It
  raises when any required variable is missing or malformed, so a production
  release fails to boot instead of starting with unsafe defaults.
  """

  @queue_defaults [ingress: 20, executions: 20, schedules: 2, maintenance: 2]
  @encryption_key_bytes 32
  # One byte of every ciphertext envelope names the key that sealed it, so a
  # version outside this range cannot be written. See
  # `PumbleAutomation.Crypto.Vault`.
  @max_encryption_key_version 255
  @min_secret_key_base_length 64
  @min_signing_salt_length 8
  @min_secret_length 16

  @typedoc "A canonical, absolute public URL split into its parts."
  @type public_url :: %{
          scheme: String.t(),
          host: String.t(),
          port: pos_integer(),
          url: String.t()
        }

  @doc """
  Reads and validates every production runtime setting.

  Raises `ArgumentError` with a redacted, actionable message on the first
  missing or malformed variable.
  """
  @spec load_prod!(map()) :: map()
  def load_prod!(env) when is_map(env) do
    validate_encryption_keys!(%{
      database_url: fetch_string!(env, "DATABASE_URL"),
      database_ssl: fetch_boolean!(env, "DATABASE_SSL", default: true),
      database_ipv6: fetch_boolean!(env, "ECTO_IPV6", default: false),
      pool_size: fetch_integer!(env, "POOL_SIZE", default: 10, min: 1, max: 100),
      port: fetch_integer!(env, "PORT", default: 4000, min: 1, max: 65_535),
      public_url: fetch_url!(env, "PUBLIC_BASE_URL"),
      secret_key_base: fetch_secret!(env, "SECRET_KEY_BASE", @min_secret_key_base_length),
      session_signing_salt: fetch_secret!(env, "SESSION_SIGNING_SALT", @min_signing_salt_length),
      pumble_client_id: fetch_string!(env, "PUMBLE_CLIENT_ID"),
      pumble_client_secret: fetch_secret!(env, "PUMBLE_CLIENT_SECRET", @min_secret_length),
      pumble_app_key: fetch_secret!(env, "PUMBLE_APP_KEY", @min_secret_length),
      pumble_signing_secret: fetch_secret!(env, "PUMBLE_SIGNING_SECRET", @min_secret_length),
      encryption_key: fetch_base64_key!(env, "ENCRYPTION_KEY", @encryption_key_bytes),
      encryption_key_version: fetch_encryption_key_version!(env),
      encryption_legacy_keys: fetch_encryption_legacy_keys!(env),
      queue_concurrency: fetch_queue_concurrency!(env),
      limits: fetch_limits!(env),
      trusted_proxies: fetch_trusted_proxies!(env),
      dns_cluster_query: optional_string(env, "DNS_CLUSTER_QUERY"),
      log_level: fetch_log_level!(env)
    })
  end

  @doc """
  Parses the version stamp written into every ciphertext this release produces.

  The envelope carries the version in one byte, so 255 is a hard ceiling rather
  than a policy.
  """
  @spec fetch_encryption_key_version!(map()) :: pos_integer()
  def fetch_encryption_key_version!(env) do
    fetch_integer!(env, "ENCRYPTION_KEY_VERSION",
      default: 1,
      min: 1,
      max: @max_encryption_key_version
    )
  end

  @doc """
  Parses the read-only keys kept so that rows written before a rotation stay
  readable.

  Format: `version:base64key`, comma separated, for example
  `1:Zm9v...,2:YmFy...`. The variable is optional; an unset variable means no
  rotation is in progress.

  A malformed entry, a repeated version, a version outside 1..255, and a key
  that is not #{@encryption_key_bytes} decoded bytes are all refused. A legacy
  key is still a live key, and one that silently fails to load looks exactly
  like data loss on the day it is needed.
  """
  @spec fetch_encryption_legacy_keys!(map()) :: %{pos_integer() => binary()}
  def fetch_encryption_legacy_keys!(env) do
    name = "ENCRYPTION_LEGACY_KEYS"

    case optional_string(env, name) do
      nil -> %{}
      value -> parse_legacy_keys!(name, value)
    end
  end

  @doc """
  Returns the trimmed value of a required variable.

  An unset or blank variable is treated as missing.
  """
  @spec fetch_string!(map(), String.t()) :: String.t()
  def fetch_string!(env, name) do
    case optional_string(env, name) do
      nil -> raise ArgumentError, missing_message(name)
      value -> value
    end
  end

  @doc """
  Returns a required secret and checks its minimum character length.
  """
  @spec fetch_secret!(map(), String.t(), pos_integer()) :: String.t()
  def fetch_secret!(env, name, min_length) do
    value = fetch_string!(env, name)

    if String.length(value) < min_length do
      raise ArgumentError, invalid_message(name, "at least #{min_length} characters")
    end

    value
  end

  @doc """
  Parses an integer variable.

  Options: `:default` (makes the variable optional), `:min`, and `:max`.
  """
  @spec fetch_integer!(map(), String.t(), keyword()) :: integer()
  def fetch_integer!(env, name, opts \\ []) do
    case {optional_string(env, name), Keyword.fetch(opts, :default)} do
      {nil, {:ok, default}} -> default
      {nil, :error} -> raise ArgumentError, missing_message(name)
      {value, _} -> parse_integer!(name, value, opts)
    end
  end

  @doc """
  Parses a boolean variable. Accepts `true`/`false`, `1`/`0`, `yes`/`no`.

  Options: `:default` (makes the variable optional).
  """
  @spec fetch_boolean!(map(), String.t(), keyword()) :: boolean()
  def fetch_boolean!(env, name, opts \\ []) do
    case {optional_string(env, name), Keyword.fetch(opts, :default)} do
      {nil, {:ok, default}} -> default
      {nil, :error} -> raise ArgumentError, missing_message(name)
      {value, _} -> parse_boolean!(name, value)
    end
  end

  @doc """
  Parses a required absolute `http`/`https` URL used as a canonical public URL.

  The URL must have no userinfo, no query, no fragment, and no path beyond `/`.
  """
  @spec fetch_url!(map(), String.t()) :: public_url()
  def fetch_url!(env, name) do
    uri = URI.parse(fetch_string!(env, name))

    cond do
      uri.scheme not in ["http", "https"] ->
        raise ArgumentError, invalid_message(name, "an absolute http:// or https:// URL")

      is_nil(uri.host) or uri.host == "" ->
        raise ArgumentError, invalid_message(name, "a URL with a host")

      not is_nil(uri.userinfo) ->
        raise ArgumentError, invalid_message(name, "a URL without userinfo")

      not is_nil(uri.query) or not is_nil(uri.fragment) ->
        raise ArgumentError, invalid_message(name, "a URL without query or fragment")

      uri.path not in [nil, "/"] ->
        raise ArgumentError, invalid_message(name, "a URL without a path")

      true ->
        %{scheme: uri.scheme, host: uri.host, port: uri.port, url: canonical_url(uri)}
    end
  end

  @doc """
  Parses a required Base64 encoded key and checks its decoded byte length.
  """
  @spec fetch_base64_key!(map(), String.t(), pos_integer()) :: binary()
  def fetch_base64_key!(env, name, bytes) do
    value = fetch_string!(env, name)
    expected = "#{bytes} Base64 encoded bytes"

    case Base.decode64(value, padding: false) do
      {:ok, key} when byte_size(key) == bytes -> key
      _other -> raise ArgumentError, invalid_message(name, expected)
    end
  end

  @doc """
  Reads per-queue concurrency, falling back to the documented starting limits.
  """
  @spec fetch_queue_concurrency!(map()) :: keyword()
  def fetch_queue_concurrency!(env) do
    Enum.map(@queue_defaults, fn {queue, default} ->
      name = "QUEUE_CONCURRENCY_" <> String.upcase(Atom.to_string(queue))
      {queue, fetch_integer!(env, name, default: default, min: 1, max: 200)}
    end)
  end

  @doc """
  Reads the operational limits that bound inbound and outbound work.

  Each value is clamped to the hard cap in `PumbleAutomation.Limits`. Crossing
  a cap is refused at boot rather than silently truncated.
  """
  @spec fetch_limits!(map()) :: map()
  def fetch_limits!(env) do
    %{
      max_request_body_bytes:
        fetch_limit!(env, "MAX_REQUEST_BODY_BYTES", :pumble_callback_body_bytes),
      pumble_callback_body_bytes:
        fetch_limit!(env, "MAX_REQUEST_BODY_BYTES", :pumble_callback_body_bytes),
      outbound_http_timeout_ms:
        fetch_integer!(env, "OUTBOUND_HTTP_TIMEOUT_MS", default: 10_000, min: 100, max: 120_000),
      workflow_nodes: fetch_limit!(env, "LIMIT_WORKFLOW_NODES", :workflow_nodes),
      branch_depth: fetch_limit!(env, "LIMIT_BRANCH_DEPTH", :branch_depth),
      definition_size_bytes: fetch_limit!(env, "LIMIT_DEFINITION_BYTES", :definition_size_bytes),
      active_workflows: fetch_limit!(env, "LIMIT_ACTIVE_WORKFLOWS", :active_workflows),
      total_workflows: fetch_limit!(env, "LIMIT_TOTAL_WORKFLOWS", :total_workflows),
      schedules_per_workspace: fetch_limit!(env, "LIMIT_SCHEDULES", :schedules_per_workspace),
      running_executions: fetch_limit!(env, "LIMIT_RUNNING_EXECUTIONS", :running_executions),
      queued_executions: fetch_limit!(env, "LIMIT_QUEUED_EXECUTIONS", :queued_executions),
      context_size_bytes: fetch_limit!(env, "LIMIT_CONTEXT_BYTES", :context_size_bytes),
      template_source_bytes:
        fetch_limit!(env, "LIMIT_TEMPLATE_SOURCE_BYTES", :template_source_bytes),
      template_expansion_bytes:
        fetch_limit!(env, "LIMIT_TEMPLATE_EXPANSION_BYTES", :template_expansion_bytes),
      generic_webhook_body_bytes:
        fetch_limit!(env, "LIMIT_WEBHOOK_BODY_BYTES", :generic_webhook_body_bytes),
      http_request_body_bytes:
        fetch_limit!(env, "LIMIT_HTTP_REQUEST_BYTES", :http_request_body_bytes),
      http_response_body_bytes:
        fetch_limit!(env, "LIMIT_HTTP_RESPONSE_BYTES", :http_response_body_bytes),
      redirects: fetch_limit!(env, "LIMIT_REDIRECTS", :redirects),
      retries: fetch_limit!(env, "LIMIT_RETRIES", :retries),
      delay_seconds: fetch_limit!(env, "LIMIT_DELAY_SECONDS", :delay_seconds),
      execution_lifetime_seconds:
        fetch_limit!(env, "LIMIT_EXECUTION_LIFETIME_SECONDS", :execution_lifetime_seconds),
      lineage_depth: fetch_limit!(env, "LIMIT_LINEAGE_DEPTH", :lineage_depth),
      lineage_descendants: fetch_limit!(env, "LIMIT_LINEAGE_DESCENDANTS", :lineage_descendants),
      callback_failures_per_minute:
        fetch_limit!(env, "LIMIT_CALLBACK_FAILURES_PER_MINUTE", :callback_failures_per_minute),
      manual_runs_per_minute:
        fetch_limit!(env, "LIMIT_MANUAL_RUNS_PER_MINUTE", :manual_runs_per_minute),
      expensive_ui_per_minute:
        fetch_limit!(env, "LIMIT_EXPENSIVE_UI_PER_MINUTE", :expensive_ui_per_minute)
    }
  end

  @doc """
  Parses `TRUSTED_PROXIES` as comma-separated IPv4/IPv6 CIDRs or bare addresses.

  An unset variable means forwarding headers are ignored.
  """
  @spec fetch_trusted_proxies!(map()) :: [{tuple(), non_neg_integer()}]
  def fetch_trusted_proxies!(env) do
    name = "TRUSTED_PROXIES"

    case optional_string(env, name) do
      nil -> []
      value -> Enum.map(String.split(value, ",", trim: true), &parse_cidr!(name, &1))
    end
  end

  @doc """
  Parses `LOG_LEVEL`. Unset means `:info`. Unknown values are refused.
  """
  @spec fetch_log_level!(map()) :: Logger.level()
  def fetch_log_level!(env) do
    name = "LOG_LEVEL"

    case optional_string(env, name) do
      nil ->
        :info

      value ->
        parse_log_level!(name, value)
    end
  end

  @doc """
  Returns the default queue concurrency used outside production.
  """
  @spec queue_defaults() :: keyword()
  def queue_defaults, do: @queue_defaults

  defp fetch_limit!(env, name, key) do
    fetch_integer!(env, name,
      default: PumbleAutomation.Limits.default(key),
      min: 1,
      max: PumbleAutomation.Limits.hard_cap(key)
    )
  end

  defp parse_cidr!(name, raw) do
    value = String.trim(raw)

    {address, prefix} =
      case String.split(value, "/", parts: 2) do
        [ip] -> {ip, nil}
        [ip, prefix] -> {ip, prefix}
      end

    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} ->
        {ip, parse_prefix!(name, ip, prefix)}

      {:error, :einval} ->
        raise ArgumentError, invalid_message(name, "comma-separated IPv4 or IPv6 CIDRs")
    end
  end

  defp parse_prefix!(_name, {_, _, _, _}, nil), do: 32
  defp parse_prefix!(_name, {_, _, _, _, _, _, _, _}, nil), do: 128

  defp parse_prefix!(name, ip, raw) do
    max = if tuple_size(ip) == 4, do: 32, else: 128

    case Integer.parse(raw) do
      {prefix, ""} when prefix >= 0 and prefix <= max ->
        prefix

      _other ->
        raise ArgumentError, invalid_message(name, "comma-separated IPv4 or IPv6 CIDRs")
    end
  end

  defp parse_legacy_keys!(name, value) do
    expected =
      "entries of version:base64key separated by commas, each version between 1 and " <>
        "#{@max_encryption_key_version} and each key #{@encryption_key_bytes} Base64 encoded bytes"

    value
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, fn entry, acc ->
      {version, key} = parse_legacy_entry!(name, entry, expected)

      if Map.has_key?(acc, version) do
        raise ArgumentError, invalid_message(name, "one entry per key version")
      end

      Map.put(acc, version, key)
    end)
  end

  defp parse_legacy_entry!(name, entry, expected) do
    with [raw_version, raw_key] <- String.split(String.trim(entry), ":", parts: 2),
         {version, ""} when version in 1..@max_encryption_key_version <-
           Integer.parse(raw_version),
         {:ok, key} <- Base.decode64(String.trim(raw_key), padding: false),
         @encryption_key_bytes <- byte_size(key) do
      {version, key}
    else
      _other -> raise ArgumentError, invalid_message(name, expected)
    end
  end

  defp validate_encryption_keys!(settings) do
    if Map.has_key?(settings.encryption_legacy_keys, settings.encryption_key_version) do
      raise ArgumentError,
            invalid_message(
              "ENCRYPTION_LEGACY_KEYS",
              "versions other than the current ENCRYPTION_KEY_VERSION"
            )
    end

    settings
  end

  defp optional_string(env, name) do
    case Map.get(env, name) do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  defp parse_integer!(name, value, opts) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    case Integer.parse(value) do
      {integer, ""} when is_nil(min) or integer >= min ->
        if is_nil(max) or integer <= max do
          integer
        else
          raise ArgumentError, invalid_message(name, range_description(min, max))
        end

      _other ->
        raise ArgumentError, invalid_message(name, range_description(min, max))
    end
  end

  defp parse_boolean!(name, value) do
    case String.downcase(value) do
      truthy when truthy in ~w(true 1 yes) ->
        true

      falsy when falsy in ~w(false 0 no) ->
        false

      _other ->
        raise ArgumentError, invalid_message(name, "one of: true, false, 1, 0, yes, no")
    end
  end

  @log_levels ~w(emergency alert critical error warning notice info debug)

  defp parse_log_level!(name, value) do
    downcased = String.downcase(value)

    if downcased in @log_levels do
      String.to_existing_atom(downcased)
    else
      raise ArgumentError, invalid_message(name, "one of: " <> Enum.join(@log_levels, ", "))
    end
  end

  defp range_description(nil, nil), do: "an integer"
  defp range_description(min, nil), do: "an integer >= #{min}"
  defp range_description(nil, max), do: "an integer <= #{max}"
  defp range_description(min, max), do: "an integer between #{min} and #{max}"

  defp canonical_url(%URI{scheme: scheme, host: host, port: port}) do
    if port == URI.default_port(scheme) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp missing_message(name) do
    "environment variable #{name} is missing. See .env.example for its purpose and format."
  end

  defp invalid_message(name, expected) do
    "environment variable #{name} is invalid. Expected #{expected}. " <>
      "The value is not shown because it may be a secret."
  end
end
