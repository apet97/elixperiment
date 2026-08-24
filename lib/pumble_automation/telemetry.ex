defmodule PumbleAutomation.Telemetry do
  @moduledoc """
  Domain telemetry events and the low-cardinality metric adapter.

  Execution paths emit `:telemetry.execute/3`. This module names those events,
  maps them onto `Telemetry.Metrics` specs, and strips identifiers before a
  metric dimension is recorded. IDs stay on the raw event for logs and traces.

  Phoenix, Ecto, and Oban events are reused as-is. There is no vendor metrics
  SDK. A handler crash is isolated and never fails the caller.
  """

  import Ecto.Query, only: [from: 2]
  import Telemetry.Metrics

  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.Schedule

  @handler_id "pumble-automation-metrics"

  @tag_keys MapSet.new([
              :check,
              :class,
              :error_class,
              :event_type,
              :from,
              :kind,
              :operation,
              :outcome,
              :queue,
              :source,
              :status,
              :status_class,
              :type
            ])

  @id_keys MapSet.new([
             :approval_id,
             :attempt_id,
             :binding_id,
             :correlation_id,
             :effect_key,
             :execution_id,
             :installation_id,
             :job,
             :job_id,
             :member_id,
             :node_id,
             :provider_id,
             :provider_request_id,
             :public_action_id,
             :received_event_id,
             :request_id,
             :root_execution_id,
             :step_id,
             :user_id,
             :version_id,
             :workflow_id,
             :workflow_version_id,
             :workspace_id
           ])

  @events %{
    callback_stop: [:pumble_automation, :pumble, :callback, :stop],
    callback_verify: [:pumble_automation, :pumble, :callback, :verify],
    dedup_record: [:pumble_automation, :ingress, :dedup, :record],
    matcher_match: [:pumble_automation, :ingress, :matcher, :match],
    step_stop: [:pumble_automation, :executions, :step, :stop],
    execution_stop: [:pumble_automation, :executions, :stop],
    transition: [:pumble_automation, :executions, :transition],
    retry: [:pumble_automation, :executions, :retry],
    uncertain: [:pumble_automation, :executions, :uncertain],
    approval_stop: [:pumble_automation, :executions, :approval, :stop],
    pumble_client_stop: [:pumble_automation, :pumble, :client, :stop],
    http_action: [:pumble_automation, :executions, :http_action],
    queue_snapshot: [:pumble_automation, :oban, :queue],
    schedule_dispatch: [:pumble_automation, :schedule, :dispatch],
    schedule_lag: [:pumble_automation, :schedule, :lag],
    reconcile: [:pumble_automation, :executions, :reconcile],
    retention_sweep: [:pumble_automation, :retention, :sweep],
    retention_purge: [:pumble_automation, :retention, :purge],
    limits_hit: [:pumble_automation, :limits, :hit],
    maintenance_run: [:pumble_automation, :maintenance, :run],
    maintenance_alert: [:pumble_automation, :maintenance, :alert]
  }

  @doc "Stable event names keyed by the metric they feed."
  @spec events() :: %{atom() => [atom()]}
  def events, do: @events

  @doc "Keys allowed as metric dimensions. Identifiers are never in this set."
  @spec tag_keys() :: MapSet.t(atom())
  def tag_keys, do: @tag_keys

  @doc "Identifier keys that stay on events and logs, never on metric series."
  @spec id_keys() :: MapSet.t(atom())
  def id_keys, do: @id_keys

  @doc """
  Section 32 metrics mapped to a source event.

  Every row has an event name. Nothing is deferred: queue depth and schedule
  lag are polled here; readiness probes already emit health events.
  """
  @spec section32() :: [map()]
  def section32 do
    [
      %{name: "callback count/latency/status", event: :callback_stop, measurement: :duration},
      %{name: "signature failures", event: :callback_verify, measurement: :count},
      %{name: "dedupe hits", event: :dedup_record, measurement: :count},
      %{name: "execution counts by state", event: :transition, measurement: :count},
      %{name: "step latency by type", event: :step_stop, measurement: :duration_ms},
      %{name: "retries", event: :retry, measurement: :count},
      %{name: "uncertain outcomes", event: :uncertain, measurement: :count},
      %{name: "Pumble API status/latency", event: :pumble_client_stop, measurement: :duration},
      %{name: "external HTTP status/latency", event: :http_action, measurement: :duration},
      %{name: "queue depth and age", event: :queue_snapshot, measurement: :depth},
      %{name: "schedule lag", event: :schedule_lag, measurement: :lag_ms},
      %{name: "expired approvals", event: :approval_stop, measurement: :duration_ms},
      %{name: "per-workspace limit rejections", event: :limits_hit, measurement: :count}
    ]
  end

  @doc "Attaches the isolated metric adapter. Safe to call more than once."
  @spec attach() :: :ok
  def attach do
    _ = :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, watched_events(), &__MODULE__.handle_event/4, %{})
    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(_event, _measurements, metadata, _config) do
    _tags = metric_tags(metadata)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Emits one telemetry event.

  Failures are swallowed so a broken reporter cannot fail a callback or job.
  """
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, metadata)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def execute(_event, _measurements, _metadata), do: :ok

  @doc """
  Low-cardinality tags for a metric reporter.

  Drops identifiers, job structs, and secret-looking keys. HTTP status codes
  become `status_class` (`2xx` / `4xx` / `5xx` / `ok` / `error`).
  """
  @spec metric_tags(map()) :: map()
  def metric_tags(metadata) when is_map(metadata) do
    metadata
    |> flatten_oban()
    |> put_status_class()
    |> default_error_class()
    |> Map.drop(MapSet.to_list(@id_keys))
    |> Map.take(MapSet.to_list(@tag_keys))
    |> stringify_tags()
  rescue
    _exception -> %{}
  catch
    _kind, _reason -> %{}
  end

  def metric_tags(_metadata), do: %{}

  @doc "Buckets an HTTP or outcome status into a bounded class."
  @spec status_class(term()) :: String.t()
  def status_class(status) when is_integer(status) and status in 200..299, do: "2xx"
  def status_class(status) when is_integer(status) and status in 400..499, do: "4xx"
  def status_class(status) when is_integer(status) and status in 500..599, do: "5xx"
  def status_class(:ok), do: "ok"
  def status_class("ok"), do: "ok"
  def status_class(status) when is_atom(status), do: Atom.to_string(status)
  def status_class(status) when is_binary(status), do: status
  def status_class(_status), do: "error"

  @doc "Telemetry.Metrics specs consumed by LiveDashboard and reporters."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      summary("pumble_automation.pumble.callback.stop.duration",
        tags: [:class, :outcome, :status_class],
        tag_values: &metric_tags/1,
        unit: {:native, :millisecond},
        description: "Pumble callback handling time"
      ),
      counter("pumble_automation.pumble.callback.verify.count",
        tags: [:status],
        tag_values: &metric_tags/1,
        description: "Callback signature verification outcomes"
      ),
      counter("pumble_automation.ingress.dedup.record.count",
        event_name: @events.dedup_record,
        tags: [:outcome, :class],
        tag_values: &metric_tags/1,
        description: "New versus duplicate received events"
      ),
      sum("pumble_automation.ingress.matcher.match.count",
        event_name: @events.matcher_match,
        tags: [:kind, :type],
        tag_values: &metric_tags/1,
        description: "Live trigger matches per inbound event"
      ),
      summary("pumble_automation.executions.step.stop.duration_ms",
        tags: [:type, :status, :kind, :error_class],
        tag_values: &metric_tags/1,
        unit: :millisecond,
        description: "Step attempt duration by node type"
      ),
      summary("pumble_automation.executions.stop.duration_ms",
        tags: [:status],
        tag_values: &metric_tags/1,
        unit: :millisecond,
        description: "Terminal execution duration"
      ),
      counter("pumble_automation.executions.transition.count",
        event_name: @events.transition,
        tags: [:from, :status, :operation],
        tag_values: &metric_tags/1,
        description: "Execution state transitions"
      ),
      counter("pumble_automation.executions.retry.count",
        event_name: @events.retry,
        tags: [:type, :error_class],
        tag_values: &metric_tags/1,
        description: "Engine-owned step retries"
      ),
      counter("pumble_automation.executions.uncertain.count",
        event_name: @events.uncertain,
        tags: [:type, :error_class],
        tag_values: &metric_tags/1,
        description: "Uncertain-effect pauses"
      ),
      summary("pumble_automation.executions.approval.stop.duration_ms",
        tags: [:status, :type],
        tag_values: &metric_tags/1,
        unit: :millisecond,
        description: "Time from approval request to decision or expiry"
      ),
      summary("pumble_automation.pumble.client.stop.duration",
        tags: [:operation, :status_class, :error_class],
        tag_values: &metric_tags/1,
        unit: {:native, :millisecond},
        description: "Pumble API call latency"
      ),
      summary("pumble_automation.executions.http_action.duration",
        tags: [:operation, :status, :error_class],
        tag_values: &metric_tags/1,
        unit: {:native, :millisecond},
        description: "Outbound HTTP action latency"
      ),
      last_value("pumble_automation.oban.queue.depth",
        event_name: @events.queue_snapshot,
        tags: [:queue],
        tag_values: &metric_tags/1,
        description: "Incomplete Oban jobs in one queue"
      ),
      last_value("pumble_automation.oban.queue.age_ms",
        event_name: @events.queue_snapshot,
        tags: [:queue],
        tag_values: &metric_tags/1,
        unit: :millisecond,
        description: "Age of the oldest incomplete job in one queue"
      ),
      summary("oban.job.stop.duration",
        tags: [:queue, :status],
        tag_values: &metric_tags/1,
        unit: {:native, :millisecond},
        description: "Oban job run time"
      ),
      summary("pumble_automation.schedule.dispatch.lag_ms",
        tags: [:outcome],
        tag_values: &metric_tags/1,
        unit: :millisecond,
        description: "Lag when a due schedule is dispatched"
      ),
      last_value("pumble_automation.schedule.lag.lag_ms",
        event_name: @events.schedule_lag,
        tags: [:operation],
        tag_values: &metric_tags/1,
        unit: :millisecond,
        description: "Oldest enabled schedule that is already due"
      ),
      counter("pumble_automation.executions.reconcile.count",
        event_name: @events.reconcile,
        tags: [:status],
        tag_values: &metric_tags/1,
        description: "Reconciliation runs"
      ),
      sum("pumble_automation.retention.sweep.tenant_rows",
        event_name: @events.retention_sweep,
        tags: [:source],
        tag_values: &metric_tags/1,
        description: "Rows removed by a retention sweep"
      ),
      sum("pumble_automation.retention.purge.tenant_rows",
        event_name: @events.retention_purge,
        tags: [:source],
        tag_values: &metric_tags/1,
        description: "Rows removed by a tenant purge"
      ),
      counter("pumble_automation.limits.hit.count",
        event_name: @events.limits_hit,
        tags: [:source],
        tag_values: &metric_tags/1,
        description: "Resource and rate-limit rejections"
      ),
      counter("pumble_automation.maintenance.run.count",
        event_name: @events.maintenance_run,
        tags: [:kind, :status],
        tag_values: &metric_tags/1,
        description: "Scheduled maintenance ticks"
      ),
      counter("pumble_automation.maintenance.alert.count",
        event_name: @events.maintenance_alert,
        tags: [:kind, :status],
        tag_values: &metric_tags/1,
        description: "Unsafe maintenance anomalies that were not auto-repaired"
      )
    ]
  end

  @doc """
  Polls queue depth/age and due-schedule lag.

  Called by `telemetry_poller`. A query failure emits nothing.
  """
  @spec dispatch_queue_snapshot() :: :ok
  def dispatch_queue_snapshot do
    now = DateTime.utc_now()
    Enum.each(queue_names(), &emit_queue(&1, now))
    emit_schedule_lag(now)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp watched_events do
    @events
    |> Map.values()
    |> Enum.uniq()
  end

  defp flatten_oban(%{job: job} = metadata) when is_map(job) or is_struct(job) do
    metadata
    |> Map.put(:queue, Map.get(job, :queue))
    |> Map.put(:status, Map.get(metadata, :state) || Map.get(job, :state))
    |> Map.delete(:job)
  end

  defp flatten_oban(metadata), do: metadata

  defp put_status_class(metadata) do
    case Map.get(metadata, :status) do
      status when is_integer(status) ->
        metadata
        |> Map.put(:status_class, status_class(status))
        |> Map.delete(:status)

      status when status in [:ok, :error] ->
        Map.put(metadata, :status_class, status_class(status))

      _other ->
        metadata
    end
  end

  defp default_error_class(metadata) do
    case Map.get(metadata, :error_class) do
      nil -> Map.put(metadata, :error_class, "none")
      class -> Map.put(metadata, :error_class, class)
    end
  end

  defp stringify_tags(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      case stringify_tag(value) do
        nil -> acc
        text -> Map.put(acc, key, text)
      end
    end)
  end

  defp stringify_tag(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_tag(value) when is_binary(value), do: value
  defp stringify_tag(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_tag(_value), do: nil

  defp queue_names do
    :pumble_automation
    |> Application.get_env(:queue_concurrency, [])
    |> Keyword.keys()
    |> Enum.map(&Atom.to_string/1)
  end

  defp emit_queue(queue, now) do
    {depth, oldest} = queue_stats(queue)

    execute(
      @events.queue_snapshot,
      %{depth: depth, age_ms: age_ms(oldest, now)},
      %{queue: queue, operation: "queue"}
    )
  end

  defp queue_stats(queue) do
    query =
      from job in Oban.Job,
        where: job.queue == ^queue and job.state in ^Concurrency.incomplete_job_states(),
        select: {count(job.id), min(job.scheduled_at)}

    case Repo.one(query) do
      {depth, oldest} -> {depth, oldest}
      nil -> {0, nil}
    end
  end

  defp emit_schedule_lag(now) do
    query =
      from schedule in Schedule,
        where:
          schedule.enabled and not is_nil(schedule.next_run_at) and schedule.next_run_at <= ^now,
        select: {count(schedule.id), min(schedule.next_run_at)}

    {due_count, oldest} =
      case Repo.one(query) do
        {count, oldest} -> {count, oldest}
        nil -> {0, nil}
      end

    execute(
      @events.schedule_lag,
      %{lag_ms: age_ms(oldest, now), due_count: due_count},
      %{operation: "schedule_lag"}
    )
  end

  defp age_ms(nil, _now), do: 0

  defp age_ms(%DateTime{} = instant, now) do
    max(0, DateTime.diff(now, instant, :millisecond))
  end
end
