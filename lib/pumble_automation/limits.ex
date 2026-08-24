defmodule PumbleAutomation.Limits do
  @moduledoc """
  Section 31 resource limits, with typed runtime overrides and hard caps.

  Every number that bounds a workflow, a run, or an inbound body lives here
  once. Owner modules read through `get/1`; they do not keep a second copy
  of the default. Production may lower a value, or raise it up to the hard
  cap, through `PumbleAutomation.Config.fetch_limits!/1`. Crossing a hard
  cap requires an ADR.

  ## Owners

  | Limit | Owner |
  |---|---|
  | nodes, depth, definition, templates | `Workflows.Limits` / validator |
  | active / total workflows | `Workflows` / `Activation` |
  | schedules per workspace | `Activation` |
  | running executions | `Executions.Concurrency` |
  | queued executions | `Executions.Engine` |
  | context / lineage | `Executions.Execution` / `Executions.Lineage` |
  | HTTP bodies / redirects | `Connections.SafeHttp` |
  | retries | `Executions.RetryPolicy` |
  | delay / approval wait | `Node.DelayConfig` / `ApprovalConfig` |
  | execution lifetime | `Executions.Engine` |
  | callback / webhook bodies | `CacheRawBody` / `WebhookService` |
  | history pages | `Executions.History` |

  Limit hits emit `[:pumble_automation, :limits, :hit]` with a source and
  optional installation id. The event never carries a payload, body, or IP.
  """

  alias PumbleAutomation.Executions.Execution

  @telemetry_event [:pumble_automation, :limits, :hit]

  @day_seconds 24 * 60 * 60

  @defaults %{
    workflow_nodes: 50,
    branch_depth: 8,
    definition_size_bytes: 256 * 1024,
    active_workflows: 25,
    total_workflows: 100,
    schedules_per_workspace: 100,
    running_executions: 5,
    queued_executions: 1_000,
    context_size_bytes: 256 * 1024,
    template_source_bytes: 16 * 1024,
    template_expansion_bytes: 64 * 1024,
    pumble_callback_body_bytes: 1_048_576,
    generic_webhook_body_bytes: 512 * 1024,
    http_request_body_bytes: 256 * 1024,
    http_response_body_bytes: 1_048_576,
    redirects: 3,
    retries: 5,
    delay_seconds: 365 * @day_seconds,
    execution_lifetime_seconds: 30 * @day_seconds,
    lineage_depth: 3,
    lineage_descendants: 8,
    history_page_size: 20,
    history_page_max: 50,
    callback_failures_per_minute: 30,
    manual_runs_per_minute: 20,
    expensive_ui_per_minute: 30,
    max_request_body_bytes: 1_048_576,
    outbound_http_timeout_ms: 10_000
  }

  @hard_caps %{
    workflow_nodes: 100,
    branch_depth: 16,
    definition_size_bytes: 1_048_576,
    active_workflows: 100,
    total_workflows: 400,
    schedules_per_workspace: 400,
    running_executions: 20,
    queued_executions: 4_000,
    context_size_bytes: 1_048_576,
    template_source_bytes: 64 * 1024,
    template_expansion_bytes: 256 * 1024,
    pumble_callback_body_bytes: 10_485_760,
    generic_webhook_body_bytes: 2_097_152,
    http_request_body_bytes: 1_048_576,
    http_response_body_bytes: 4_194_304,
    redirects: 3,
    retries: 5,
    delay_seconds: 365 * @day_seconds,
    execution_lifetime_seconds: 30 * @day_seconds,
    lineage_depth: 3,
    lineage_descendants: 32,
    history_page_size: 100,
    history_page_max: 200,
    callback_failures_per_minute: 300,
    manual_runs_per_minute: 120,
    expensive_ui_per_minute: 120,
    max_request_body_bytes: 10_485_760,
    outbound_http_timeout_ms: 120_000
  }

  @type key :: atom()

  @doc "Section 31 defaults plus operational rate and history bounds."
  @spec defaults() :: %{optional(key()) => pos_integer()}
  def defaults, do: @defaults

  @doc "Hard safety caps. Runtime overrides cannot exceed these."
  @spec hard_caps() :: %{optional(key()) => pos_integer()}
  def hard_caps, do: @hard_caps

  @doc "Configured keys this module understands."
  @spec keys() :: [key()]
  def keys, do: @defaults |> Map.keys() |> Enum.sort()

  @doc "The Section 31 (or operational) default for `key`."
  @spec default(key()) :: pos_integer()
  def default(key) when is_atom(key), do: Map.fetch!(@defaults, key)

  @doc "The hard cap for `key`."
  @spec hard_cap(key()) :: pos_integer()
  def hard_cap(key) when is_atom(key), do: Map.fetch!(@hard_caps, key)

  @doc """
  The effective limit for `key`.

  Reads `:pumble_automation, :limits`, falls back to the Section 31 default,
  and clamps to the hard cap. Unknown or non-positive configured values use
  the default.
  """
  @spec get(key()) :: pos_integer()
  def get(key) when is_atom(key) do
    clamp(key, configured_value(key))
  end

  @doc "Telemetry event for a refused over-limit action."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Records one limit hit.

  `source` is a stable atom. `installation_id` is optional and is the only
  tenant dimension; nothing about the request body is accepted.
  """
  @spec record_hit(atom(), Ecto.UUID.t() | nil) :: :ok
  def record_hit(source, installation_id \\ nil) when is_atom(source) do
    metadata =
      %{source: Atom.to_string(source)}
      |> maybe_put(:installation_id, installation_id)

    :telemetry.execute(@telemetry_event, %{count: 1}, metadata)
    :ok
  end

  @doc "Configured trusted proxy CIDRs. Empty means forwarding headers are ignored."
  @spec trusted_proxies() :: [{tuple(), non_neg_integer()}]
  def trusted_proxies do
    Application.get_env(:pumble_automation, :trusted_proxies, [])
  end

  @doc "Whether `execution` has outlived the Section 31 lifetime."
  @spec execution_expired?(term()) :: boolean()
  def execution_expired?(%Execution{inserted_at: inserted_at}), do: expired_at?(inserted_at)
  def execution_expired?(%{started_at: started_at}), do: expired_at?(started_at)
  def execution_expired?(%{inserted_at: inserted_at}), do: expired_at?(inserted_at)
  def execution_expired?(_other), do: false

  @doc "The instant an execution started at `started_at` must finish by."
  @spec deadline(DateTime.t()) :: DateTime.t()
  def deadline(%DateTime{} = started_at) do
    DateTime.add(started_at, get(:execution_lifetime_seconds), :second)
  end

  @doc "Convenience: delay / approval wait ceiling in seconds."
  @spec delay_seconds() :: pos_integer()
  def delay_seconds, do: get(:delay_seconds)

  defp expired_at?(%DateTime{} = started_at) do
    DateTime.compare(DateTime.utc_now(), deadline(started_at)) != :lt
  end

  defp expired_at?(_other), do: false

  defp configured_value(:pumble_callback_body_bytes) do
    cfg = configured()

    Map.get(cfg, :pumble_callback_body_bytes) ||
      Map.get(cfg, :max_request_body_bytes) ||
      Map.fetch!(@defaults, :pumble_callback_body_bytes)
  end

  defp configured_value(key) do
    Map.get(configured(), key, Map.fetch!(@defaults, key))
  end

  defp configured do
    case Application.get_env(:pumble_automation, :limits, %{}) do
      map when is_map(map) -> map
      _other -> %{}
    end
  end

  defp clamp(key, value) when is_integer(value) and value > 0 do
    value
    |> max(1)
    |> min(Map.fetch!(@hard_caps, key))
  end

  defp clamp(key, _value), do: Map.fetch!(@defaults, key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
