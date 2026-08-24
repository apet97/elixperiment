defmodule PumbleAutomation.Logging do
  @moduledoc """
  Structured, redacted application logs.

  Operators correlate a run by identifiers: request, installation, workflow,
  version, execution, step, attempt, and job. They do not need the content
  that produced the run. This module is the only place a domain event becomes
  a log line, and it redacts before it formats.

  Production writes one JSON object per line (`docs/operations/logging.md`).
  Dev and test keep Elixir's text formatter so existing captures stay
  readable. `LOG_LEVEL` selects the production level without a code change.

  ## Failure behaviour

  `event/3` never raises into a caller. A formatter crash is replaced with a
  JSON object that contains no original payload. Redaction failure becomes
  `"[REDACTED]"`, never the raw value.

  ## Diagnostic mode

  A tenant-authorized, time-bounded window may add content hashes and byte
  lengths. It never adds bodies, message text, rendered templates, or
  tokens. The window lives in ETS and expires by itself.
  """

  require Logger

  @levels [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]
  @redacted "[REDACTED]"
  @table :pumble_automation_log_diagnostics
  @default_ttl_seconds 900
  @max_ttl_seconds 3_600
  @handler_id "pumble-automation-structured-logs"

  @fields ~w(
    request_id correlation_id provider_id installation_id workflow_id version_id
    execution_id step_id attempt_id job_id operation duration_ms status
    error_code error_class event_type content_bytes content_sha256
  )a

  @aliases %{
    workflow_version_id: :version_id,
    pumble_provider_id: :provider_id,
    workflow_version: :version_id
  }

  @secret_key_pattern ~r/(token|secret|code|password|passwd|credential|api[_-]?key|signature|cookie|authorization|bearer)/i
  @content_key_pattern ~r/\A(body|payload|content|raw|template|rendered|text|message|private)\z/i

  @secret_headers MapSet.new([
                    "authorization",
                    "cookie",
                    "set-cookie",
                    "token",
                    "x-app-token",
                    "x-csrf-token",
                    "x-webhook-token",
                    "x-pumble-request-signature"
                  ])

  @telemetry_events [
    [:pumble_automation, :pumble, :callback, :stop],
    [:pumble_automation, :executions, :pumble_action],
    [:pumble_automation, :pumble, :client, :stop],
    [:pumble_automation, :executions, :http_action],
    [:phoenix, :router_dispatch, :exception]
  ]

  @doc "Identifier keys that a structured log line may carry."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "Creates the diagnostic ETS table. Safe to call more than once."
  @spec setup() :: :ok
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        _table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  end

  @doc "Attaches telemetry handlers that emit structured log lines."
  @spec attach() :: :ok
  def attach do
    setup()
    _ = :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, @telemetry_events, &__MODULE__.handle_event/4, %{})
    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    event(level_for(event), message_for(event), fields_for(event, measurements, metadata))
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Writes one structured log line.

  `fields` is reduced to the allowlist and redacted before Logger sees it.
  Logger errors are swallowed so a full disk cannot fail a callback or job.
  """
  @spec event(Logger.level(), String.t(), map()) :: :ok
  def event(level, message, fields \\ %{})

  def event(level, message, fields)
      when level in @levels and is_binary(message) and is_map(fields) do
    safe = prepare(fields)
    Logger.log(level, message, metadata_keyword(safe))
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def event(_level, _message, _fields), do: :ok

  @doc "Merges allowlisted correlation fields onto the current process."
  @spec attach_context(map()) :: :ok
  def attach_context(fields) when is_map(fields) do
    Logger.metadata(metadata_keyword(prepare(fields)))
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def attach_context(_fields), do: :ok

  @doc "Clears correlation metadata this module may have set."
  @spec clear_context() :: :ok
  def clear_context do
    Enum.each(@fields, fn key -> Logger.metadata([{key, nil}]) end)
    :ok
  rescue
    _exception -> :ok
  end

  @doc """
  Enables hashed diagnostic fields for `installation_id`.

  Requires `:authorized_by` (a tenant actor id). `:ttl_seconds` defaults to
  15 minutes and cannot exceed one hour. `:sample_rate` is 0.0..1.0.
  """
  @spec enable_diagnostics(Ecto.UUID.t(), keyword()) :: :ok | {:error, :unauthorized}
  def enable_diagnostics(installation_id, opts \\ []) when is_binary(installation_id) do
    setup()

    case Keyword.get(opts, :authorized_by) do
      actor when is_binary(actor) and actor != "" ->
        ttl = ttl_seconds(opts)
        expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
        sample_rate = sample_rate(opts)
        :ets.insert(@table, {installation_id, expires_at, sample_rate, actor})
        :ok

      _missing ->
        {:error, :unauthorized}
    end
  end

  @doc "Turns diagnostic mode off for `installation_id`."
  @spec disable_diagnostics(Ecto.UUID.t()) :: :ok
  def disable_diagnostics(installation_id) when is_binary(installation_id) do
    setup()
    true = :ets.delete(@table, installation_id)
    :ok
  end

  @doc "Whether diagnostic hashes may be emitted for this tenant right now."
  @spec diagnostics_enabled?(Ecto.UUID.t() | nil) :: boolean()
  def diagnostics_enabled?(installation_id) when is_binary(installation_id) do
    setup()

    case :ets.lookup(@table, installation_id) do
      [{^installation_id, expires_at, sample_rate, _actor}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          :rand.uniform() <= sample_rate
        else
          _ = :ets.delete(@table, installation_id)
          false
        end

      [] ->
        false
    end
  rescue
    _exception -> false
  end

  def diagnostics_enabled?(_installation_id), do: false

  @doc """
  Replaces secret and private values before anything is formatted.

  Walks maps, lists, and two-element tuples. On any failure the whole term
  becomes `"[REDACTED]"` so a broken walker cannot leak the input.
  """
  @spec redact(term()) :: term()
  def redact(term) do
    do_redact(term)
  rescue
    _exception -> @redacted
  catch
    _kind, _reason -> @redacted
  end

  @doc "Redacts secret header values. Unknown headers keep only their names."
  @spec filter_headers(term()) :: [{String.t(), String.t()}]
  def filter_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {name, _value} ->
        header = header_name(name)

        if secret_header?(header) do
          {header, @redacted}
        else
          {header, "[present]"}
        end

      _other ->
        {"unknown", @redacted}
    end)
  rescue
    _exception -> []
  end

  def filter_headers(_headers), do: []

  @doc "SHA-256 digest and byte length of `value`. Never returns the value."
  @spec fingerprint(term()) :: %{bytes: non_neg_integer(), sha256: String.t()}
  def fingerprint(value) when is_binary(value) do
    %{
      bytes: byte_size(value),
      sha256: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
    }
  end

  def fingerprint(value) do
    encoded = inspect(value, limit: 256, printable_limit: 256)
    fingerprint(encoded)
  end

  @doc false
  @spec check_config(term()) :: :ok | {:error, term()}
  def check_config(config) when is_map(config), do: :ok
  def check_config(config) when is_list(config), do: :ok
  def check_config(_config), do: {:error, :invalid_formatter_config}

  @doc false
  @spec format(map(), term()) :: iodata()
  def format(log_event, _config) when is_map(log_event) do
    log_event
    |> json_payload()
    |> Jason.encode!()
    |> then(&[&1, ?\n])
  rescue
    _exception -> ~s({"level":"error","msg":"[REDACTED]","error_code":"log_format_failed"}\n)
  catch
    _kind, _reason -> ~s({"level":"error","msg":"[REDACTED]","error_code":"log_format_failed"}\n)
  end

  def format(_log_event, _config) do
    ~s({"level":"error","msg":"[REDACTED]","error_code":"log_format_failed"}\n)
  end

  defp prepare(fields) when is_map(fields) do
    diagnostics = Map.get(fields, :diagnostics) || Map.get(fields, "diagnostics")
    installation_id = field_value(fields, :installation_id)

    fields
    |> Map.drop([:diagnostics, "diagnostics"])
    |> take_fields()
    |> maybe_fingerprint(installation_id, diagnostics)
    |> redact()
    |> stringify_values()
  end

  defp take_fields(fields) do
    Enum.reduce(fields, %{}, fn {key, value}, acc ->
      case canonical_key(key) do
        nil -> acc
        field -> Map.put(acc, field, value)
      end
    end)
  end

  defp canonical_key(key) when is_atom(key) do
    cond do
      key in @fields -> key
      Map.has_key?(@aliases, key) -> Map.fetch!(@aliases, key)
      true -> nil
    end
  end

  defp canonical_key(key) when is_binary(key) do
    cond do
      Enum.any?(@fields, &(Atom.to_string(&1) == key)) -> String.to_existing_atom(key)
      Map.has_key?(@aliases, extra_alias(key)) -> Map.fetch!(@aliases, extra_alias(key))
      true -> nil
    end
  end

  defp canonical_key(_key), do: nil

  defp extra_alias("workflow_version_id"), do: :workflow_version_id
  defp extra_alias("pumble_provider_id"), do: :pumble_provider_id
  defp extra_alias(_key), do: nil

  defp field_value(fields, key) do
    Map.get(fields, key) || Map.get(fields, Atom.to_string(key))
  end

  defp maybe_fingerprint(fields, installation_id, diagnostics)
       when not is_nil(diagnostics) do
    if diagnostics_enabled?(installation_id) do
      digest = fingerprint(diagnostics)

      fields
      |> Map.put(:content_bytes, digest.bytes)
      |> Map.put(:content_sha256, digest.sha256)
    else
      fields
    end
  end

  defp maybe_fingerprint(fields, _installation_id, _diagnostics), do: fields

  defp stringify_values(fields) when is_map(fields) do
    Map.new(fields, fn
      {key, value} when key in [:duration_ms, :content_bytes] and is_integer(value) ->
        {key, value}

      {key, value} ->
        {key, stringify(value)}
    end)
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: Float.to_string(value)
  defp stringify(value), do: inspect(value, limit: 32, printable_limit: 64)

  defp metadata_keyword(fields) do
    fields
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.new()
  end

  defp do_redact(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} ->
      if canonical_key(key) in @fields do
        {key, do_redact(nested)}
      else
        redact_entry(key, nested)
      end
    end)
  end

  defp do_redact(value) when is_list(value), do: Enum.map(value, &do_redact/1)
  defp do_redact({key, value}), do: redact_entry(key, value)
  defp do_redact(value), do: value

  defp redact_entry(key, value) do
    if denied_key?(key) do
      {key, @redacted}
    else
      {key, do_redact(value)}
    end
  end

  defp denied_key?(key) when is_atom(key), do: key |> Atom.to_string() |> denied_key?()

  defp denied_key?(key) when is_binary(key) do
    Regex.match?(@secret_key_pattern, key) or Regex.match?(@content_key_pattern, key)
  end

  defp denied_key?(_key), do: false

  defp secret_header?(name), do: MapSet.member?(@secret_headers, String.downcase(name))

  defp header_name(name) when is_atom(name), do: Atom.to_string(name)
  defp header_name(name) when is_binary(name), do: name
  defp header_name(name), do: inspect(name)

  defp ttl_seconds(opts) do
    requested = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    max = @max_ttl_seconds

    cond do
      not is_integer(requested) -> @default_ttl_seconds
      requested < 1 -> 1
      requested > max -> max
      true -> requested
    end
  end

  defp sample_rate(opts) do
    case Keyword.get(opts, :sample_rate, 1.0) do
      rate when is_number(rate) and rate >= 0 and rate <= 1 -> rate / 1
      _other -> 1.0
    end
  end

  defp json_payload(log_event) do
    meta = Map.get(log_event, :meta) || %{}

    %{
      "ts" => timestamp(meta),
      "level" => level_name(Map.get(log_event, :level)),
      "msg" => redact_message(message_text(Map.get(log_event, :msg)))
    }
    |> Map.merge(json_fields(meta))
    |> drop_nils()
  end

  defp json_fields(meta) when is_map(meta) do
    Enum.reduce(@fields, %{}, fn field, acc ->
      case Map.get(meta, field) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(field), json_value(field, value))
      end
    end)
  end

  defp json_fields(_meta), do: %{}

  defp json_value(field, value)
       when field in [:duration_ms, :content_bytes] and is_integer(value),
       do: value

  defp json_value(_field, value), do: stringify(redact(value))

  defp message_text({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp message_text({:report, report}), do: inspect(redact(report), limit: 32)
  defp message_text({format, args}) when is_binary(format) and is_list(args), do: "report"
  defp message_text(text) when is_binary(text), do: text
  defp message_text(chardata) when is_list(chardata), do: IO.chardata_to_string(chardata)
  defp message_text(_other), do: "log"

  defp redact_message(message) when is_binary(message) do
    if String.contains?(message, ["Bearer ", "token=", "secret="]) do
      @redacted
    else
      message
    end
  end

  defp timestamp(%{time: time}) when is_integer(time) do
    time
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  rescue
    _exception -> DateTime.to_iso8601(DateTime.utc_now())
  end

  defp timestamp(_meta), do: DateTime.to_iso8601(DateTime.utc_now())

  defp level_name(level) when is_atom(level), do: Atom.to_string(level)
  defp level_name(_level), do: "info"

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp level_for([:phoenix, :router_dispatch, :exception]), do: :error
  defp level_for(_event), do: :info

  defp message_for([:pumble_automation, :pumble, :callback, :stop]), do: "pumble.callback"
  defp message_for([:pumble_automation, :executions, :pumble_action]), do: "pumble.action"
  defp message_for([:pumble_automation, :pumble, :client, :stop]), do: "pumble.client"
  defp message_for([:pumble_automation, :executions, :http_action]), do: "http.action"
  defp message_for([:phoenix, :router_dispatch, :exception]), do: "exception"
  defp message_for(_event), do: "event"

  defp fields_for([:phoenix, :router_dispatch, :exception], measurements, metadata) do
    %{
      operation: "exception",
      event_type: "exception",
      status: "error",
      error_class: "internal",
      error_code: exception_code(metadata),
      duration_ms: duration_ms(measurements),
      request_id: request_id(metadata)
    }
  end

  defp fields_for(_event, measurements, metadata) when is_map(metadata) do
    metadata
    |> Map.take([
      :operation,
      :installation_id,
      :workflow_id,
      :workflow_version_id,
      :execution_id,
      :step_id,
      :attempt_id,
      :job_id,
      :status,
      :outcome,
      :error_code,
      :error_class,
      :class,
      :provider_request_id,
      :correlation_id,
      :run_mode,
      :duration_ms
    ])
    |> Map.put(:duration_ms, metadata[:duration_ms] || duration_ms(measurements))
    |> Map.put(:event_type, event_type(metadata))
    |> Map.put(:status, metadata[:status] || metadata[:outcome])
    |> Map.put(:error_code, metadata[:error_code] || metadata[:error_class])
    |> Map.put(:provider_id, metadata[:provider_request_id] || metadata[:provider_id])
    |> Map.put(:request_id, metadata[:request_id] || metadata[:correlation_id])
  end

  defp fields_for(_event, _measurements, _metadata), do: %{}

  defp event_type(%{class: class}) when not is_nil(class), do: class
  defp event_type(%{event_type: type}) when not is_nil(type), do: type
  defp event_type(%{operation: operation}) when not is_nil(operation), do: operation
  defp event_type(_metadata), do: nil

  defp duration_ms(%{duration: duration}) when is_integer(duration) do
    System.convert_time_unit(duration, :native, :millisecond)
  end

  defp duration_ms(%{duration_ms: ms}) when is_integer(ms), do: ms
  defp duration_ms(_measurements), do: nil

  defp request_id(%{conn: %{assigns: %{request_id: id}}}) when is_binary(id), do: id
  defp request_id(%{request_id: id}) when is_binary(id), do: id
  defp request_id(_metadata), do: nil

  defp exception_code(%{reason: %{__struct__: module}}) do
    module |> Module.split() |> List.last()
  end

  defp exception_code(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp exception_code(_metadata), do: "exception"
end
