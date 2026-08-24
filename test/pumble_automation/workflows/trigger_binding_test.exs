defmodule PumbleAutomation.Workflows.TriggerBindingTest do
  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.TriggerBinding

  setup do
    %{installation: %{id: installation_id}} = InstallationsFixtures.install()
    workflow = drafted_workflow(installation_id)
    version = version(workflow)

    %{installation_id: installation_id, workflow: workflow, version: version}
  end

  describe "the migration" do
    test "creates the lookup, identity, and alias indexes" do
      definitions = index_definitions("trigger_bindings")

      assert definitions =~ "trigger_bindings_lookup_index"
      assert definitions =~ "(installation_id, kind, type, channel_id)"
      assert definitions =~ "trigger_bindings_identity_index"
      assert definitions =~ "NULLS NOT DISTINCT"
      assert definitions =~ "trigger_bindings_enabled_alias_index"
      assert definitions =~ "WHERE (enabled AND (alias IS NOT NULL))"
    end

    test "binds only to a version of its own tenant" do
      assert foreign_keys("trigger_bindings") =~ "(workflow_version_id, installation_id)"
    end
  end

  describe "the lookup index" do
    test "serves the event-matching predicate with an index scan", %{
      installation_id: installation_id,
      version: version
    } do
      trigger_binding(version, %{channel_id: "channel-1"})

      plan =
        explain_index_plan(
          TriggerBinding.matching(installation_id,
            kind: "pumble_event",
            type: "NEW_MESSAGE",
            channel_id: "channel-1"
          )
        )

      assert index_backed?(plan)
    end
  end

  describe "matching/2" do
    test "finds a binding that names the channel", %{
      installation_id: installation_id,
      version: version
    } do
      wanted = trigger_binding(version, %{channel_id: "channel-1"})
      _other = trigger_binding(version, %{channel_id: "channel-2"})

      assert [found] =
               Repo.all(
                 TriggerBinding.matching(installation_id,
                   kind: "pumble_event",
                   type: "NEW_MESSAGE",
                   channel_id: "channel-1"
                 )
               )

      assert found.id == wanted.id
    end

    test "finds a binding that names no channel, whatever the channel is", %{
      installation_id: installation_id,
      version: version
    } do
      everywhere = trigger_binding(version, %{channel_id: nil})

      for channel <- ~w(channel-1 channel-9) do
        assert [found] =
                 Repo.all(
                   TriggerBinding.matching(installation_id,
                     kind: "pumble_event",
                     type: "NEW_MESSAGE",
                     channel_id: channel
                   )
                 )

        assert found.id == everywhere.id
      end
    end

    test "never matches a disabled binding", %{
      installation_id: installation_id,
      version: version
    } do
      trigger_binding(version, %{channel_id: "channel-1", enabled: false})

      assert [] ==
               Repo.all(
                 TriggerBinding.matching(installation_id,
                   kind: "pumble_event",
                   type: "NEW_MESSAGE",
                   channel_id: "channel-1"
                 )
               )
    end

    test "never matches another tenant's binding", %{version: version} do
      trigger_binding(version, %{channel_id: "channel-1"})
      other = InstallationsFixtures.install()

      assert [] ==
               Repo.all(
                 TriggerBinding.matching(other.installation.id,
                   kind: "pumble_event",
                   type: "NEW_MESSAGE",
                   channel_id: "channel-1"
                 )
               )
    end

    test "does not cross trigger classes", %{
      installation_id: installation_id,
      version: version
    } do
      trigger_binding(version, %{kind: "manual", type: "manual", alias: "deploy"})

      assert [] ==
               Repo.all(
                 TriggerBinding.matching(installation_id,
                   kind: "pumble_event",
                   type: "NEW_MESSAGE"
                 )
               )
    end
  end

  describe "binding identity" do
    test "refuses a second identical binding on one version", %{version: version} do
      trigger_binding(version, %{channel_id: "channel-1"})

      assert {:error, changeset} =
               %TriggerBinding{}
               |> TriggerBinding.changeset(%{
                 installation_id: version.installation_id,
                 workflow_version_id: version.id,
                 kind: "pumble_event",
                 type: "NEW_MESSAGE",
                 channel_id: "channel-1"
               })
               |> Repo.insert()

      refute changeset.valid?
    end

    test "treats two absent channels as the same identity, not two", %{version: version} do
      trigger_binding(version, %{channel_id: nil})

      assert {:error, _changeset} =
               %TriggerBinding{}
               |> TriggerBinding.changeset(%{
                 installation_id: version.installation_id,
                 workflow_version_id: version.id,
                 kind: "pumble_event",
                 type: "NEW_MESSAGE"
               })
               |> Repo.insert()
    end
  end

  describe "the manual alias" do
    test "may be held by only one enabled binding per installation", %{
      installation_id: installation_id,
      version: version
    } do
      trigger_binding(version, %{kind: "manual", type: "manual", alias: "deploy"})

      second = version(drafted_workflow(installation_id, %{name: "Second"}))

      assert {:error, changeset} =
               %TriggerBinding{}
               |> TriggerBinding.changeset(%{
                 installation_id: installation_id,
                 workflow_version_id: second.id,
                 kind: "manual",
                 type: "manual",
                 alias: "deploy"
               })
               |> Repo.insert()

      assert %{alias: [_message]} = errors_on(changeset)
    end

    test "may be reused once the holder is disabled", %{
      installation_id: installation_id,
      version: version
    } do
      held = trigger_binding(version, %{kind: "manual", type: "manual", alias: "deploy"})

      held
      |> TriggerBinding.changeset(%{enabled: false})
      |> Repo.update!()

      second = version(drafted_workflow(installation_id, %{name: "Second"}))

      assert {:ok, _binding} =
               %TriggerBinding{}
               |> TriggerBinding.changeset(%{
                 installation_id: installation_id,
                 workflow_version_id: second.id,
                 kind: "manual",
                 type: "manual",
                 alias: "deploy"
               })
               |> Repo.insert()
    end

    test "is free in another workspace at the same time", %{version: version} do
      trigger_binding(version, %{kind: "manual", type: "manual", alias: "deploy"})

      other = InstallationsFixtures.install()
      other_version = version(drafted_workflow(other.installation.id))

      assert {:ok, _binding} =
               %TriggerBinding{}
               |> TriggerBinding.changeset(%{
                 installation_id: other.installation.id,
                 workflow_version_id: other_version.id,
                 kind: "manual",
                 type: "manual",
                 alias: "deploy"
               })
               |> Repo.insert()
    end

    test "by_alias/2 resolves only the enabled holder", %{
      installation_id: installation_id,
      version: version
    } do
      held = trigger_binding(version, %{kind: "manual", type: "manual", alias: "deploy"})

      assert [found] = Repo.all(TriggerBinding.by_alias(installation_id, "deploy"))
      assert found.id == held.id

      held |> TriggerBinding.changeset(%{enabled: false}) |> Repo.update!()

      assert [] == Repo.all(TriggerBinding.by_alias(installation_id, "deploy"))
    end
  end

  describe "changeset/2" do
    test "requires a tenant, a version, and a class" do
      changeset = TriggerBinding.changeset(%TriggerBinding{}, %{})

      assert %{installation_id: [_], workflow_version_id: [_], kind: [_]} = errors_on(changeset)
    end

    test "refuses an unknown class", %{version: version} do
      changeset =
        TriggerBinding.changeset(%TriggerBinding{}, %{
          installation_id: version.installation_id,
          workflow_version_id: version.id,
          kind: "telepathy"
        })

      assert %{kind: [_message]} = errors_on(changeset)
    end
  end

  describe "project/3" do
    test "gives one row per channel a Pumble event trigger names", %{version: version} do
      trigger =
        Trigger.new(:pumble_event, %{
          event: :new_message,
          channel_ids: ["channel-1", "channel-2"],
          keyword: "deploy"
        })

      rows = TriggerBinding.project(trigger, version.installation_id, version.id)

      assert length(rows) == 2
      assert Enum.map(rows, & &1.channel_id) == ["channel-1", "channel-2"]
      assert Enum.all?(rows, &(&1.type == "NEW_MESSAGE"))
      assert Enum.all?(rows, &(&1.filter_config["keyword"] == "deploy"))
    end

    test "gives one channel-less row when the trigger names none", %{version: version} do
      trigger = Trigger.new(:pumble_event, %{event: :reaction_added})

      assert [row] = TriggerBinding.project(trigger, version.installation_id, version.id)
      assert row.channel_id == nil
      assert row.type == "REACTION_ADDED"
    end

    test "gives one row for a manual trigger, whatever entry points it opens", %{
      version: version
    } do
      trigger =
        Trigger.new(:manual, %{
          manual_alias: "deploy",
          slash_command: true,
          global_shortcut: true,
          message_shortcut: true
        })

      assert [row] = TriggerBinding.project(trigger, version.installation_id, version.id)
      assert row.alias == "deploy"
      assert row.filter_config["global_shortcut"]
    end

    test "projects rows the database accepts", %{version: version} do
      trigger = Trigger.new(:pumble_event, %{event: :new_message, channel_ids: ["c1", "c2"]})

      for attrs <- TriggerBinding.project(trigger, version.installation_id, version.id) do
        assert {:ok, _row} =
                 %TriggerBinding{} |> TriggerBinding.changeset(attrs) |> Repo.insert()
      end
    end
  end

  defp index_definitions(table) do
    %{rows: rows} = Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])
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
end

defmodule PumbleAutomation.Workflows.TriggerBindingAliasRaceTest do
  @moduledoc """
  Several writers reaching for one manual alias at once.

  Like the version-number race, this cannot run inside the SQL sandbox: a
  partial unique index only refuses a duplicate another transaction has
  actually committed, and the sandbox commits nothing. So the repository runs
  in `:auto` mode here, the rows are really written, and `on_exit/1` erases the
  installation whether the test passes or fails.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.TriggerBinding

  @writers 6

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "exactly one writer wins the enabled manual alias" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    versions =
      for index <- 1..@writers do
        installation.id
        |> drafted_workflow(%{name: "Workflow #{index}"})
        |> version(%{
          source_definition: definition(Enum.map(1..index, fn _ -> message_node() end))
        })
      end

    outcomes =
      versions
      |> Task.async_stream(
        fn version ->
          %TriggerBinding{}
          |> TriggerBinding.changeset(%{
            installation_id: installation.id,
            workflow_version_id: version.id,
            kind: "manual",
            type: "manual",
            alias: "deploy"
          })
          |> Repo.insert()
        end,
        max_concurrency: @writers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(outcomes, &match?({:ok, _binding}, &1)) == 1
    assert Enum.count(outcomes, &match?({:error, _changeset}, &1)) == @writers - 1

    held =
      Repo.all(
        from b in TriggerBinding,
          where: b.installation_id == ^installation.id and b.alias == "deploy" and b.enabled
      )

    assert length(held) == 1
  end
end
