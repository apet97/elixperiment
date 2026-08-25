defmodule PumbleAutomation.Workflows.ActivationTest do
  @moduledoc """
  Activation is one transaction: either the new version, bindings, schedules,
  live pointer, and audit row all exist, or none of them do.
  """

  # This module installs a table-wide failure trigger for rollback proof.
  use PumbleAutomation.DataCase, async: false

  import PumbleAutomation.WorkflowsFixtures
  import ExUnit.CaptureLog

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.Endpoints
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.ScheduleCalculator
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  setup do
    %{installation: installation, member: member} = InstallationsFixtures.install()

    %{
      scope: Scope.new(member),
      installation: installation,
      installation_id: installation.id
    }
  end

  describe "activate_workflow/3" do
    test "compiles, versions, projects bindings, and points the workflow at the version",
         context do
      workflow = activatable(context.installation_id)

      assert {:ok, result} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert result.workflow.status == "active"
      assert result.workflow.active_version_id == result.version.id
      assert result.workflow.draft_revision == 1
      assert result.version.version_number == 1
      assert result.version.compiler_version == "1"
      assert is_map(result.version.compiled_definition)
      assert result.version.activated_at
      assert result.warnings == []

      assert [binding] =
               Repo.all(
                 TriggerBinding.matching(context.installation_id,
                   kind: "pumble_event",
                   type: "NEW_MESSAGE",
                   channel_id: "channel-1"
                 )
               )

      assert binding.workflow_version_id == result.version.id
      assert binding.enabled

      assert [event] = audit_events(context.installation_id, "workflow.activated")
      assert event.resource_id == workflow.id
      assert event.metadata["previous_state"] == "draft"
      assert event.metadata["next_state"] == "active"
    end

    test "reuses a version whose content hash already exists", context do
      workflow = activatable(context.installation_id)
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)

      assert {:ok, second} = Workflows.activate_workflow(context.scope, workflow.id, 1)

      assert second.version.id == first.version.id

      versions =
        Repo.all(from v in WorkflowVersion, where: v.workflow_id == ^workflow.id)

      assert length(versions) == 1
    end

    test "reuses an exact previous-release snapshot written during the expand migration",
         context do
      workflow = activatable(context.installation_id)
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)

      Repo.update_all(
        from(version in WorkflowVersion, where: version.id == ^first.version.id),
        set: [source_hash: nil, identity_hash: nil]
      )

      legacy = Repo.get!(WorkflowVersion, first.version.id)
      assert WorkflowVersion.legacy_intact?(legacy)

      assert {:ok, second} = Workflows.activate_workflow(context.scope, workflow.id, 1)
      assert second.version.id == first.version.id

      assert Repo.aggregate(
               from(version in WorkflowVersion, where: version.workflow_id == ^workflow.id),
               :count
             ) == 1
    end

    test "materializes one version-bound webhook and reveals encrypted credentials only once",
         context do
      definition =
        Definition.new(
          Trigger.new(:webhook, %{require_signature: true}),
          [delay_node()]
        )

      workflow = activatable(context.installation_id, definition)

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   Workflows.activate_workflow(context.scope, workflow.id, 0)

          send(self(), {:webhook_activation, result})
        end)

      assert_receive {:webhook_activation, result}
      reveal = result.webhook_credentials

      assert reveal.signature_header == WebhookService.signature_header()
      assert reveal.url == Endpoints.public_url(reveal.public_id)
      assert is_binary(reveal.token)
      assert is_binary(reveal.signing_secret)

      assert [endpoint] =
               Repo.all(
                 from endpoint in WebhookEndpoint,
                   where:
                     endpoint.workflow_id == ^workflow.id and
                       (endpoint.enabled or endpoint.signature_enabled)
               )

      assert endpoint.workflow_version_id == result.version.id
      assert endpoint.id == reveal.endpoint_id
      assert endpoint.require_signature
      refute endpoint.enabled
      assert endpoint.signature_enabled
      assert WebhookEndpoint.enabled?(endpoint)
      assert is_nil(endpoint.signing_secret)
      refute inspect(endpoint) =~ reveal.signing_secret
      refute log =~ reveal.signing_secret
      refute log =~ reveal.token

      assert {:ok, token} = Base.url_decode64(reveal.token, padding: false)
      assert WebhookEndpoint.authenticates?(endpoint, token)

      authenticated = Repo.one!(WebhookEndpoint.by_public_id_for_auth(endpoint.public_id))
      assert authenticated.signing_secret == reveal.signing_secret

      raw_body = ~s({"exact": true})
      signature = WebhookEndpoint.sign_body(reveal.signing_secret, raw_body)
      assert WebhookEndpoint.signature_valid?(authenticated, signature, raw_body)

      assert %{rows: [[ciphertext]]} =
               Repo.query!("SELECT signing_secret FROM webhook_endpoints WHERE id = $1", [
                 Ecto.UUID.dump!(endpoint.id)
               ])

      refute ciphertext == reveal.signing_secret
      assert :nomatch == :binary.match(ciphertext, reveal.signing_secret)

      assert {:ok, [listed]} = Endpoints.list(context.scope)
      refute Map.has_key?(listed, :signing_secret)
      refute inspect(listed) =~ reveal.signing_secret
    end

    test "replacing a webhook version disables the obsolete endpoint", context do
      first_definition =
        Definition.new(Trigger.new(:webhook, %{require_signature: false}), [delay_node()])

      workflow = activatable(context.installation_id, first_definition)
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      [first_endpoint] =
        Repo.all(from endpoint in WebhookEndpoint, where: endpoint.workflow_id == ^workflow.id)

      second_definition =
        Definition.new(
          Trigger.new(:webhook, %{require_signature: true}),
          [delay_node(), stop_node()]
        )

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          workflow.id,
          second_definition,
          first.workflow.draft_revision
        )

      {:ok, second} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      endpoints =
        Repo.all(
          from endpoint in WebhookEndpoint,
            where: endpoint.workflow_id == ^workflow.id,
            order_by: endpoint.inserted_at
        )

      assert length(endpoints) == 2
      assert Repo.get!(WebhookEndpoint, first_endpoint.id).enabled == false
      assert [current] = Enum.filter(endpoints, &WebhookEndpoint.enabled?/1)
      assert current.workflow_version_id == second.version.id
      assert current.require_signature

      old_raw_body = ~s({"old":true})

      assert {:error, %Error{class: :not_found, code: :endpoint_disabled}} =
               WebhookService.accept(first_endpoint.public_id, %{
                 raw_body: old_raw_body,
                 content_type: "application/json",
                 authorization: "Bearer " <> first.webhook_credentials.token,
                 body: %{"old" => true},
                 headers: %{},
                 remote_ip: {:activation_test, self()}
               })
    end

    test "an editor activates a webhook but does not receive owner credentials", context do
      definition =
        Definition.new(Trigger.new(:webhook, %{require_signature: true}), [delay_node()])

      workflow = activatable(context.installation_id, definition)
      editor = editor_scope(context.installation_id)

      assert {:ok, result} = Workflows.activate_workflow(editor, workflow.id, 0)
      assert is_nil(result.webhook_credentials)

      assert Repo.exists?(
               from endpoint in WebhookEndpoint,
                 where:
                   endpoint.workflow_id == ^workflow.id and
                     (endpoint.enabled or endpoint.signature_enabled)
             )
    end

    test "replaces trigger bindings when a new version is activated", context do
      first_definition = definition([delay_node()])
      workflow = activatable(context.installation_id, first_definition)
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      second_definition =
        Definition.new(
          Trigger.new(:pumble_event, %{event: :new_message, channel_ids: ["channel-2"]}),
          [delay_node()]
        )

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          workflow.id,
          second_definition,
          first.workflow.draft_revision
        )

      {:ok, second} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      assert second.version.id != first.version.id

      old_bindings =
        Repo.all(from b in TriggerBinding, where: b.workflow_version_id == ^first.version.id)

      assert old_bindings != []
      assert Enum.all?(old_bindings, &(&1.enabled == false))

      assert [] ==
               Repo.all(
                 TriggerBinding.matching(context.installation_id,
                   kind: "pumble_event",
                   type: "NEW_MESSAGE",
                   channel_id: "channel-1"
                 )
               )

      assert [%{workflow_version_id: version_id}] =
               Repo.all(
                 TriggerBinding.matching(context.installation_id,
                   kind: "pumble_event",
                   type: "NEW_MESSAGE",
                   channel_id: "channel-2"
                 )
               )

      assert version_id == second.version.id
    end

    test "replaces the schedule projection when the trigger is a clock", context do
      definition =
        Definition.new(
          Trigger.new(:schedule, %{
            schedule_type: :daily,
            time_of_day: "09:00",
            timezone: "Etc/UTC"
          }),
          [delay_node()]
        )

      workflow = activatable(context.installation_id, definition)
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert [schedule] =
               Repo.all(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

      assert schedule.workflow_version_id == first.version.id
      assert schedule.schedule_type == "daily"
      assert %DateTime{} = schedule.next_run_at

      later =
        Definition.new(
          Trigger.new(:schedule, %{
            schedule_type: :every_minutes,
            interval: 15,
            timezone: "Etc/UTC"
          }),
          [delay_node(), delay_node()]
        )

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          workflow.id,
          later,
          first.workflow.draft_revision
        )

      {:ok, second} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      schedules = Repo.all(from s in Schedule, where: s.workflow_id == ^workflow.id)
      enabled = Enum.filter(schedules, & &1.enabled)
      disabled = Enum.reject(schedules, & &1.enabled)

      assert length(disabled) == 1
      assert hd(disabled).id == schedule.id
      assert [%{workflow_version_id: version_id, schedule_type: "every_minutes"}] = enabled
      assert version_id == second.version.id
    end

    test "materializes a naive one-time instant in its configured IANA timezone", context do
      future = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      local = DateTime.shift_zone!(future, "Europe/Belgrade")

      schedule_config = %{
        schedule_type: :once,
        run_at: local |> DateTime.to_naive() |> NaiveDateTime.to_iso8601(),
        timezone: "Europe/Belgrade"
      }

      assert {:ok, expected} =
               ScheduleCalculator.next(schedule_config, DateTime.add(future, -1, :day))

      definition =
        Definition.new(
          Trigger.new(:schedule, schedule_config),
          [delay_node()]
        )

      workflow = activatable(context.installation_id, definition)
      assert {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert %Schedule{workflow_version_id: version_id, next_run_at: next_run_at} =
               Repo.one!(
                 from schedule in Schedule,
                   where: schedule.workflow_id == ^workflow.id and schedule.enabled
               )

      assert version_id == activated.version.id
      assert next_run_at == expected
    end

    test "leaves an earlier version intact so a running execution can keep it", context do
      workflow = activatable(context.installation_id, definition([delay_node()]))
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          workflow.id,
          definition([delay_node(), delay_node()]),
          first.workflow.draft_revision
        )

      {:ok, second} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      stored = Repo.get!(WorkflowVersion, first.version.id)

      assert stored.id != second.version.id
      assert stored.compiled_definition == first.version.compiled_definition
      assert stored.definition_hash == first.version.definition_hash
      assert WorkflowVersion.intact?(stored)
      assert second.workflow.active_version_id == second.version.id
    end

    test "returns warnings without blocking", context do
      definition = definition([stop_node(), delay_node()])
      workflow = activatable(context.installation_id, definition)

      assert {:ok, result} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      assert Enum.map(result.warnings, & &1.code) == [:unreachable_after_stop]
      assert result.workflow.status == "active"
    end

    test "an editor may activate", context do
      workflow = activatable(context.installation_id)
      editor = editor_scope(context.installation_id)

      assert {:ok, result} = Workflows.activate_workflow(editor, workflow.id, 0)
      assert result.workflow.status == "active"
    end

    test "a viewer may not", context do
      workflow = activatable(context.installation_id)
      viewer = viewer_scope(context.installation_id)

      assert {:error, %Error{class: :permission}} =
               Workflows.activate_workflow(viewer, workflow.id, 0)

      assert Repo.get!(Workflow, workflow.id).status == "draft"
    end

    test "answers not_found across workspaces", context do
      workflow = activatable(context.installation_id)
      other = InstallationsFixtures.install()

      assert {:error, error} =
               Workflows.activate_workflow(Scope.new(other.member), workflow.id, 0)

      assert error == unknown_id_error(Scope.new(other.member))
      assert Repo.get!(Workflow, workflow.id).status == "draft"
    end
  end

  describe "transaction rollback" do
    test "an invalid draft writes no version, binding, schedule, or audit", context do
      workflow = activatable(context.installation_id, definition([]))

      assert {:error, %Error{class: :validation, code: :activation_blocked} = error} =
               Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert Enum.any?(error.details.issues, &(&1.code == :no_steps))
      assert_no_activation(context.installation_id, workflow.id)
    end

    test "a stale draft revision writes nothing", context do
      workflow = activatable(context.installation_id)

      assert {:error, %Error{class: :conflict, code: :draft_revision_conflict} = error} =
               Workflows.activate_workflow(context.scope, workflow.id, 9)

      assert error.details.current_revision == 0
      assert_no_activation(context.installation_id, workflow.id)
    end

    test "an archived workflow writes nothing", context do
      workflow =
        activatable(context.installation_id, definition([delay_node()]), %{
          status: "archived",
          archived_at: DateTime.utc_now()
        })

      assert {:error, %Error{class: :conflict, code: :already_archived}} =
               Workflows.activate_workflow(context.scope, workflow.id, 0)

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "archived"
      assert is_nil(stored.active_version_id)
      refute Repo.exists?(from v in WorkflowVersion, where: v.workflow_id == ^workflow.id)
    end

    test "a revoked installation writes nothing", context do
      workflow = activatable(context.installation_id)
      revoke!(context.installation)

      assert {:error, %Error{class: :permission, code: :installation_revoked}} =
               Workflows.activate_workflow(context.scope, workflow.id, 0)

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "draft"
      assert is_nil(stored.active_version_id)
    end

    test "a scope omitted from the recorded install request writes nothing and returns the full issue list",
         context do
      record_requested_scopes!(context.installation, ["channels:read"])
      workflow = activatable(context.installation_id, definition([message_node()]))

      assert {:error, %Error{class: :validation, code: :activation_blocked} = error} =
               Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert Enum.map(error.details.issues, & &1.code) == [:scope_missing]
      assert Enum.all?(error.details.issues, &(&1.severity == :error))
      assert_no_activation(context.installation_id, workflow.id)
    end

    test "a missing secret writes nothing", context do
      connection = ConnectionsFixtures.connection(context.scope)

      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          connection_id: connection.id,
          body: "token={{ secret.API_TOKEN }}"
        })

      workflow = activatable(context.installation_id, definition([node]))

      assert {:error, %Error{class: :validation, code: :activation_blocked} = error} =
               Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert Enum.any?(error.details.issues, &(&1.code == :secret_not_found))
      assert_no_activation(context.installation_id, workflow.id)
    end

    test "a taken manual alias rolls the version insert back", context do
      held =
        activatable(
          context.installation_id,
          Definition.new(
            Trigger.new(:manual, %{manual_alias: "deploy", slash_command: true}),
            [delay_node()]
          )
        )

      {:ok, _} = Workflows.activate_workflow(context.scope, held.id, 0)

      challenger =
        activatable(
          context.installation_id,
          Definition.new(
            Trigger.new(:manual, %{manual_alias: "deploy", slash_command: true}),
            [delay_node()]
          ),
          %{name: "Other", slug: "other-#{System.unique_integer([:positive])}"}
        )

      assert {:error, %Error{class: :conflict, code: :alias_taken}} =
               Workflows.activate_workflow(context.scope, challenger.id, 0)

      stored = Repo.get!(Workflow, challenger.id)
      assert stored.status == "draft"
      assert is_nil(stored.active_version_id)

      refute Repo.exists?(from v in WorkflowVersion, where: v.workflow_id == ^challenger.id)

      assert [] ==
               audit_events(context.installation_id, "workflow.activated")
               |> Enum.filter(&(&1.resource_id == challenger.id))
    end

    test "a rejected audit row rolls every activation write back", context do
      workflow =
        activatable(
          context.installation_id,
          Definition.new(Trigger.new(:webhook, %{require_signature: true}), [delay_node()])
        )

      reject_audit!("workflow.activated")

      assert {:error, %Error{code: :audit_write_failed}} =
               Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert_no_activation(context.installation_id, workflow.id)
    end
  end

  defp activatable(installation_id, definition \\ definition([delay_node()]), attrs \\ %{})

  defp activatable(installation_id, %Definition{} = definition, attrs) do
    drafted_workflow(
      installation_id,
      Map.merge(%{draft_definition: Definition.encode(definition)}, attrs)
    )
  end

  defp assert_no_activation(installation_id, workflow_id) do
    stored = Repo.get!(Workflow, workflow_id)
    assert stored.status == "draft"
    assert is_nil(stored.active_version_id)
    refute Repo.exists?(from v in WorkflowVersion, where: v.workflow_id == ^workflow_id)
    refute Repo.exists?(from b in TriggerBinding, where: b.installation_id == ^installation_id)

    refute Repo.exists?(
             from s in Schedule,
               where: s.workflow_id == ^workflow_id
           )

    refute Repo.exists?(
             from endpoint in WebhookEndpoint,
               where: endpoint.workflow_id == ^workflow_id
           )

    assert [] ==
             Enum.filter(
               audit_events(installation_id, "workflow.activated"),
               &(&1.resource_id == workflow_id)
             )
  end

  defp record_requested_scopes!(installation, scopes) do
    installation
    |> Installation.changeset(%{bot_scopes: scopes})
    |> Repo.update!()
  end

  defp revoke!(installation) do
    installation
    |> Installation.changeset(%{status: "revoked"})
    |> Repo.update!()
  end

  defp reject_audit!(action) do
    suffix = System.unique_integer([:positive])
    name = "reject_audit_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'audit rejected';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{name}
    BEFORE INSERT ON audit_events
    FOR EACH ROW
    WHEN (NEW.action = '#{action}')
    EXECUTE FUNCTION #{name}()
    """)

    :ok
  end

  defp audit_events(installation_id, action) do
    Repo.all(
      from e in AuditEvent,
        where: e.installation_id == ^installation_id and e.action == ^action
    )
  end

  defp unknown_id_error(scope) do
    {:error, error} = Workflows.get_workflow(scope, Ecto.UUID.generate())
    error
  end

  defp viewer_scope(installation_id), do: role_scope(installation_id, "viewer")
  defp editor_scope(installation_id), do: role_scope(installation_id, "editor")

  defp role_scope(installation_id, role) do
    %Scope{
      installation_id: installation_id,
      member_id: member_id(installation_id),
      role: role
    }
  end

  defp member_id(installation_id) do
    Repo.one!(
      from m in "workspace_members",
        where: m.installation_id == ^Ecto.UUID.dump!(installation_id),
        limit: 1,
        select: type(m.id, Ecto.UUID)
    )
  end
end

defmodule PumbleAutomation.Workflows.ActivationConcurrencyTest do
  @moduledoc """
  Two activations of one draft, run against a real database rather than the
  sandbox. See `WorkflowVersionConcurrencyTest` for why `:auto` is required.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Error
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "concurrent activations produce one winner and a revision conflict" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Workflows.activate_workflow(scope, workflow.id, 0) end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    oks = for {:ok, result} <- results, do: result
    errors = for {:error, %Error{} = error} <- results, do: error

    assert length(oks) == 1
    assert length(errors) == 1
    assert hd(errors).code == :draft_revision_conflict

    winner = hd(oks)
    assert winner.workflow.status == "active"
    assert winner.version.version_number == 1

    stored = Repo.get!(Workflow, workflow.id)
    assert stored.active_version_id == winner.version.id
    assert stored.draft_revision == 1

    versions =
      Repo.all(from v in WorkflowVersion, where: v.workflow_id == ^workflow.id)

    assert length(versions) == 1

    enabled =
      Repo.all(
        from b in TriggerBinding,
          where: b.workflow_version_id == ^winner.version.id and b.enabled
      )

    assert length(enabled) == 1
  end
end
