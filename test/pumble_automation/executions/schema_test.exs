defmodule PumbleAutomation.Executions.SchemaTest do
  @moduledoc """
  Durable execution, step, attempt, and approval constraints.

  The promises this file holds are the ones later P7 workers inherit: a
  tenant cannot be crossed by a parent id, a node runs at most once per
  execution, attempts are append-only, and an approval is decided once.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.ExecutionsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Workflows.WorkflowVersion

  setup do
    %{installation: %{id: installation_id}, member: member} = InstallationsFixtures.install()
    version = version(installation_id)

    %{
      installation_id: installation_id,
      member: member,
      version: version
    }
  end

  describe "the migration" do
    test "creates the four tables with uniqueness and tenant-composite keys" do
      for table <- ~w(executions step_executions step_attempts approvals) do
        assert %{rows: [[found]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
        assert found == table
      end

      execution_indexes = index_definitions("executions")
      assert execution_indexes =~ "UNIQUE"
      assert execution_indexes =~ "(installation_id, execution_key)"
      assert execution_indexes =~ "(id, installation_id)"

      step_indexes = index_definitions("step_executions")
      assert step_indexes =~ "(execution_id, node_id)"
      assert step_indexes =~ "(id, execution_id, installation_id)"

      assert index_definitions("step_attempts") =~ "(step_execution_id, attempt_number)"
      assert index_definitions("approvals") =~ "approvals_step_execution_id_index"

      assert foreign_keys("executions") =~ "(workflow_id, installation_id)"
      assert foreign_keys("executions") =~ "(workflow_version_id, installation_id)"
      assert foreign_keys("step_executions") =~ "(execution_id, installation_id)"
      assert foreign_keys("approvals") =~ "(step_execution_id, execution_id, installation_id)"
    end

    test "declares the status check constraints" do
      assert "executions_status_check" in check_constraints("executions")
      assert "step_executions_status_check" in check_constraints("step_executions")
      assert "step_attempts_status_check" in check_constraints("step_attempts")
      assert "approvals_status_check" in check_constraints("approvals")
    end

    test "does not give step_attempts an updated_at column" do
      refute :updated_at in StepAttempt.__schema__(:fields)
    end
  end

  describe "execution changeset and status" do
    test "inserts a queued run bound to its version", %{version: version} do
      run = execution(version)

      assert run.status == "queued"
      assert run.installation_id == version.installation_id
      assert run.workflow_version_id == version.id
      assert run.lineage_depth == 0
      assert run.root_execution_id == nil
      assert run.lock_version == 0
    end

    test "refuses a status outside the Section 19 set", %{version: version} do
      changeset =
        Execution.changeset(%Execution{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          execution_key: "k",
          status: "pending"
        })

      assert %{status: [_]} = errors_on(changeset)

      assert Execution.statuses() ==
               ~w(queued running waiting_delay waiting_approval paused_uncertain completed failed cancelled)
    end

    test "refuses a duplicate execution key in one tenant", %{version: version} do
      execution(version, %{execution_key: "same-delivery"})

      assert {:error, changeset} =
               %Execution{}
               |> Execution.changeset(%{
                 installation_id: version.installation_id,
                 workflow_id: version.workflow_id,
                 workflow_version_id: version.id,
                 execution_key: "same-delivery",
                 status: "queued"
               })
               |> Repo.insert()

      assert %{execution_key: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows the same execution key in another tenant", %{version: version} do
      execution(version, %{execution_key: "same-delivery"})
      %{installation: other} = InstallationsFixtures.install()
      other_version = version(other.id)

      assert %Execution{} = execution(other_version, %{execution_key: "same-delivery"})
    end

    test "refuses context larger than the Section 31 bound", %{version: version} do
      blob = String.duplicate("x", Execution.max_context_bytes() + 1)

      changeset =
        Execution.changeset(%Execution{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          execution_key: "k",
          status: "queued",
          context: %{"blob" => blob}
        })

      assert %{context: ["is too large"]} = errors_on(changeset)
    end

    test "refuses secret-looking keys in context and the trigger snapshot", %{version: version} do
      attrs = %{
        installation_id: version.installation_id,
        workflow_id: version.workflow_id,
        workflow_version_id: version.id,
        execution_key: "k",
        status: "queued"
      }

      assert %{context: [_]} =
               errors_on(
                 Execution.changeset(
                   %Execution{},
                   Map.put(attrs, :context, %{"api_token" => "no"})
                 )
               )

      assert %{trigger_snapshot: [_]} =
               errors_on(
                 Execution.changeset(
                   %Execution{},
                   Map.put(attrs, :trigger_snapshot, %{"signing_secret" => "no"})
                 )
               )
    end

    test "a derived run must name its root, and a root must not", %{version: version} do
      root = execution(version)

      assert %{root_execution_id: [_]} =
               errors_on(
                 Execution.changeset(%Execution{}, %{
                   installation_id: version.installation_id,
                   workflow_id: version.workflow_id,
                   workflow_version_id: version.id,
                   execution_key: "child",
                   status: "queued",
                   lineage_depth: 1
                 })
               )

      assert %{root_execution_id: [_]} =
               errors_on(
                 Execution.changeset(%Execution{}, %{
                   installation_id: version.installation_id,
                   workflow_id: version.workflow_id,
                   workflow_version_id: version.id,
                   execution_key: "rooted",
                   status: "queued",
                   lineage_depth: 0,
                   root_execution_id: root.id
                 })
               )

      child =
        execution(version, %{
          lineage_depth: 1,
          root_execution_id: root.id
        })

      assert child.lineage_depth == 1
      assert child.root_execution_id == root.id
    end

    test "refuses a lineage deeper than three", %{version: version} do
      changeset =
        Execution.changeset(%Execution{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          execution_key: "k",
          status: "queued",
          lineage_depth: 4,
          root_execution_id: Ecto.UUID.generate()
        })

      assert %{lineage_depth: [_]} = errors_on(changeset)
    end
  end

  describe "cross-tenant parent mismatch" do
    test "refuses an execution whose version belongs to another installation", %{
      version: version
    } do
      %{installation: other} = InstallationsFixtures.install()

      assert {:error, changeset} =
               %Execution{}
               |> Execution.changeset(%{
                 installation_id: other.id,
                 workflow_id: version.workflow_id,
                 workflow_version_id: version.id,
                 execution_key: "crossed",
                 status: "queued"
               })
               |> Repo.insert()

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :workflow_id) or Map.has_key?(errors, :workflow_version_id)
    end

    test "refuses a step whose execution belongs to another installation", %{version: version} do
      run = execution(version)
      %{installation: other} = InstallationsFixtures.install()

      assert {:error, changeset} =
               %StepExecution{}
               |> StepExecution.changeset(%{
                 installation_id: other.id,
                 execution_id: run.id,
                 node_id: Ecto.UUID.generate(),
                 node_type: "stop",
                 status: "queued"
               })
               |> Repo.insert()

      assert errors_on(changeset).execution_id != []
    end

    test "refuses an approval whose step is not that execution's step", %{version: version} do
      first = execution(version)
      second = execution(version)
      step = step_execution(first)

      assert {:error, changeset} =
               %Approval{}
               |> Approval.changeset(%{
                 installation_id: first.installation_id,
                 execution_id: second.id,
                 step_execution_id: step.id,
                 public_action_id: Ecto.UUID.generate(),
                 token_digest: Approval.digest("token"),
                 nonce: :crypto.strong_rand_bytes(32),
                 expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
               })
               |> Repo.insert()

      assert errors_on(changeset).step_execution_id != []
    end
  end

  describe "step executions" do
    test "computes the effect key and input hash, ignoring caller-supplied values", %{
      version: version
    } do
      run = execution(version)
      node_id = Ecto.UUID.generate()

      step =
        step_execution(run, %{
          node_id: node_id,
          resolved_input: %{"text" => "hello"},
          effect_key: "forged",
          resolved_input_hash: String.duplicate("0", 64)
        })

      assert step.effect_key == StepExecution.effect_key(run.installation_id, run.id, node_id)
      refute step.effect_key == "forged"
      assert step.resolved_input_hash == WorkflowVersion.definition_hash(%{"text" => "hello"})
      refute step.resolved_input_hash == String.duplicate("0", 64)
    end

    test "refuses a second step for the same node on one execution", %{version: version} do
      run = execution(version)
      node_id = Ecto.UUID.generate()
      step_execution(run, %{node_id: node_id})

      assert {:error, changeset} =
               %StepExecution{}
               |> StepExecution.changeset(%{
                 installation_id: run.installation_id,
                 execution_id: run.id,
                 node_id: node_id,
                 node_type: "delay",
                 status: "queued"
               })
               |> Repo.insert()

      errors = errors_on(changeset)

      assert "has already been taken" in List.wrap(errors[:node_id]) or
               "has already been taken" in List.wrap(errors[:execution_id])
    end

    test "refuses output larger than the payload bound", %{version: version} do
      run = execution(version)
      blob = String.duplicate("x", StepExecution.max_payload_bytes() + 1)

      changeset =
        StepExecution.changeset(%StepExecution{}, %{
          installation_id: run.installation_id,
          execution_id: run.id,
          node_id: Ecto.UUID.generate(),
          node_type: "stop",
          status: "queued",
          output: %{"blob" => blob}
        })

      assert %{output: ["is too large"]} = errors_on(changeset)
    end

    test "refuses an unknown node type", %{version: version} do
      run = execution(version)

      changeset =
        StepExecution.changeset(%StepExecution{}, %{
          installation_id: run.installation_id,
          execution_id: run.id,
          node_id: Ecto.UUID.generate(),
          node_type: "telepathy",
          status: "queued"
        })

      assert %{node_type: [_]} = errors_on(changeset)
    end
  end

  describe "step attempts" do
    test "allocates consecutive numbers and is create-only", %{version: version} do
      step = version |> execution() |> step_execution()
      first = step_attempt(step)
      second = step_attempt(step)

      assert first.attempt_number == 1
      assert second.attempt_number == 2
      assert first.status == "started"
      assert first.installation_id == step.installation_id

      exported = StepAttempt.__info__(:functions)
      refute Keyword.has_key?(exported, :update)
      refute Keyword.has_key?(exported, :delete)

      assert_raise RuntimeError, ~r/immutable/, fn ->
        StepAttempt.changeset(first, %{status: "succeeded"})
      end
    end

    test "ignores a caller-supplied tenant, step, and attempt number", %{version: version} do
      step = version |> execution() |> step_execution()
      %{installation: other} = InstallationsFixtures.install()

      {:ok, attempt} =
        StepAttempt.create(step, %{
          installation_id: other.id,
          step_execution_id: Ecto.UUID.generate(),
          attempt_number: 99,
          status: "failed"
        })

      assert attempt.installation_id == step.installation_id
      assert attempt.step_execution_id == step.id
      assert attempt.attempt_number == 1
      assert attempt.status == "failed"
    end

    test "refuses secret-looking diagnostics", %{version: version} do
      step = version |> execution() |> step_execution()

      assert {:error, %Error{class: :validation, code: :invalid_attempt}} =
               StepAttempt.create(step, %{diagnostics: %{"access_token" => "no"}})
    end
  end

  describe "approvals" do
    test "stores a digest, never the plaintext token", %{version: version} do
      token = "button-token-plaintext"
      step = version |> execution() |> step_execution()
      approval = approval(step, %{token: token})

      loaded = Repo.get!(Approval, approval.id)
      assert loaded.token_digest == Approval.digest(token)
      refute loaded.token_digest == token
      refute inspect(loaded) =~ token
      refute inspect(loaded) =~ "button-token"
    end

    test "changeset/2 raises for a stored approval", %{version: version} do
      approval = version |> execution() |> step_execution() |> approval()

      assert_raise RuntimeError, ~r/decide\/2/, fn ->
        Approval.changeset(approval, %{status: "approved"})
      end
    end

    test "refuses a second approval on the same step", %{version: version} do
      step = version |> execution() |> step_execution()
      approval(step)

      assert {:error, changeset} =
               %Approval{}
               |> Approval.changeset(%{
                 installation_id: step.installation_id,
                 execution_id: step.execution_id,
                 step_execution_id: step.id,
                 public_action_id: Ecto.UUID.generate(),
                 token_digest: Approval.digest("other"),
                 nonce: :crypto.strong_rand_bytes(32),
                 expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
               })
               |> Repo.insert()

      assert %{step_execution_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "decide/2 records one decision and refuses a second", %{version: version, member: member} do
      approval = version |> execution() |> step_execution() |> approval()

      assert {:ok, decided} =
               Approval.decide(approval, %{
                 status: "approved",
                 decided_by_member_id: member.id
               })

      assert decided.status == "approved"
      assert decided.decided_by_member_id == member.id
      assert decided.lock_version == approval.lock_version + 1
      refute is_nil(decided.decided_at)

      assert {:error, %Error{class: :conflict, code: :approval_already_decided}} =
               Approval.decide(decided, %{status: "rejected"})
    end

    test "refuses a digest that is not 32 bytes", %{version: version} do
      run = execution(version)
      step = step_execution(run)

      changeset =
        Approval.changeset(%Approval{}, %{
          installation_id: step.installation_id,
          execution_id: step.execution_id,
          step_execution_id: step.id,
          public_action_id: Ecto.UUID.generate(),
          token_digest: "not-a-digest",
          nonce: :crypto.strong_rand_bytes(32),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })

      assert %{token_digest: [_]} = errors_on(changeset)
    end
  end

  defp index_definitions(table) do
    %{rows: rows} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])

    Enum.map_join(rows, "\n", &hd/1)
  end

  defp foreign_keys(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pg_get_constraintdef(c.oid)
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname = $1 AND c.contype = 'f'
        """,
        [table]
      )

    Enum.map_join(rows, "\n", &hd/1)
  end

  defp check_constraints(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT con.conname FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        WHERE rel.relname = $1 AND con.contype = 'c'
        """,
        [table]
      )

    rows |> Enum.map(fn [name] -> name end) |> Enum.sort()
  end
end

defmodule PumbleAutomation.Executions.StepUniquenessRaceTest do
  @moduledoc """
  Several workers opening the same step at once.

  The unique index on `(execution_id, node_id)` only refuses a duplicate
  another transaction has actually committed, so this cannot run inside the
  SQL sandbox.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.ExecutionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo

  @writers 6

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "exactly one writer wins the (execution, node) identity" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    run = installation.id |> version() |> execution()
    node_id = Ecto.UUID.generate()

    outcomes =
      1..@writers
      |> Task.async_stream(
        fn _index ->
          %StepExecution{}
          |> StepExecution.changeset(%{
            installation_id: run.installation_id,
            execution_id: run.id,
            node_id: node_id,
            node_type: "pumble_action",
            status: "queued"
          })
          |> Repo.insert()
        end,
        max_concurrency: @writers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(outcomes, &match?({:ok, _step}, &1)) == 1
    assert Enum.count(outcomes, &match?({:error, _changeset}, &1)) == @writers - 1

    stored =
      Repo.all(
        from s in StepExecution,
          where: s.execution_id == ^run.id and s.node_id == ^node_id
      )

    assert length(stored) == 1
  end
end

defmodule PumbleAutomation.Executions.ApprovalDecisionRaceTest do
  @moduledoc """
  Two clicks deciding one approval at once.

  `Approval.decide/2` is a single `UPDATE ... WHERE status = 'pending'`. That
  predicate is only exclusive against a committed row, so this test has to
  leave the sandbox.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo

  import PumbleAutomation.ExecutionsFixtures

  @writers 6

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "exactly one writer records the decision" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    approval = installation.id |> version() |> execution() |> step_execution() |> approval()

    outcomes =
      1..@writers
      |> Task.async_stream(
        fn index ->
          status = if rem(index, 2) == 0, do: "approved", else: "rejected"
          Approval.decide(approval, %{status: status})
        end,
        max_concurrency: @writers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(outcomes, &match?({:ok, _approval}, &1)) == 1

    assert Enum.count(outcomes, &match?({:error, %Error{code: :approval_already_decided}}, &1)) ==
             @writers - 1

    stored = Repo.get!(Approval, approval.id)
    assert stored.status in ~w(approved rejected)
    assert stored.lock_version == 1
    refute is_nil(stored.decided_at)
  end
end
