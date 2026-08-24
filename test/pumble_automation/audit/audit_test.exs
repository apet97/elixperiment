defmodule PumbleAutomation.Audit.AuditTest do
  @moduledoc """
  P13-T06: actor vocabulary, flood-limited denied audit, append-only API,
  and tenant-scoped support operations.
  """

  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.EchoWorker
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.ExecutionsFixtures
  alias PumbleAutomation.Ingress.RateLimiter
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Operations
  alias PumbleAutomation.Scope

  setup do
    RateLimiter.reset()
    %{installation: installation, member: member} = InstallationsFixtures.install()
    %{scope: Scope.new(member), installation: installation, member: member}
  end

  describe "actor classifications" do
    test "system, job, browser user, and Pumble user are the only actor types", %{scope: scope} do
      assert Enum.sort(AuditEvent.actor_types()) == ["job", "pumble_user", "system", "user"]

      assert Writer.actor(:system) == %{actor_type: "system", actor_id: "application"}

      assert Writer.actor({:job, AdvanceExecutionWorker}) == %{
               actor_type: "job",
               actor_id: "advance_execution_worker"
             }

      assert Writer.actor({:pumble, "pumble-user-9"}) == %{
               actor_type: "pumble_user",
               actor_id: "pumble-user-9"
             }

      assert Writer.actor(scope) == %{actor_type: "user", actor_id: scope.member_id}
    end

    test "classified actors persist on an audit row", %{scope: scope} do
      for actor <- [
            Writer.actor(:system),
            Writer.actor({:job, "reconciliation_worker"}),
            Writer.actor(scope),
            Writer.actor({:pumble, "approver-1"})
          ] do
        assert {:ok, %{audit: event}} =
                 Ecto.Multi.new()
                 |> Writer.append(
                   :audit,
                   Map.merge(actor, %{
                     installation_id: scope.installation_id,
                     action: "admin.job_requeued",
                     resource_type: "installation",
                     resource_id: scope.installation_id
                   })
                 )
                 |> Repo.transaction()

        assert event.actor_type == actor.actor_type
        assert event.actor_id == actor.actor_id
      end
    end
  end

  describe "metadata redaction" do
    test "secret-shaped keys are refused and never stored", %{scope: scope} do
      before = Repo.aggregate(AuditEvent, :count)

      assert {:error, :audit, changeset, _} =
               Ecto.Multi.new()
               |> Writer.append(:audit, %{
                 installation_id: scope.installation_id,
                 actor_type: "user",
                 actor_id: scope.member_id,
                 action: "admin.diagnostics_exported",
                 metadata: %{token: "leaked", reason: "export"}
               })
               |> Repo.transaction()

      refute changeset.valid?
      assert Repo.aggregate(AuditEvent, :count) == before
    end

    test "a diagnostics export contains no secret values or foreign tenants", %{
      scope: scope,
      installation: installation
    } do
      %{installation: other} = InstallationsFixtures.install()

      assert {:ok, bundle} = Operations.export_diagnostics(scope)
      encoded = Jason.encode!(bundle)

      assert bundle["installation"]["id"] == installation.id
      refute encoded =~ other.pumble_workspace_id
      refute encoded =~ "encrypted"
      refute encoded =~ "token"
      refute encoded =~ "[REDACTED]"

      assert Enum.sort(Map.keys(bundle["installation"])) ==
               Enum.sort(~w(bot_scopes deletion_scheduled_at id status user_scopes workspace_id))
    end
  end

  describe "append-only API" do
    test "the writer and schema still expose no update or delete" do
      assert mutating_functions(Writer) == []
      assert mutating_functions(AuditEvent) == []
    end

    test "support operations are a finite named catalogue" do
      assert Operations.operations() == [
               :requeue_safe_job,
               :run_reconciliation,
               :export_diagnostics,
               :initiate_tenant_deletion
             ]

      refute Operations.operation?(:sql)
      refute function_exported?(Operations, :query, 1)
      refute function_exported?(Operations, :eval, 1)
    end

    test "audit_events has no prior-event hash column" do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'audit_events'"
        )

      names = Enum.map(rows, fn [name] -> name end)
      refute "prior_event_hash" in names
      refute "updated_at" in names
    end
  end

  describe "flood limiting" do
    test "repeated denied interaction audit is capped per actor and action", %{scope: scope} do
      attrs = fn ->
        %{
          installation_id: scope.installation_id,
          actor_type: "pumble_user",
          actor_id: "flood-actor",
          action: "execution.interaction_denied",
          resource_type: "installation",
          resource_id: scope.installation_id,
          metadata: %{reason: "not_found", result: "denied", source: "pumble_callback"}
        }
      end

      results =
        Enum.map(1..(Writer.denied_per_minute() + 3), fn _index ->
          Writer.append_denied(attrs.())
        end)

      assert Enum.all?(results, &(&1 == :ok))

      count =
        Repo.aggregate(
          from(event in AuditEvent,
            where: event.action == "execution.interaction_denied",
            where: event.actor_id == "flood-actor"
          ),
          :count
        )

      assert count == Writer.denied_per_minute()
    end
  end

  describe "atomic audit rollback" do
    test "an unsafe requeue writes no audit row", %{scope: scope, installation: installation} do
      job =
        discarded_job!(installation.id, EchoWorker, %{
          installation_id: installation.id,
          id: Ecto.UUID.generate()
        })

      assert {:error, %Error{code: :unsafe_repair}} = Operations.requeue_safe_job(scope, job.id)

      assert Repo.aggregate(
               from(e in AuditEvent, where: e.action == "admin.job_requeued"),
               :count
             ) == 0
    end
  end

  describe "cross-tenant support action" do
    test "another workspace's job is not found and is not retried", %{scope: scope} do
      %{installation: other, member: other_member} = InstallationsFixtures.install()

      job =
        discarded_job!(other.id, AdvanceExecutionWorker, %{
          "installation_id" => other.id,
          "execution_id" => Ecto.UUID.generate(),
          "expected_node_id" => Ecto.UUID.generate(),
          "generation" => 0
        })

      assert {:error, %Error{class: :not_found, code: :resource_not_found}} =
               Operations.requeue_safe_job(scope, job.id)

      assert Repo.get!(Oban.Job, job.id).state == "discarded"
      assert {:ok, foreign} = Operations.export_diagnostics(Scope.new(other_member))
      refute foreign["installation"]["id"] == scope.installation_id
    end

    test "an editor cannot run support operations", %{installation: installation, member: member} do
      editor = Scope.new(InstallationsFixtures.set_role(member, "editor"))

      job =
        discarded_job!(installation.id, AdvanceExecutionWorker, %{
          "installation_id" => installation.id,
          "execution_id" => Ecto.UUID.generate(),
          "expected_node_id" => Ecto.UUID.generate(),
          "generation" => 0
        })

      assert {:error, %Error{class: :permission}} = Operations.requeue_safe_job(editor, job.id)
      assert {:error, %Error{class: :permission}} = Operations.run_reconciliation(editor)
      assert {:error, %Error{class: :permission}} = Operations.export_diagnostics(editor)
      assert {:error, %Error{class: :permission}} = Operations.initiate_tenant_deletion(editor)
    end
  end

  describe "requeue_safe_job/2" do
    test "a discarded advance job with no attempt is retried and audited", %{
      scope: scope,
      installation: installation
    } do
      job =
        discarded_job!(installation.id, AdvanceExecutionWorker, %{
          "installation_id" => installation.id,
          "execution_id" => Ecto.UUID.generate(),
          "expected_node_id" => Ecto.UUID.generate(),
          "generation" => 0
        })

      assert {:ok, retried} = Operations.requeue_safe_job(scope, job.id)
      assert retried.state == "available"

      event = Repo.get_by!(AuditEvent, action: "admin.job_requeued")
      assert event.actor_type == "user"
      assert event.actor_id == scope.member_id
      assert event.resource_id == Integer.to_string(job.id)
      assert event.metadata["previous_state"] == "discarded"
      assert event.metadata["next_state"] == "available"
      assert event.metadata["source"] == "support"
    end

    test "a job that already opened an attempt is refused", %{
      scope: scope,
      installation: installation
    } do
      job =
        discarded_job!(installation.id, AdvanceExecutionWorker, %{
          "installation_id" => installation.id,
          "execution_id" => Ecto.UUID.generate(),
          "expected_node_id" => Ecto.UUID.generate(),
          "generation" => 0
        })

      version = ExecutionsFixtures.version(installation.id)
      execution = ExecutionsFixtures.execution(version)
      step = ExecutionsFixtures.step_execution(execution)
      {:ok, _attempt} = StepAttempt.create(step, %{oban_job_id: job.id})

      assert {:error, %Error{code: :unsafe_repair}} = Operations.requeue_safe_job(scope, job.id)
      assert Repo.get!(Oban.Job, job.id).state == "discarded"
      assert {:error, %Error{message: message}} = Operations.requeue_safe_job(scope, job.id)
      assert message =~ "Do not repair jobs in SQL"
    end
  end

  describe "run_reconciliation/1" do
    test "an owner reconciliation is audited through the engine", %{scope: scope} do
      assert {:ok, %{count: 0}} = Operations.run_reconciliation(scope)
    end
  end

  describe "initiate_tenant_deletion/1" do
    test "an owner starts uninstall and the lifecycle audit records the actor", %{
      scope: scope,
      installation: installation
    } do
      assert {:ok, %{installation: deleted, scheduled_at: %DateTime{}}} =
               Operations.initiate_tenant_deletion(scope)

      assert deleted.status == "uninstalled"
      assert deleted.id == installation.id

      event = Repo.get_by!(AuditEvent, action: "installation.uninstalled")
      assert event.actor_type == "user"
      assert event.actor_id == scope.member_id
      assert event.metadata["reason"] == "owner_requested"
      assert event.metadata["next_state"] == "uninstalled"
    end

    test "a deleted tenant cannot be deleted again", %{scope: scope} do
      assert {:ok, %{installation: uninstalled}} = Operations.initiate_tenant_deletion(scope)

      uninstalled
      |> Installation.changeset(%{status: "deleted"})
      |> Repo.update!()

      assert {:error, %Error{code: :already_deleted}} = Operations.initiate_tenant_deletion(scope)
    end
  end

  defp discarded_job!(_installation_id, worker, args) do
    {:ok, job} = args |> worker.new() |> Oban.insert()

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "discarded", discarded_at: DateTime.utc_now()]
      )

    Repo.get!(Oban.Job, job.id)
  end

  defp mutating_functions(module) do
    for {name, arity} <- module.__info__(:functions),
        string = Atom.to_string(name),
        String.contains?(string, "update") or String.contains?(string, "delete"),
        do: {name, arity}
  end
end
