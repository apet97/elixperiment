defmodule PumbleAutomation.Executions.History do
  @moduledoc """
  Tenant-scoped execution summaries and sanitized timelines for operators.

  The LiveViews read through this module. They never select execution
  context, trigger snapshots, raw step output maps, unrestricted attempt
  diagnostics, or approval tokens. A fixed allowlist of sanitized attempt
  facts is exposed so an operator can resolve uncertain outcomes safely.
  Dangerous writes still go through
  `PumbleAutomation.Executions.Engine`.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @attempt_diagnostic_keys ~w(
    kind message error_class effect_key attempt operation request_summary retry_at
    dispatch_state dispatched bytes_may_have_left duplicate_risk guidance
  )
  @max_diagnostic_value_bytes 512

  @max_workflow_options 200

  @doc "The default page size for execution index queries."
  @spec page_size() :: pos_integer()
  def page_size, do: Limits.get(:history_page_size)

  @doc """
  One page of execution summaries, newest first, with a cursor for the next page.

  Options: `:limit`, `:cursor`, `:workflow_id`, `:status`, `:from`, `:until`.
  The query never selects `context` or `trigger_snapshot`.
  """
  @spec list_index(Scope.t(), keyword()) ::
          {:ok, %{entries: [map()], next_cursor: String.t() | nil}} | {:error, Error.t()}
  def list_index(%Scope{} = scope, opts \\ []) do
    with :ok <- Policy.authorize(scope, :read_executions),
         {:ok, filters} <- parse_filters(opts) do
      limit = filters.limit
      rows = Repo.all(index_query(scope, filters, limit + 1))
      {entries, rest} = Enum.split(rows, limit)
      next_cursor = if rest == [], do: nil, else: encode_cursor(List.last(entries))
      {:ok, %{entries: Enum.map(entries, &decorate_index/1), next_cursor: next_cursor}}
    end
  end

  @doc "Workflow id and name pairs for the index filter, without draft documents."
  @spec list_workflow_options(Scope.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_workflow_options(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :read_executions) do
      query =
        from w in Workflow,
          where: w.installation_id == ^scope.installation_id,
          order_by: [asc: w.name, asc: w.id],
          limit: ^@max_workflow_options,
          select: %{id: w.id, name: w.name}

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  One execution's sanitized timeline.

  Cross-tenant and unknown ids return the same `:not_found` error. Trigger
  text, raw step output maps, unrestricted diagnostics, and approval tokens
  are not loaded. Only the explicit safe diagnostic allowlist is returned.
  """
  @spec get_detail(Scope.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_detail(%Scope{} = scope, id) do
    with :ok <- Policy.authorize(scope, :read_executions),
         {:ok, uuid} <- cast_uuid(id),
         {:ok, header} <- fetch_header(scope, uuid) do
      steps = load_steps(scope.installation_id, header.id)
      {:ok, assemble_detail(header, steps)}
    end
  end

  @doc "Whether an operator may still request cancel for this summary."
  @spec cancellable?(map()) :: boolean()
  def cancellable?(%{status: "running", cancelled_at: cancelled_at})
      when not is_nil(cancelled_at),
      do: false

  def cancellable?(%{status: status}) when is_binary(status), do: not Execution.terminal?(status)
  def cancellable?(_row), do: false

  @doc "Whether the owner uncertainty controls apply to this summary."
  @spec resolvable?(map()) :: boolean()
  def resolvable?(%{status: "paused_uncertain"}), do: true
  def resolvable?(_row), do: false

  defp parse_filters(opts) do
    with {:ok, workflow_id} <- optional_uuid(opts, :workflow_id),
         {:ok, status} <- optional_status(opts),
         {:ok, from} <- optional_time(opts, :from),
         {:ok, until} <- optional_time(opts, :until),
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)) do
      {:ok,
       %{
         workflow_id: workflow_id,
         status: status,
         from: from,
         until: until,
         cursor: cursor,
         limit: clamp_limit(Keyword.get(opts, :limit, page_size()))
       }}
    end
  end

  defp index_query(%Scope{} = scope, filters, limit) do
    scope.installation_id
    |> base_query()
    |> filter_workflow(filters.workflow_id)
    |> filter_status(filters.status)
    |> filter_from(filters.from)
    |> filter_until(filters.until)
    |> filter_cursor(filters.cursor)
    |> order_newest()
    |> limit_rows(limit)
    |> select_summary()
  end

  defp fetch_header(%Scope{} = scope, id) do
    query =
      scope.installation_id
      |> base_query()
      |> where_id(id)
      |> select_summary()

    case Repo.one(query) do
      nil -> Scope.refuse_unknown(Execution, id, scope.installation_id, :executions)
      header -> {:ok, decorate_index(header)}
    end
  end

  defp load_steps(installation_id, execution_id) do
    steps = Repo.all(steps_query(installation_id, execution_id))
    step_ids = Enum.map(steps, & &1.id)
    attempts = load_attempts(installation_id, step_ids)
    approvals = load_approvals(installation_id, step_ids)

    Enum.map(steps, fn step ->
      step
      |> Map.put(:attempts, Map.get(attempts, step.id, []))
      |> Map.put(:approval, Map.get(approvals, step.id))
      |> decorate_step()
    end)
  end

  defp load_attempts(_installation_id, []), do: %{}

  defp load_attempts(installation_id, step_ids) do
    query =
      from a in StepAttempt,
        where: a.installation_id == ^installation_id and a.step_execution_id in ^step_ids,
        order_by: [asc: a.attempt_number, asc: a.id],
        select: %{
          id: a.id,
          step_execution_id: a.step_execution_id,
          attempt_number: a.attempt_number,
          status: a.status,
          error_class: a.error_class,
          error_code: a.error_code,
          remote_status: a.remote_status,
          remote_request_id: a.remote_request_id,
          oban_job_id: a.oban_job_id,
          retry_at: a.retry_at,
          duration_ms: a.duration_ms,
          diagnostics: a.diagnostics,
          started_at: a.started_at,
          ended_at: a.ended_at
        }

    query
    |> Repo.all()
    |> Enum.map(
      &Map.update!(&1, :diagnostics, fn diagnostics -> safe_diagnostics(diagnostics) end)
    )
    |> Enum.group_by(& &1.step_execution_id)
  end

  defp safe_diagnostics(diagnostics) when is_map(diagnostics) do
    diagnostics
    |> Map.take(@attempt_diagnostic_keys)
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_boolean(value) or is_integer(value) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(value) -> Map.put(acc, key, clip(value))
      {_key, _value}, acc -> acc
    end)
  end

  defp safe_diagnostics(_diagnostics), do: %{}

  defp clip(value) when byte_size(value) <= @max_diagnostic_value_bytes, do: value

  defp clip(value) do
    prefix = binary_part(value, 0, @max_diagnostic_value_bytes)

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end

  defp load_approvals(_installation_id, []), do: %{}

  defp load_approvals(installation_id, step_ids) do
    query =
      from a in Approval,
        where: a.installation_id == ^installation_id and a.step_execution_id in ^step_ids,
        select: %{
          id: a.id,
          step_execution_id: a.step_execution_id,
          status: a.status,
          expires_at: a.expires_at,
          decided_at: a.decided_at,
          decided_by_pumble_user_id: a.decided_by_pumble_user_id,
          pumble_channel_id: a.pumble_channel_id,
          pumble_message_id: a.pumble_message_id
        }

    query
    |> Repo.all()
    |> Map.new(&{&1.step_execution_id, &1})
  end

  defp assemble_detail(header, steps) do
    %{
      execution: header,
      trigger: trigger_pairs(header),
      steps: steps,
      terminal_reason: terminal_reason(header, steps)
    }
  end

  defp base_query(installation_id) do
    from e in Execution,
      join: w in Workflow,
      on: w.id == e.workflow_id and w.installation_id == e.installation_id,
      join: v in WorkflowVersion,
      on: v.id == e.workflow_version_id and v.installation_id == e.installation_id,
      left_join: s in StepExecution,
      on:
        s.execution_id == e.id and s.node_id == e.current_node_id and
          s.installation_id == e.installation_id,
      where: e.installation_id == ^installation_id
  end

  defp select_summary(query) do
    from [e, w, v, s] in query,
      select: %{
        id: e.id,
        status: e.status,
        inserted_at: e.inserted_at,
        updated_at: e.updated_at,
        workflow_id: e.workflow_id,
        workflow_name: w.name,
        workflow_version_id: e.workflow_version_id,
        version_number: v.version_number,
        execution_key: e.execution_key,
        current_node_id: e.current_node_id,
        current_node_type: s.node_type,
        cancellation_reason: e.cancellation_reason,
        cancelled_at: e.cancelled_at,
        lock_version: e.lock_version,
        run_mode: fragment("? #>> '{execution,run_mode}'", e.context),
        trigger_type: fragment("?->>'type'", e.trigger_snapshot),
        correlation_id: fragment("?->>'correlation_id'", e.trigger_snapshot),
        trigger_occurred_at: fragment("?->>'occurred_at'", e.trigger_snapshot),
        trigger_channel_id: fragment("?->>'channel_id'", e.trigger_snapshot),
        trigger_actor_id: fragment("?->>'actor_id'", e.trigger_snapshot),
        trigger_resource_id: fragment("?->>'resource_id'", e.trigger_snapshot),
        trigger_thread_root_id: fragment("?->>'thread_root_id'", e.trigger_snapshot)
      }
  end

  defp steps_query(installation_id, execution_id) do
    from s in StepExecution,
      where: s.installation_id == ^installation_id and s.execution_id == ^execution_id,
      order_by: [asc: s.inserted_at, asc: s.id],
      select: %{
        id: s.id,
        node_id: s.node_id,
        node_type: s.node_type,
        status: s.status,
        selected_edge: s.selected_edge,
        remote_reference: s.remote_reference,
        uncertainty_reason: s.uncertainty_reason,
        attempt_count: s.attempt_count,
        inserted_at: s.inserted_at,
        updated_at: s.updated_at,
        resume_at: fragment("?->>'resume_at'", s.output),
        expires_at: fragment("?->>'expires_at'", s.output),
        output_reason: fragment("?->>'reason'", s.output),
        output_result: fragment("?->>'result'", s.output),
        output_message_id: fragment("?->>'message_id'", s.output),
        output_channel_id: fragment("?->>'channel_id'", s.output),
        output_user_id: fragment("?->>'user_id'", s.output),
        output_status: fragment("?->>'status'", s.output),
        output_excerpt: fragment("?->>'excerpt'", s.output)
      }
  end

  defp filter_workflow(query, nil), do: query

  defp filter_workflow(query, workflow_id),
    do: from([e] in query, where: e.workflow_id == ^workflow_id)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from([e] in query, where: e.status == ^status)

  defp filter_from(query, nil), do: query
  defp filter_from(query, from), do: from([e] in query, where: e.inserted_at >= ^from)

  defp filter_until(query, nil), do: query
  defp filter_until(query, until), do: from([e] in query, where: e.inserted_at <= ^until)

  defp filter_cursor(query, nil), do: query

  defp filter_cursor(query, {time, id}) do
    from [e] in query,
      where: e.inserted_at < ^time or (e.inserted_at == ^time and e.id < ^id)
  end

  defp order_newest(query), do: from([e] in query, order_by: [desc: e.inserted_at, desc: e.id])

  defp limit_rows(query, limit), do: from([e] in query, limit: ^limit)

  defp where_id(query, id), do: from([e] in query, where: e.id == ^id)

  defp decorate_index(row) do
    row
    |> Map.put(:trigger_summary, trigger_summary(row))
    |> Map.put(:cancellable?, cancellable?(row))
    |> Map.put(:resolvable?, resolvable?(row))
  end

  defp decorate_step(step) do
    Map.put(step, :output_pairs, step_output_pairs(step))
  end

  defp trigger_summary(row) do
    [row.trigger_type, row.trigger_channel_id, row.run_mode]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "—"
      text -> text
    end
  end

  defp trigger_pairs(row) do
    [
      {"Type", row.trigger_type},
      {"Correlation ID", row.correlation_id},
      {"Occurred at", row.trigger_occurred_at},
      {"Channel", row.trigger_channel_id},
      {"Actor", row.trigger_actor_id},
      {"Resource", row.trigger_resource_id},
      {"Thread", row.trigger_thread_root_id},
      {"Run mode", row.run_mode}
    ]
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
  end

  defp step_output_pairs(step) do
    [
      {"Result", step.output_result},
      {"Reason", step.output_reason},
      {"Status", step.output_status},
      {"Message", step.output_message_id},
      {"Channel", step.output_channel_id},
      {"User", step.output_user_id},
      {"Excerpt", step.output_excerpt}
    ]
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
  end

  defp terminal_reason(%{status: "cancelled", cancellation_reason: reason}, _steps)
       when is_binary(reason) and reason != "",
       do: reason

  defp terminal_reason(%{status: "failed", current_node_id: node_id}, steps) do
    case Enum.find(steps, &(&1.node_id == node_id)) do
      %{uncertainty_reason: reason} when is_binary(reason) and reason != "" -> reason
      %{attempts: attempts} -> failed_attempt_reason(attempts)
      _missing -> nil
    end
  end

  defp terminal_reason(%{status: "completed", current_node_id: node_id}, steps) do
    case Enum.find(steps, &(&1.node_id == node_id)) do
      %{output_reason: reason} when is_binary(reason) and reason != "" -> reason
      _missing -> nil
    end
  end

  defp terminal_reason(_header, _steps), do: nil

  defp failed_attempt_reason(attempts) do
    attempts
    |> Enum.reverse()
    |> Enum.find_value(fn attempt ->
      [attempt.error_class, attempt.error_code]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" · ")
      |> case do
        "" -> nil
        text -> text
      end
    end)
  end

  defp encode_cursor(%{inserted_at: %DateTime{} = time, id: id}) do
    Base.url_encode64("#{DateTime.to_iso8601(time)} #{id}", padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- decode64(value),
         [time_text, id] <- String.split(decoded, " ", parts: 2),
         {:ok, time, _offset} <- DateTime.from_iso8601(time_text),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, {time, uuid}}
    else
      _invalid -> {:ok, nil}
    end
  end

  defp decode_cursor(_value), do: {:ok, nil}

  defp decode64(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :error
    end
  end

  defp optional_uuid(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value -> cast_optional_uuid(value)
    end
  end

  defp cast_optional_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:ok, nil}
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Policy.not_found()}
    end
  end

  defp optional_status(opts) do
    case Keyword.get(opts, :status) do
      status when status in ["", nil] ->
        {:ok, nil}

      status when is_binary(status) ->
        if status in Execution.statuses(), do: {:ok, status}, else: {:ok, nil}

      _other ->
        {:ok, nil}
    end
  end

  defp optional_time(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      %DateTime{} = time -> {:ok, time}
      value when is_binary(value) -> parse_time(value)
      _other -> {:ok, nil}
    end
  end

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} ->
        {:ok, DateTime.from_unix!(DateTime.to_unix(time, :microsecond), :microsecond)}

      {:error, _reason} ->
        parse_naive_time(value)
    end
  end

  defp parse_naive_time(value) do
    case NaiveDateTime.from_iso8601(String.replace(value, "T", " ")) do
      {:ok, naive} ->
        case DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, time} -> {:ok, time}
          _other -> {:ok, nil}
        end

      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, Limits.get(:history_page_max))

  defp clamp_limit(_limit), do: page_size()

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
