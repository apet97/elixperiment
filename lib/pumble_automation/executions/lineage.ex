defmodule PumbleAutomation.Executions.Lineage do
  @moduledoc """
  Loop protection for derived executions and untrusted Pumble events.

  The workflow contract caps lineage depth at three. This module also caps descendants
  per root and per event window, refuses a workflow that would re-enter its
  own tree, and ignores parent claims that are not cryptographically bound.

  Pumble payloads are never a source of causality. Bot authorship is decided
  only by `aId == bot_user_id` (`N-4` / `N-7`). Subtype, flags, and
  caller-supplied root or depth fields do not suppress or create lineage.
  Internal starts (browser, manual, schedule) and a verified webhook header
  may name a parent; everything else starts a new root.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.WorkflowVersion

  @telemetry_event [:pumble_automation, :lineage]
  @header_name "x-pumble-automation-lineage"
  @event_window_seconds 900
  @window_scan_limit 100
  @include_bot_warning "Including bot messages can create loops. Lineage depth still caps derived runs."
  @skip_create_codes [
    :lineage_loop,
    :lineage_depth_exceeded,
    :lineage_descendants_exceeded
  ]

  @type lineage :: %{root_execution_id: Ecto.UUID.t() | nil, lineage_depth: non_neg_integer()}
  @type request :: map()

  @doc "Lineage depth ceiling."
  @spec max_depth() :: pos_integer()
  def max_depth, do: Limits.get(:lineage_depth)

  @doc "Maximum derived executions under one root, and bot-origin runs in the event window."
  @spec max_descendants() :: pos_integer()
  def max_descendants, do: Limits.get(:lineage_descendants)

  @doc "How long an event window and a lineage token last, in seconds."
  @spec event_window_seconds() :: pos_integer()
  def event_window_seconds, do: @event_window_seconds

  @doc "The inbound header that may carry a bound parent execution."
  @spec header_name() :: String.t()
  def header_name, do: @header_name

  @doc "Telemetry prefix for loop and bot-filter diagnostics."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc "Create errors that ingress must skip rather than fail the receipt."
  @spec skip_create_codes() :: [atom()]
  def skip_create_codes, do: @skip_create_codes

  @doc "Owner-facing warning when a trigger includes the installation bot."
  @spec include_bot_warning_message() :: String.t()
  def include_bot_warning_message, do: @include_bot_warning

  @doc "A root run: no parent, depth zero."
  @spec root() :: lineage()
  def root, do: %{root_execution_id: nil, lineage_depth: 0}

  @doc """
  The next hop under `parent`.

  Depth is `parent.lineage_depth + 1`. The root is the parent's root, or the
  parent itself when the parent is a root.
  """
  @spec from_parent(Execution.t()) :: lineage()
  def from_parent(%Execution{} = parent) do
    %{
      root_execution_id: parent.root_execution_id || parent.id,
      lineage_depth: parent.lineage_depth + 1
    }
  end

  @doc """
  A compact HMAC token bound to this execution and its installation.

  The token is the only way an inbound webhook may name a parent. It expires
  after `event_window_seconds/0`.
  """
  @spec token(Execution.t()) :: String.t()
  def token(%Execution{} = execution) do
    exp = DateTime.utc_now() |> DateTime.add(@event_window_seconds, :second) |> DateTime.to_unix()
    mac = mac(execution.installation_id, execution.id, exp)

    execution.id <> "." <> Integer.to_string(exp) <> "." <> encode(mac)
  end

  @doc """
  Reads a verified parent execution id from inbound headers.

  Missing, expired, foreign, or forged tokens are `:absent`. A forged token
  is counted; the body of the request is never logged.
  """
  @spec parent_from_headers(map() | nil, Ecto.UUID.t()) :: {:ok, Ecto.UUID.t()} | :absent
  def parent_from_headers(headers, installation_id)
      when is_binary(installation_id) do
    case header_value(headers) do
      nil ->
        :absent

      token ->
        case verify_token(token, installation_id) do
          {:ok, execution_id} ->
            {:ok, execution_id}

          :error ->
            record(:forged, installation_id)
            :absent
        end
    end
  end

  @doc """
  Admits or refuses one create.

  Untrusted Pumble events always start a root. Internal and verified webhook
  parents are loaded by `(installation_id, id)`, then depth, descendants, and
  workflow re-entry are enforced. Duplicate `execution_key` retries exclude
  the existing row so a second create of the same key still collapses.
  """
  @spec admit(module(), request(), WorkflowVersion.t()) ::
          {:ok, lineage()} | {:error, Error.t()}
  def admit(repo, request, %WorkflowVersion{} = version) when is_map(request) do
    if untrusted_event?(request) do
      admit_untrusted(repo, request, version)
    else
      admit_internal(repo, request, version)
    end
  end

  @doc "Records a loop or filter diagnostic without payload, body, or message text."
  @spec record(atom(), Ecto.UUID.t() | nil) :: :ok
  def record(reason, installation_id \\ nil) when is_atom(reason) do
    metadata =
      %{reason: Atom.to_string(reason)}
      |> maybe_put(:installation_id, installation_id)

    :telemetry.execute(@telemetry_event, %{count: 1}, metadata)
    :ok
  end

  defp admit_untrusted(repo, request, version) do
    with :ok <- pumble_window(repo, request, version) do
      {:ok, root()}
    end
  end

  defp admit_internal(repo, request, version) do
    cond do
      is_binary(request.parent_execution_id) ->
        derive_from_parent(repo, request, version, request.parent_execution_id)

      request.lineage_depth > 0 ->
        admit_explicit(repo, request, version)

      true ->
        {:ok, root()}
    end
  end

  defp derive_from_parent(repo, request, version, parent_id) do
    with {:ok, parent} <- load_execution(repo, request.installation_id, parent_id) do
      parent
      |> from_parent()
      |> admit_derived(repo, request, version)
    end
  end

  defp admit_explicit(repo, request, version) do
    with {:ok, _root} <- load_execution(repo, request.installation_id, request.root_execution_id) do
      %{root_execution_id: request.root_execution_id, lineage_depth: request.lineage_depth}
      |> admit_derived(repo, request, version)
    end
  end

  defp admit_derived(lineage, repo, request, version) do
    with :ok <- require_depth(lineage.lineage_depth, request.installation_id),
         :ok <- require_descendants(repo, request, lineage.root_execution_id),
         :ok <- require_acyclic(repo, request, version, lineage.root_execution_id) do
      {:ok, lineage}
    end
  end

  defp pumble_window(repo, request, version) do
    resource_id = snapshot_string(request.trigger_snapshot, "resource_id")
    bot_origin? = snapshot_boolean(request.trigger_snapshot, "bot_origin")
    recent = recent_executions(repo, request)

    with :ok <- require_resource_unique(recent, version.workflow_id, resource_id, request),
         :ok <- require_bot_reentry(recent, version.workflow_id, bot_origin?, request) do
      require_bot_window(recent, bot_origin?, request)
    end
  end

  defp require_resource_unique(_recent, _workflow_id, nil, _request), do: :ok

  defp require_resource_unique(recent, workflow_id, resource_id, request) do
    repeated? =
      Enum.any?(recent, fn execution ->
        execution.workflow_id == workflow_id and
          snapshot_string(execution.trigger_snapshot, "resource_id") == resource_id
      end)

    if repeated? do
      refuse(:cycle, request.installation_id, :lineage_loop, loop_message())
    else
      :ok
    end
  end

  defp require_bot_reentry(_recent, _workflow_id, false, _request), do: :ok
  defp require_bot_reentry(_recent, _workflow_id, nil, _request), do: :ok

  defp require_bot_reentry(recent, workflow_id, true, request) do
    if Enum.any?(recent, &(&1.workflow_id == workflow_id)) do
      refuse(:cycle, request.installation_id, :lineage_loop, loop_message())
    else
      :ok
    end
  end

  defp require_bot_window(_recent, bot_origin?, _request) when bot_origin? != true, do: :ok

  defp require_bot_window(recent, true, request) do
    count =
      Enum.count(recent, fn execution ->
        snapshot_boolean(execution.trigger_snapshot, "bot_origin") == true
      end)

    if count >= max_descendants() do
      refuse(
        :descendants,
        request.installation_id,
        :lineage_descendants_exceeded,
        descendant_message()
      )
    else
      :ok
    end
  end

  defp require_depth(depth, installation_id) do
    if depth > max_depth() do
      refuse(
        :depth,
        installation_id,
        :lineage_depth_exceeded,
        "This run cannot start because it would exceed the lineage depth limit."
      )
    else
      :ok
    end
  end

  defp require_descendants(repo, request, root_id) do
    count =
      repo.aggregate(
        from(execution in Execution,
          where:
            execution.installation_id == ^request.installation_id and
              execution.root_execution_id == ^root_id and
              execution.execution_key != ^request.execution_key
        ),
        :count
      )

    if count >= max_descendants() do
      refuse(
        :descendants,
        request.installation_id,
        :lineage_descendants_exceeded,
        descendant_message()
      )
    else
      :ok
    end
  end

  defp require_acyclic(repo, request, version, root_id) do
    ids =
      repo.all(
        from(execution in Execution,
          where:
            execution.installation_id == ^request.installation_id and
              execution.execution_key != ^request.execution_key and
              (execution.id == ^root_id or execution.root_execution_id == ^root_id),
          select: {execution.workflow_id, execution.workflow_version_id}
        )
      )

    conflict? =
      Enum.any?(ids, fn {workflow_id, version_id} ->
        workflow_id == version.workflow_id or version_id == version.id
      end)

    if conflict? do
      refuse(:cycle, request.installation_id, :lineage_loop, loop_message())
    else
      :ok
    end
  end

  defp recent_executions(repo, request) do
    cutoff = DateTime.add(DateTime.utc_now(), -@event_window_seconds, :second)

    repo.all(
      from execution in Execution,
        where:
          execution.installation_id == ^request.installation_id and
            execution.execution_key != ^request.execution_key and
            execution.inserted_at >= ^cutoff,
        order_by: [desc: execution.inserted_at],
        limit: @window_scan_limit,
        select: [:id, :workflow_id, :workflow_version_id, :trigger_snapshot, :execution_key]
    )
  end

  defp load_execution(repo, installation_id, execution_id) when is_binary(execution_id) do
    query =
      from execution in Execution,
        where: execution.id == ^execution_id and execution.installation_id == ^installation_id

    case repo.one(query) do
      %Execution{} = execution ->
        {:ok, execution}

      nil ->
        Scope.refuse_unknown(Execution, execution_id, installation_id, :lineage)
    end
  end

  defp load_execution(_repo, _installation_id, _execution_id) do
    {:error, invalid_parent()}
  end

  defp verify_token(token, installation_id) when is_binary(token) do
    with {:ok, execution_id, exp, mac} <- parse_token(token),
         :ok <- require_fresh(exp),
         true <- valid_mac?(installation_id, execution_id, exp, mac),
         %Execution{} <- tenant_execution(installation_id, execution_id) do
      {:ok, execution_id}
    else
      _other -> :error
    end
  end

  defp parse_token(token) do
    case String.split(token, ".", parts: 3) do
      [execution_id, exp, mac] ->
        with {:ok, _} <- Ecto.UUID.cast(execution_id),
             {unix, ""} <- Integer.parse(exp),
             {:ok, digest} <- decode(mac) do
          {:ok, execution_id, unix, digest}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp require_fresh(exp) when is_integer(exp) do
    if exp > DateTime.to_unix(DateTime.utc_now()), do: :ok, else: :error
  end

  defp valid_mac?(installation_id, execution_id, exp, mac) do
    expected = mac(installation_id, execution_id, exp)
    byte_size(expected) == byte_size(mac) and Plug.Crypto.secure_compare(expected, mac)
  end

  defp tenant_execution(installation_id, execution_id) do
    Repo.one(
      from execution in Execution,
        where: execution.id == ^execution_id and execution.installation_id == ^installation_id
    )
  end

  defp mac(installation_id, execution_id, exp) do
    :crypto.mac(
      :hmac,
      :sha256,
      signing_key(),
      "lineage.v1\n" <>
        installation_id <> "\n" <> execution_id <> "\n" <> Integer.to_string(exp)
    )
  end

  defp signing_key do
    Application.fetch_env!(:pumble_automation, PumbleAutomationWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  defp encode(mac), do: Base.url_encode64(mac, padding: false)

  defp decode(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, mac} -> {:ok, mac}
      :error -> :error
    end
  end

  defp header_value(headers) when is_map(headers) do
    case Map.get(headers, @header_name) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp header_value(_headers), do: nil

  defp untrusted_event?(request), do: request.lineage_source == :pumble_event

  defp snapshot_string(snapshot, key) when is_map(snapshot) do
    case map_get(snapshot, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp snapshot_string(_snapshot, _key), do: nil

  defp snapshot_boolean(snapshot, key) when is_map(snapshot) do
    case map_get(snapshot, key) do
      value when is_boolean(value) -> value
      _missing -> nil
    end
  end

  defp snapshot_boolean(_snapshot, _key), do: nil

  defp map_get(map, "resource_id"), do: Map.get(map, "resource_id") || Map.get(map, :resource_id)
  defp map_get(map, "bot_origin"), do: Map.get(map, "bot_origin") || Map.get(map, :bot_origin)
  defp map_get(map, key), do: Map.get(map, key)

  defp refuse(reason, installation_id, code, message) do
    record(reason, installation_id)
    Limits.record_hit(code, installation_id)

    {:error, Error.new(:validation, code, message: message)}
  end

  defp loop_message do
    "This run cannot start because it would repeat a workflow in the same lineage."
  end

  defp descendant_message do
    "This run cannot start because it would exceed the lineage descendant limit."
  end

  defp invalid_parent do
    Error.new(:validation, :invalid_execution,
      message: "A derived execution must name its root run."
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
