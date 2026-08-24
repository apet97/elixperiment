defmodule PumbleAutomation.Executions.CreateExecutionTest do
  @moduledoc """
  Creating an execution is one transaction: the queued run, its first step,
  and the Oban advance job either all exist or none of them do.
  """

  # This module installs a table-wide failure trigger for rollback proof.
  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)
    %{version: version, workflow: workflow} = activate!(scope, installation.id)

    %{
      scope: scope,
      installation: installation,
      installation_id: installation.id,
      version: version,
      workflow: workflow
    }
  end

  describe "create/2" do
    test "inserts a queued execution, first step, and advance job together", context do
      key = "ingress-#{System.unique_integer([:positive])}"

      assert {:ok, execution} =
               Engine.create(context.scope, %{
                 workflow_version_id: context.version.id,
                 execution_key: key,
                 trigger_snapshot: %{"channel_id" => "channel-1"},
                 run_mode: "live"
               })

      assert execution.status == "queued"
      assert execution.execution_key == key
      assert execution.installation_id == context.installation_id
      assert execution.workflow_id == context.workflow.id
      assert execution.workflow_version_id == context.version.id
      assert execution.current_node_id
      assert execution.lock_version == 0
      assert execution.lineage_depth == 0
      assert execution.context["execution"]["run_mode"] == "live"
      assert execution.trigger_snapshot == %{"channel_id" => "channel-1"}

      assert [step] =
               Repo.all(from s in StepExecution, where: s.execution_id == ^execution.id)

      assert step.node_id == execution.current_node_id
      assert step.status == "queued"
      assert step.node_type == "delay"

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

    test "a second call with the same key returns the existing execution", context do
      key = "dup-#{System.unique_integer([:positive])}"
      attrs = %{workflow_version_id: context.version.id, execution_key: key}

      assert {:ok, first} = Engine.create(context.scope, attrs)
      assert {:ok, second} = Engine.create(context.scope, attrs)

      assert second.id == first.id

      assert Repo.aggregate(
               from(e in Execution, where: e.installation_id == ^context.installation_id),
               :count
             ) == 1

      assert Repo.aggregate(Oban.Job, :count) == 1
    end

    test "an inactive installation writes nothing", context do
      revoke!(context.installation)

      assert {:error, %Error{class: :permission, code: :installation_revoked}} =
               Engine.create(context.scope, %{
                 workflow_version_id: context.version.id,
                 execution_key: "k-#{System.unique_integer([:positive])}"
               })

      assert_no_execution(context.installation_id)
    end

    test "a deactivated workflow writes nothing", context do
      {:ok, _} = Workflows.deactivate_workflow(context.scope, context.workflow.id)

      assert {:error, %Error{class: :conflict, code: :not_active}} =
               Engine.create(context.scope, %{
                 workflow_version_id: context.version.id,
                 execution_key: "k-#{System.unique_integer([:positive])}"
               })

      assert_no_execution(context.installation_id)
    end

    test "a version that is not the live program is a mismatch", context do
      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          context.workflow.id,
          definition([delay_node(), delay_node()]),
          context.workflow.draft_revision
        )

      {:ok, second} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      assert second.version.id != context.version.id

      assert {:error, %Error{class: :conflict, code: :version_mismatch}} =
               Engine.create(context.scope, %{
                 workflow_version_id: context.version.id,
                 execution_key: "k-#{System.unique_integer([:positive])}"
               })

      assert_no_execution(context.installation_id)
    end

    test "another workspace's version is indistinguishable from missing", context do
      other = InstallationsFixtures.install()
      other_scope = Scope.new(other.member)
      %{version: other_version} = activate!(other_scope, other.installation.id)

      assert {:error, error} =
               Engine.create(context.scope, %{
                 workflow_version_id: other_version.id,
                 execution_key: "k-#{System.unique_integer([:positive])}"
               })

      assert error == Policy.not_found()
      assert_no_execution(context.installation_id)
    end

    test "lineage depth above three is refused before any write", context do
      assert {:error, %Error{class: :validation, code: :lineage_depth_exceeded}} =
               Engine.create(context.scope, %{
                 workflow_version_id: context.version.id,
                 execution_key: "k-#{System.unique_integer([:positive])}",
                 root_execution_id: Ecto.UUID.generate(),
                 lineage_depth: 4
               })

      assert_no_execution(context.installation_id)
    end

    test "a derived run at depth three is admitted", context do
      {:ok, root} =
        Engine.create(context.scope, %{
          workflow_version_id: context.version.id,
          execution_key: "root-#{System.unique_integer([:positive])}"
        })

      %{version: child_version} =
        activate!(context.scope, context.installation_id, definition([stop_node()]))

      assert {:ok, child} =
               Engine.create(context.scope, %{
                 workflow_version_id: child_version.id,
                 execution_key: "child-#{System.unique_integer([:positive])}",
                 root_execution_id: root.id,
                 lineage_depth: 3
               })

      assert child.lineage_depth == 3
      assert child.root_execution_id == root.id
    end
  end

  describe "transaction rollback" do
    test "an oversized trigger snapshot writes no execution, step, or job", context do
      huge = %{"blob" => String.duplicate("a", Execution.max_context_bytes() + 1)}

      assert {:error, %Error{class: :validation, code: :invalid_execution}} =
               Engine.create(context.scope, %{
                 workflow_version_id: context.version.id,
                 execution_key: "k-#{System.unique_integer([:positive])}",
                 trigger_snapshot: huge
               })

      assert_no_execution(context.installation_id)
    end

    test "a rejected step insert rolls the execution and the not-yet-inserted job back",
         context do
      reject_inserts!("step_executions")

      assert {:error, %Error{code: :execution_write_failed}} =
               Engine.create(context.scope, %{
                 workflow_version_id: context.version.id,
                 execution_key: "k-#{System.unique_integer([:positive])}"
               })

      assert_no_execution(context.installation_id)
    end
  end

  defp activate!(scope, installation_id, definition \\ definition([delay_node()])) do
    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp assert_no_execution(installation_id) do
    refute Repo.exists?(from e in Execution, where: e.installation_id == ^installation_id)
    refute Repo.exists?(from s in StepExecution, where: s.installation_id == ^installation_id)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  defp revoke!(installation) do
    installation
    |> Installation.changeset(%{status: "revoked"})
    |> Repo.update!()
  end

  defp reject_inserts!(table) do
    suffix = System.unique_integer([:positive])
    name = "reject_#{table}_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'insert rejected';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{name}
    BEFORE INSERT ON #{table}
    FOR EACH ROW
    EXECUTE FUNCTION #{name}()
    """)

    :ok
  end
end

defmodule PumbleAutomation.Executions.CreateExecutionConcurrencyTest do
  @moduledoc """
  Two creates of one source key, run against a real database rather than the
  sandbox. See `WorkflowVersionConcurrencyTest` for why `:auto` is required.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "concurrent duplicate creates produce one execution and one job" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)
    key = "race-#{System.unique_integer([:positive])}"
    attrs = %{workflow_version_id: activated.version.id, execution_key: key}

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Engine.create(scope, attrs) end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    oks = for {:ok, execution} <- results, do: execution

    assert length(oks) == 2
    assert oks |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

    stored =
      Repo.all(
        from e in Execution,
          where: e.installation_id == ^installation.id and e.execution_key == ^key
      )

    assert length(stored) == 1

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "PumbleAutomation.Executions.Workers.AdvanceExecutionWorker"
      )

    assert length(jobs) == 1
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
