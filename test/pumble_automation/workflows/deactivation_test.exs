defmodule PumbleAutomation.Workflows.DeactivationTest do
  @moduledoc """
  Deactivation stops new matching without cancelling runs already bound to a
  version. Reactivation of a prior version re-checks current dependencies.
  """

  # This module installs a table-wide failure trigger for rollback proof.
  use PumbleAutomation.DataCase, async: false

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Connections
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Schedule
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

  describe "deactivate_workflow/2" do
    test "disables bindings and schedules, clears the live pointer, and audits", context do
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
      {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      version = activated.version

      assert {:ok, deactivated} = Workflows.deactivate_workflow(context.scope, workflow.id)

      assert deactivated.status == "inactive"
      assert is_nil(deactivated.active_version_id)

      assert [] ==
               Repo.all(
                 from b in TriggerBinding,
                   where: b.workflow_version_id == ^version.id and b.enabled
               )

      assert [] ==
               Repo.all(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

      assert Repo.get!(WorkflowVersion, version.id)

      assert [event] = audit_events(context.installation_id, "workflow.deactivated")
      assert event.resource_id == workflow.id
      assert event.metadata["previous_state"] == "active"
      assert event.metadata["next_state"] == "inactive"
    end

    test "does not cancel in-flight work: the version row stays", context do
      workflow = activatable(context.installation_id)
      {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)

      stored = Repo.get!(WorkflowVersion, activated.version.id)
      assert WorkflowVersion.intact?(stored)
      assert stored.compiled_definition == activated.version.compiled_definition
    end

    test "disables the active version-bound webhook endpoint", context do
      definition =
        Definition.new(Trigger.new(:webhook, %{require_signature: true}), [delay_node()])

      workflow = activatable(context.installation_id, definition)
      {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert [endpoint] =
               Repo.all(
                 from endpoint in WebhookEndpoint,
                   where:
                     endpoint.workflow_id == ^workflow.id and
                       (endpoint.enabled or endpoint.signature_enabled)
               )

      assert endpoint.workflow_version_id == activated.version.id
      assert {:ok, _workflow} = Workflows.deactivate_workflow(context.scope, workflow.id)
      refute Repo.get!(WebhookEndpoint, endpoint.id).enabled
    end

    test "a workflow that is not running is a typed conflict", context do
      workflow = activatable(context.installation_id)

      assert {:error, %Error{class: :conflict, code: :not_active}} =
               Workflows.deactivate_workflow(context.scope, workflow.id)
    end

    test "deactivating twice is a conflict the second time", context do
      workflow = activatable(context.installation_id)
      {:ok, _} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)

      assert {:error, %Error{class: :conflict, code: :not_active}} =
               Workflows.deactivate_workflow(context.scope, workflow.id)

      assert length(audit_events(context.installation_id, "workflow.deactivated")) == 1
    end

    test "an editor may deactivate", context do
      workflow = activatable(context.installation_id)
      {:ok, _} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      editor = editor_scope(context.installation_id)

      assert {:ok, deactivated} = Workflows.deactivate_workflow(editor, workflow.id)
      assert deactivated.status == "inactive"
    end

    test "a viewer may not", context do
      workflow = activatable(context.installation_id)
      {:ok, _} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      viewer = viewer_scope(context.installation_id)

      assert {:error, %Error{class: :permission}} =
               Workflows.deactivate_workflow(viewer, workflow.id)

      assert Repo.get!(Workflow, workflow.id).status == "active"
    end
  end

  describe "reactivate_workflow/3" do
    test "re-materializes bindings onto a prior immutable version", context do
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

      {:ok, result} = Workflows.reactivate_workflow(context.scope, workflow.id, 1)

      assert result.version.id == first.version.id
      assert result.version.id != second.version.id
      assert result.workflow.active_version_id == first.version.id
      assert result.workflow.status == "active"
      assert WorkflowVersion.intact?(Repo.get!(WorkflowVersion, second.version.id))

      enabled = enabled_bindings(first.version.id)
      assert length(enabled) == 1
      assert enabled_bindings(second.version.id) == []

      assert [event | _] =
               audit_events(context.installation_id, "workflow.activated")
               |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

      assert event.metadata["next_state"] == "active"
    end

    test "after deactivation, a prior version can be brought back", context do
      workflow = activatable(context.installation_id)
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)

      assert {:ok, result} = Workflows.reactivate_workflow(context.scope, workflow.id, 1)

      assert result.version.id == first.version.id
      assert result.workflow.status == "active"
      assert result.workflow.active_version_id == first.version.id
      assert length(enabled_bindings(first.version.id)) == 1
    end

    test "reactivating a webhook version issues a fresh endpoint and leaves the old one disabled",
         context do
      definition =
        Definition.new(Trigger.new(:webhook, %{require_signature: true}), [delay_node()])

      workflow = activatable(context.installation_id, definition)
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      [old_endpoint] = Repo.all(from(endpoint in WebhookEndpoint))

      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)
      {:ok, reactivated} = Workflows.reactivate_workflow(context.scope, workflow.id, 1)

      assert reactivated.version.id == first.version.id
      assert reactivated.webhook_credentials.endpoint_id != old_endpoint.id
      refute Repo.get!(WebhookEndpoint, old_endpoint.id).enabled

      assert [current] =
               Repo.all(
                 from endpoint in WebhookEndpoint,
                   where:
                     endpoint.workflow_id == ^workflow.id and
                       (endpoint.enabled or endpoint.signature_enabled)
               )

      assert current.id == reactivated.webhook_credentials.endpoint_id
      assert current.workflow_version_id == first.version.id
    end

    test "a missing current secret blocks and leaves history untouched", context do
      secret = ConnectionsFixtures.secret(context.scope, %{name: "API_TOKEN"})
      connection = ConnectionsFixtures.connection(context.scope)

      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          connection_id: connection.id,
          body: "token={{ secret.API_TOKEN }}"
        })

      workflow = activatable(context.installation_id, definition([node]))
      {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)

      assert {:ok, _} = Connections.delete_secret(context.scope, secret.id)

      assert {:error, %Error{class: :validation, code: :activation_blocked} = error} =
               Workflows.reactivate_workflow(context.scope, workflow.id, 1)

      assert Enum.any?(error.details.issues, &(&1.code == :secret_not_found))

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "inactive"
      assert is_nil(stored.active_version_id)
      assert enabled_bindings(activated.version.id) == []
      assert WorkflowVersion.intact?(Repo.get!(WorkflowVersion, activated.version.id))
    end

    test "reactivation refuses a resolved-secret rebind until the source is revised",
         context do
      original_secret = ConnectionsFixtures.secret(context.scope, %{name: "API_TOKEN"})
      connection = ConnectionsFixtures.connection(context.scope)

      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          connection_id: connection.id,
          body: "token={{ secret.API_TOKEN }}"
        })

      workflow = activatable(context.installation_id, definition([node]))
      {:ok, first} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)

      assert {:ok, _deleted} = Connections.delete_secret(context.scope, original_secret.id)

      replacement_secret =
        ConnectionsFixtures.secret(context.scope, %{name: "API_TOKEN", value: "replacement"})

      assert {:error,
              %Error{
                class: :conflict,
                code: :snapshot_requires_source_revision,
                message: message
              }} =
               Workflows.reactivate_workflow(context.scope, workflow.id, 1)

      assert message =~ "cannot be reactivated"
      assert message =~ "activate it as a new version"

      assert first.version.referenced_secret_ids == [original_secret.id]
      assert replacement_secret.id != original_secret.id
      assert WorkflowVersion.intact?(Repo.get!(WorkflowVersion, first.version.id))

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "inactive"
      assert is_nil(stored.active_version_id)
      assert Repo.aggregate(WorkflowVersion, :count) == 1
    end

    test "an updated requested-scope snapshot can block reactivation", context do
      record_requested_scopes!(context.installation, ["messages:write"])
      workflow = activatable(context.installation_id, definition([message_node()]))
      {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      record_requested_scopes!(Repo.get!(Installation, context.installation_id), ["channels:read"])

      assert {:error, %Error{class: :validation, code: :activation_blocked} = error} =
               Workflows.reactivate_workflow(context.scope, workflow.id, 1)

      assert Enum.map(error.details.issues, & &1.code) == [:scope_missing]

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "active"
      assert stored.active_version_id == activated.version.id
      assert length(enabled_bindings(activated.version.id)) == 1
    end

    test "answers not_found for a version number nobody has", context do
      workflow = activatable(context.installation_id)
      {:ok, _} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      assert {:error, %Error{class: :not_found}} =
               Workflows.reactivate_workflow(context.scope, workflow.id, 9)
    end

    test "refuses every inconsistent stored version surface without changing live state",
         context do
      workflow = activatable(context.installation_id, definition([delay_node()]))
      {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)
      original = Repo.get!(WorkflowVersion, activated.version.id)
      activation_audits = length(audit_events(context.installation_id, "workflow.activated"))

      changed_source =
        put_in(
          original.source_definition,
          ["steps", Access.at(0), "config", "duration_seconds"],
          61
        )

      corruptions = [
        source_definition: changed_source,
        definition_hash: String.duplicate("0", 64),
        identity_hash: String.duplicate("0", 64),
        compiled_definition: Map.put(original.compiled_definition, "max_path_length", 999),
        compiler_version: "0",
        required_scopes: ["unexpected:scope"],
        referenced_secret_ids: [Ecto.UUID.generate()],
        referenced_connection_ids: [Ecto.UUID.generate()]
      ]

      for {field, corrupted} <- corruptions do
        Repo.update_all(
          from(version in WorkflowVersion, where: version.id == ^original.id),
          set: [{field, corrupted}]
        )

        assert {:error, %Error{class: :conflict, code: :version_integrity_failure}} =
                 Workflows.reactivate_workflow(context.scope, workflow.id, 1)

        stored_workflow = Repo.get!(Workflow, workflow.id)
        assert stored_workflow.status == "inactive"
        assert is_nil(stored_workflow.active_version_id)
        assert enabled_bindings(original.id) == []

        Repo.update_all(
          from(version in WorkflowVersion, where: version.id == ^original.id),
          set: [{field, Map.fetch!(original, field)}]
        )
      end

      assert length(audit_events(context.installation_id, "workflow.activated")) ==
               activation_audits
    end
  end

  describe "audit rollback" do
    test "a rejected audit row rolls deactivation back", context do
      workflow = activatable(context.installation_id)
      {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)
      reject_audit!("workflow.deactivated")

      assert {:error, %Error{code: :audit_write_failed}} =
               Workflows.deactivate_workflow(context.scope, workflow.id)

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "active"
      assert stored.active_version_id == activated.version.id
      assert length(enabled_bindings(activated.version.id)) == 1
      assert audit_events(context.installation_id, "workflow.deactivated") == []
    end
  end

  defp activatable(installation_id, definition \\ definition([delay_node()]), attrs \\ %{})

  defp activatable(installation_id, %Definition{} = definition, attrs) do
    drafted_workflow(
      installation_id,
      Map.merge(%{draft_definition: Definition.encode(definition)}, attrs)
    )
  end

  defp enabled_bindings(version_id) do
    Repo.all(from b in TriggerBinding, where: b.workflow_version_id == ^version_id and b.enabled)
  end

  defp record_requested_scopes!(installation, scopes) do
    installation
    |> Installation.changeset(%{bot_scopes: scopes})
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

defmodule PumbleAutomation.Workflows.DeactivationConcurrencyTest do
  @moduledoc """
  Deactivation versus ingress matching, run against a real database.

  A match that already observed an enabled binding before deactivation
  committed may still exist; after commit, matching is empty. That is the
  documented race, not a defect.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.TriggerBinding

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "after commit, matching is empty; a match that raced may have seen the old row" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, _activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    match_opts = [kind: "pumble_event", type: "NEW_MESSAGE", channel_id: "channel-1"]

    results =
      [:deactivate, :match]
      |> Task.async_stream(
        fn
          :deactivate ->
            Workflows.deactivate_workflow(scope, workflow.id)

          :match ->
            Repo.all(TriggerBinding.matching(installation.id, match_opts))
        end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    match_result = Enum.find(results, &is_list/1)
    deactivate_result = Enum.find(results, &match?({:ok, _}, &1))

    assert {:ok, deactivated} = deactivate_result
    assert deactivated.status == "inactive"
    assert is_list(match_result)
    assert length(match_result) in [0, 1]

    assert [] == Repo.all(TriggerBinding.matching(installation.id, match_opts))

    refute Repo.exists?(
             from b in TriggerBinding,
               join: v in PumbleAutomation.Workflows.WorkflowVersion,
               on: v.id == b.workflow_version_id,
               where: v.workflow_id == ^workflow.id and b.enabled
           )
  end
end
