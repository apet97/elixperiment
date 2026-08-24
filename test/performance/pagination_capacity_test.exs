defmodule PumbleAutomation.Performance.PaginationCapacityTest do
  @moduledoc """
  Query-shape and pagination proof over bounded, tenant-scoped local fixtures.

  Query counts, selected fields, page sizes, cursor semantics, and EXPLAIN
  shapes are release gates. Printed durations describe only this local run.
  """

  use PumbleAutomation.DataCase, async: false

  import PumbleAutomation.ExecutionsFixtures, only: [execution: 2]
  import PumbleAutomation.WorkflowsFixtures, only: [workflow: 2]

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.History
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Workflow

  @workflow_rows 60
  @workflow_page_size 20
  @other_tenant_rows 12

  test "workflow pages stay tenant-scoped and cost two queries per page" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    other = InstallationsFixtures.install()
    scope = Scope.new(member)

    for index <- 1..@workflow_rows do
      workflow(installation.id, %{name: "Capacity #{String.pad_leading("#{index}", 3, "0")}"})
    end

    for index <- 1..@other_tenant_rows do
      workflow(other.installation.id, %{name: "Other #{index}"})
    end

    {pages, elapsed_us} =
      timed(fn ->
        for offset <- [0, @workflow_page_size, @workflow_page_size * 2] do
          {result, queries} =
            trace_queries(fn ->
              Workflows.list_workflow_index(scope,
                limit: @workflow_page_size,
                offset: offset
              )
            end)

          assert length(queries) == 2
          assert Enum.any?(queries, &bounded_workflow_sql?/1)
          {result, queries}
        end
      end)

    results = Enum.map(pages, &elem(&1, 0))
    query_batches = Enum.map(pages, &elem(&1, 1))

    entries =
      Enum.flat_map(results, fn
        {:ok, %{entries: rows, total: @workflow_rows}} -> rows
      end)

    assert length(entries) == @workflow_rows
    assert length(Enum.uniq(Enum.map(entries, & &1.id))) == @workflow_rows
    refute Enum.any?(entries, &Map.has_key?(&1, :draft_definition))

    query =
      from workflow in Workflow,
        where: workflow.installation_id == ^installation.id and is_nil(workflow.archived_at),
        order_by: [desc: workflow.inserted_at, desc: workflow.id],
        limit: @workflow_page_size,
        select: %{id: workflow.id, name: workflow.name, status: workflow.status}

    plan = explain_index_plan(query, analyze: true)
    assert index_backed?(plan)
    refute plan =~ "Seq Scan on workflows"
    emit_plan("workflow_page", plan, true, total_workflow_cap: Limits.get(:total_workflows))

    emit_metric("workflow_pagination", @workflow_rows, elapsed_us,
      pages: length(results),
      queries: Enum.sum(Enum.map(query_batches, &length/1)),
      other_tenant_rows: @other_tenant_rows
    )
  end

  test "history cursor pages clamp at the catalog maximum and avoid tenant-wide sorting" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    other = InstallationsFixtures.install()
    scope = Scope.new(member)
    page_max = Limits.get(:history_page_max)
    row_count = page_max + 5
    marker = "capacity-private-payload-" <> String.duplicate("x", 256)

    version = PumbleAutomation.ExecutionsFixtures.version(installation.id)
    other_version = PumbleAutomation.ExecutionsFixtures.version(other.installation.id)

    for index <- 1..row_count do
      execution(version, %{
        execution_key: "capacity-history-#{index}",
        status: "completed",
        context: %{"private_payload" => marker, "execution" => %{"run_mode" => "live"}},
        trigger_snapshot: %{"private_payload" => marker, "type" => "capacity"}
      })
    end

    for index <- 1..@other_tenant_rows do
      execution(other_version, %{
        execution_key: "other-history-#{index}",
        status: "completed"
      })
    end

    {{:ok, first}, first_queries, first_us} =
      trace_timed_queries(fn -> History.list_index(scope, limit: page_max * 10) end)

    assert length(first.entries) == page_max
    assert is_binary(first.next_cursor)
    assert length(first_queries) == 1
    assert bounded_history_sql?(hd(first_queries))

    {{:ok, second}, second_queries, second_us} =
      trace_timed_queries(fn ->
        History.list_index(scope, limit: page_max * 10, cursor: first.next_cursor)
      end)

    assert length(second.entries) == 5
    assert is_nil(second.next_cursor)
    assert length(second_queries) == 1
    assert bounded_history_sql?(hd(second_queries))

    all_entries = first.entries ++ second.entries
    assert length(Enum.uniq(Enum.map(all_entries, & &1.id))) == row_count
    refute inspect(all_entries) =~ marker
    refute Enum.any?(all_entries, &Map.has_key?(&1, :context))
    refute Enum.any?(all_entries, &Map.has_key?(&1, :trigger_snapshot))

    query =
      from execution in Execution,
        where: execution.installation_id == ^installation.id,
        order_by: [desc: execution.inserted_at, desc: execution.id],
        limit: ^(page_max + 1),
        select: %{id: execution.id, inserted_at: execution.inserted_at}

    # Fetching 51 of 55 fixture rows can make a tiny quicksort cheaper than the
    # ordered index, depending on database-wide statistics left by prior tests.
    # Disable sort only for this structural EXPLAIN so PostgreSQL must prove the
    # tenant/order index can satisfy the query without a tenant-wide sort.
    Repo.query!("SET LOCAL enable_sort = off")
    plan = explain_index_plan(query, analyze: true)
    assert index_backed?(plan)
    refute plan =~ "Seq Scan on executions"
    assert plan =~ "executions_installation_history_cursor_index"

    # A LIMIT does not bound database work when PostgreSQL must first sort all
    # rows in the tenant. This assertion requires an order-preserving tenant
    # index and intentionally fails if history regresses to a scan-and-sort.
    refute plan =~ "Sort"
    emit_plan("history_cursor_page", plan, true, order_preserving: true)

    emit_metric("history_pagination", row_count, first_us + second_us,
      pages: 2,
      page_max: page_max,
      queries: length(first_queries) + length(second_queries),
      other_tenant_rows: @other_tenant_rows
    )
  end

  defp bounded_workflow_sql?(sql) do
    String.contains?(sql, "LIMIT") and String.contains?(sql, "OFFSET") and
      String.contains?(sql, "installation_id") and String.contains?(sql, "ORDER BY")
  end

  defp bounded_history_sql?(sql) do
    String.contains?(sql, "LIMIT") and String.contains?(sql, "installation_id") and
      String.contains?(sql, "ORDER BY")
  end

  defp trace_timed_queries(fun) do
    {elapsed_us, {result, queries}} = :timer.tc(fn -> trace_queries(fun) end)
    {result, queries, elapsed_us}
  end

  defp trace_queries(fun) do
    handler = "capacity-query-trace-#{System.unique_integer([:positive])}"
    key = {__MODULE__, handler}
    mine = self()
    Process.put(key, [])

    :ok =
      :telemetry.attach(
        handler,
        [:pumble_automation, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == mine and is_binary(metadata.query) do
            Process.put(key, [metadata.query | Process.get(key, [])])
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, key |> Process.get([]) |> Enum.reverse()}
    after
      :telemetry.detach(handler)
      Process.delete(key)
    end
  end

  defp timed(fun) do
    {elapsed_us, result} = :timer.tc(fun)
    {result, elapsed_us}
  end

  defp emit_metric(name, count, elapsed_us, metadata) do
    details = Enum.map_join(metadata, " ", fn {key, value} -> "#{key}=#{value}" end)

    IO.puts(
      "CAPACITY_METRIC name=#{name} count=#{count} total_us=#{elapsed_us} " <>
        "avg_us=#{div(elapsed_us, count)} #{details} gate=semantic"
    )
  end

  defp emit_plan(name, plan, index_backed, metadata) do
    digest = :sha256 |> :crypto.hash(plan) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    details = Enum.map_join(metadata, " ", fn {key, value} -> "#{key}=#{value}" end)

    IO.puts(
      "CAPACITY_PLAN name=#{name} index_backed=#{index_backed} " <>
        "seq_scan=#{String.contains?(plan, "Seq Scan")} sort=#{String.contains?(plan, "Sort")} " <>
        "#{details} digest=#{digest}"
    )
  end
end
