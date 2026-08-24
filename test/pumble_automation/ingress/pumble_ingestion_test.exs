defmodule PumbleAutomation.Ingress.PumbleIngestionTest do
  @moduledoc """
  Durable Pumble event ingestion: one receipt, then one execution and job
  per live match, with duplicates collapsing and failures left retryable.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    %{installation: installation, member: member} = InstallationsFixtures.install()

    %{
      scope: Scope.new(member),
      installation: installation,
      installation_id: installation.id,
      workspace_id: installation.pumble_workspace_id
    }
  end

  describe "zero, one, and many matches" do
    test "zero matches stores a processed receipt and creates nothing", context do
      activate!(context, definition([delay_node()]))
      payload = event_payload(context.workspace_id, channel_id: "no-such-channel")

      assert :accepted = Service.enqueue_event(payload, context())

      assert [%ReceivedEvent{processing_state: "processed"} = receipt] =
               receipts(context.installation_id)

      assert receipt.data["execution_count"] == 0
      assert_no_execution(context.installation_id)
    end

    test "one match creates one execution, one job, and a processed receipt", context do
      %{version: version} = activate!(context, definition([delay_node()]))
      payload = event_payload(context.workspace_id, rid: "RID-one")

      assert :accepted = Service.enqueue_event(payload, context(raw_body: "body-one"))

      assert [%ReceivedEvent{processing_state: "processed"} = receipt] =
               receipts(context.installation_id)

      assert receipt.data["execution_count"] == 1
      assert receipt.data["correlation_id"]
      assert receipt.data["type"] == "NEW_MESSAGE"
      assert receipt.data["channel_id"] == "channel-1"

      assert [%Execution{} = execution] = executions(context.installation_id)
      assert execution.received_event_id == receipt.id
      assert execution.workflow_version_id == version.id
      assert execution.execution_key == "recv:" <> receipt.id <> ":" <> binding_id(execution)
      assert execution.trigger_snapshot["binding_id"]
      assert execution.trigger_snapshot["correlation_id"] == receipt.data["correlation_id"]
      assert execution.trigger_snapshot["received_event_id"] == receipt.id

      assert [%StepExecution{status: "queued"}] =
               Repo.all(from s in StepExecution, where: s.execution_id == ^execution.id)

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          expected_node_id: execution.current_node_id,
          generation: 0
        }
      )
    end

    test "many matches create one execution and job per live binding", context do
      versions =
        for index <- 1..3 do
          %{version: version} =
            activate!(context, definition([delay_node()]), %{name: "Many #{index}"})

          version
        end

      payload = event_payload(context.workspace_id, rid: "RID-many")

      assert :accepted = Service.enqueue_event(payload, context(raw_body: "body-many"))

      assert [%ReceivedEvent{processing_state: "processed"} = receipt] =
               receipts(context.installation_id)

      stored = executions(context.installation_id)
      assert length(stored) == 3
      assert receipt.data["execution_count"] == 3
      assert Enum.all?(stored, &(&1.received_event_id == receipt.id))

      assert MapSet.new(Enum.map(stored, & &1.workflow_version_id)) ==
               MapSet.new(Enum.map(versions, & &1.id))

      assert Repo.aggregate(Oban.Job, :count) == 3
      assert Enum.all?(stored, &has_advance_job?/1)
    end
  end

  describe "duplicates" do
    test "a second callback for the same event creates nothing", context do
      activate!(context, definition([delay_node()]))
      payload = event_payload(context.workspace_id, rid: "RID-dup")
      ctx = context(raw_body: "same-bytes")

      assert :accepted = Service.enqueue_event(payload, ctx)
      assert :accepted = Service.enqueue_event(payload, ctx)

      assert [%ReceivedEvent{processing_state: "processed"}] = receipts(context.installation_id)
      assert length(executions(context.installation_id)) == 1
      assert Repo.aggregate(Oban.Job, :count) == 1
    end
  end

  describe "tenant rejection" do
    test "an uninstalled tenant writes no receipt and no execution", context do
      activate!(context, definition([delay_node()]))

      context.installation
      |> Installation.changeset(%{status: "uninstalled", uninstalled_at: DateTime.utc_now()})
      |> Repo.update!()

      payload = event_payload(context.workspace_id, rid: "RID-gone")

      assert :accepted = Service.enqueue_event(payload, context(raw_body: "gone"))
      assert receipts(context.installation_id) == []
      assert_no_execution(context.installation_id)
    end

    test "an unknown workspace is acknowledged and dropped" do
      payload = event_payload("workspace-never-installed", rid: "RID-none")

      assert :accepted = Service.enqueue_event(payload, context(raw_body: "none"))
      refute Repo.exists?(ReceivedEvent)
      refute Repo.exists?(Execution)
    end
  end

  describe "crash between receipt and execution" do
    test "the next call resumes and does not duplicate the run", context do
      activate!(context, definition([delay_node()]))
      payload = event_payload(context.workspace_id, rid: "RID-crash")

      crash =
        context(
          raw_body: "crash-bytes",
          after_receipt: fn -> raise "injected crash after receipt" end
        )

      assert_raise RuntimeError, "injected crash after receipt", fn ->
        Service.enqueue_event(payload, crash)
      end

      assert [%ReceivedEvent{processing_state: "received"} = receipt] =
               receipts(context.installation_id)

      assert_no_execution(context.installation_id)

      resume = context(raw_body: "crash-bytes")
      assert :accepted = Service.enqueue_event(payload, resume)

      stored = Repo.get!(ReceivedEvent, receipt.id)
      assert stored.processing_state == "processed"
      assert stored.data["execution_count"] == 1
      assert length(executions(context.installation_id)) == 1
      assert Repo.aggregate(Oban.Job, :count) == 1
    end
  end

  describe "transport requirements" do
    test "a callback without retained bytes is a validation error", context do
      payload = event_payload(context.workspace_id)

      assert {:error, %Error{class: :validation, code: :missing_body}} =
               Service.enqueue_event(payload, %{})
    end
  end

  defp activate!(context, definition, attrs \\ %{}) do
    workflow =
      drafted_workflow(
        context.installation_id,
        Map.merge(
          %{
            name: "Ingest #{System.unique_integer([:positive])}",
            slug: "ingest-#{System.unique_integer([:positive])}",
            draft_definition: Definition.encode(definition)
          },
          attrs
        )
      )

    {:ok, result} = Workflows.activate_workflow(context.scope, workflow.id, 0)
    result
  end

  defp event_payload(workspace_id, opts \\ []) do
    type = Keyword.get(opts, :type, "NEW_MESSAGE")

    %Payload.Event{
      message_type: "PUMBLE_EVENT",
      event_type: type,
      workspace_id: workspace_id,
      body: %{
        "cId" => Keyword.get(opts, :channel_id, "channel-1"),
        "aId" => Keyword.get(opts, :actor_id, "user-1"),
        "tx" => Keyword.get(opts, :text, "hello"),
        "rid" => Keyword.get(opts, :rid, "RID-#{System.unique_integer([:positive])}"),
        "mId" => "M-#{System.unique_integer([:positive])}",
        "tsm" => 1_767_225_600_000
      }
    }
  end

  defp context(opts \\ []) do
    opts
    |> Enum.into(%{})
    |> Map.put_new(:raw_body, "body-#{System.unique_integer([:positive])}")
    |> Map.put_new(:signature, "sig")
  end

  defp receipts(installation_id) do
    Repo.all(from event in ReceivedEvent, where: event.installation_id == ^installation_id)
  end

  defp executions(installation_id) do
    Repo.all(from execution in Execution, where: execution.installation_id == ^installation_id)
  end

  defp assert_no_execution(installation_id) do
    refute Repo.exists?(from e in Execution, where: e.installation_id == ^installation_id)
    refute Repo.exists?(from s in StepExecution, where: s.installation_id == ^installation_id)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  defp has_advance_job?(%Execution{} = execution) do
    Repo.exists?(
      from job in Oban.Job,
        where: job.worker == "PumbleAutomation.Executions.Workers.AdvanceExecutionWorker",
        where: fragment("? ->> 'execution_id' = ?", job.args, ^execution.id)
    )
  end

  defp binding_id(%Execution{trigger_snapshot: snapshot}), do: snapshot["binding_id"]
end

defmodule PumbleAutomation.Ingress.PumbleIngestionConcurrencyTest do
  @moduledoc """
  Two callbacks of one event, run against a real database rather than the
  sandbox.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "concurrent duplicate callbacks produce one receipt, one execution, and one job" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, _activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    payload = %Payload.Event{
      message_type: "PUMBLE_EVENT",
      event_type: "NEW_MESSAGE",
      workspace_id: installation.pumble_workspace_id,
      body: %{
        "cId" => "channel-1",
        "aId" => "user-1",
        "tx" => "hello",
        "rid" => "RID-race-#{System.unique_integer([:positive])}",
        "mId" => "M-race",
        "tsm" => 1_767_225_600_000
      }
    }

    ctx = %{raw_body: "race-bytes", signature: "sig"}

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Service.enqueue_event(payload, ctx) end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == :accepted))

    assert Repo.aggregate(
             from(event in ReceivedEvent, where: event.installation_id == ^installation.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(execution in Execution, where: execution.installation_id == ^installation.id),
             :count
           ) == 1

    jobs =
      Repo.all(
        from job in Oban.Job,
          where: job.worker == "PumbleAutomation.Executions.Workers.AdvanceExecutionWorker",
          where: fragment("? ->> 'installation_id' = ?", job.args, ^installation.id)
      )

    assert length(jobs) == 1
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from job in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end

defmodule PumbleAutomation.Ingress.PumbleIngestionJobFailureTest do
  @moduledoc """
  A rejected Oban insert must not leave an execution without a job. The
  receipt stays `received` so the next callback can finish the work.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "a rejected job insert rolls the execution back and leaves the receipt retryable" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, _activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {_name, drop} = reject_job_insert!(installation.id)
    on_exit(drop)

    payload = %Payload.Event{
      message_type: "PUMBLE_EVENT",
      event_type: "NEW_MESSAGE",
      workspace_id: installation.pumble_workspace_id,
      body: %{
        "cId" => "channel-1",
        "aId" => "user-1",
        "tx" => "hello",
        "rid" => "RID-jobfail-#{System.unique_integer([:positive])}",
        "mId" => "M-jobfail",
        "tsm" => 1_767_225_600_000
      }
    }

    ctx = %{raw_body: "jobfail-bytes", signature: "sig"}

    assert {:error, %Error{}} = Service.enqueue_event(payload, ctx)

    assert [%ReceivedEvent{processing_state: "received"}] =
             Repo.all(
               from event in ReceivedEvent, where: event.installation_id == ^installation.id
             )

    refute Repo.exists?(from e in Execution, where: e.installation_id == ^installation.id)

    refute Repo.exists?(
             from job in Oban.Job,
               where: fragment("? ->> 'installation_id' = ?", job.args, ^installation.id)
           )

    drop.()

    assert :accepted = Service.enqueue_event(payload, ctx)

    assert [%ReceivedEvent{processing_state: "processed"} = receipt] =
             Repo.all(
               from event in ReceivedEvent, where: event.installation_id == ^installation.id
             )

    assert receipt.data["execution_count"] == 1

    assert Repo.aggregate(
             from(e in Execution, where: e.installation_id == ^installation.id),
             :count
           ) ==
             1

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: fragment("? ->> 'installation_id' = ?", job.args, ^installation.id)
             ),
             :count
           ) == 1
  end

  defp reject_job_insert!(installation_id) do
    suffix = System.unique_integer([:positive])
    name = "reject_oban_jobs_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'job insert rejected';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{name}
    BEFORE INSERT ON oban_jobs
    FOR EACH ROW
    WHEN ((NEW.args ->> 'installation_id') = '#{installation_id}')
    EXECUTE FUNCTION #{name}()
    """)

    drop = fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON oban_jobs")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end

    {name, drop}
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from job in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
