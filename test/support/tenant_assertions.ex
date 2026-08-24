defmodule PumbleAutomation.TenantAssertions do
  @moduledoc """
  Assertions for the tenant-isolation matrix.

  Cross-tenant identifiers must be indistinguishable from missing ones, and a
  confirmed foreign id must emit bounded tenancy telemetry.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomationWeb.BrowserSession

  @doc "Puts the browser session cookie on a conn."
  @spec log_in(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def log_in(conn, token) when is_binary(token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end

  @doc "Asserts the result is exactly Policy.not_found/0."
  @spec assert_not_found(term()) :: PumbleAutomation.Error.t()
  def assert_not_found({:error, error}) do
    assert error == Policy.not_found()
    error
  end

  def assert_not_found(other) do
    flunk("expected Policy.not_found/0, got: #{inspect(other)}")
  end

  @doc "Runs `fun` with a tenancy-mismatch telemetry handler attached."
  @spec with_mismatch_events((-> result)) :: {result, [{map(), map()}]} when result: var
  def with_mismatch_events(fun) when is_function(fun, 0) do
    parent = self()
    ref = make_ref()
    handler_id = "tenant-mismatch-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        Scope.telemetry_event(),
        fn _event, measurements, metadata, _config ->
          send(parent, {ref, measurements, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      {result, collect_mismatches(ref)}
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc "Asserts at least one mismatch event named `source` was captured."
  @spec assert_mismatch_source([{map(), map()}], atom()) :: :ok
  def assert_mismatch_source(events, source) when is_atom(source) do
    name = Atom.to_string(source)

    assert Enum.any?(events, fn {_measurements, metadata} -> metadata.source == name end),
           "expected tenancy mismatch source #{inspect(source)}, got #{inspect(events)}"

    :ok
  end

  @doc "Counts of rows a destructive operation must not touch on another tenant."
  @spec tenant_snapshot(String.t()) :: map()
  def tenant_snapshot(installation_id) when is_binary(installation_id) do
    %{
      status: Repo.get!(Installation, installation_id).status,
      members:
        Repo.aggregate(
          from(m in WorkspaceMember, where: m.installation_id == ^installation_id),
          :count
        ),
      workflows:
        Repo.aggregate(from(w in Workflow, where: w.installation_id == ^installation_id), :count),
      executions:
        Repo.aggregate(
          from(e in Execution, where: e.installation_id == ^installation_id),
          :count
        )
    }
  end

  @doc "Asserts another tenant's snapshot is unchanged after a destructive operation."
  @spec assert_tenant_intact(String.t(), map()) :: :ok
  def assert_tenant_intact(installation_id, snapshot) when is_map(snapshot) do
    assert tenant_snapshot(installation_id) == snapshot
    :ok
  end

  @doc "Fails if any web module names PumbleAutomation.Repo."
  @spec assert_web_modules_omit_repo() :: :ok
  def assert_web_modules_omit_repo do
    root = Path.expand("../../lib/pumble_automation_web", __DIR__)
    files = Path.wildcard(Path.join(root, "**/*.{ex,heex}"))

    offenders =
      Enum.filter(files, fn path ->
        File.read!(path) =~ "PumbleAutomation.Repo"
      end)

    assert offenders == [],
           "web-layer Repo use is forbidden, found: #{Enum.map_join(offenders, ", ", &Path.relative_to_cwd/1)}"

    :ok
  end

  defp collect_mismatches(ref, acc \\ []) do
    receive do
      {^ref, measurements, metadata} ->
        collect_mismatches(ref, [{measurements, metadata} | acc])
    after
      0 ->
        Enum.reverse(acc)
    end
  end
end
