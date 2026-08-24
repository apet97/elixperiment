defmodule PumbleAutomation.Ingress.TriggerMatcherTest do
  @moduledoc """
  Indexed trigger matching: tenant/type/channel/alias in SQL, small typed
  filters in Elixir, live versions only.

  The query-plan test below is the EXPLAIN fixture for a production-like
  sample: dozens of enabled bindings in one workspace. The plan must be
  index-backed (`index_backed?/1`). Named index existence is asserted from
  `pg_indexes` in `trigger_binding_test.exs`.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Ingress.AutomationEvent
  alias PumbleAutomation.Ingress.InteractionCommand
  alias PumbleAutomation.Ingress.LifecycleCommand
  alias PumbleAutomation.Ingress.TriggerMatcher
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow

  setup do
    %{installation: installation} = InstallationsFixtures.install()
    %{installation: installation, installation_id: installation.id}
  end

  describe "pumble events" do
    test "returns the live version and binding for a matching channel", %{
      installation_id: installation_id
    } do
      {_workflow, version, binding} =
        live_event_binding(installation_id, %{channel_id: "channel-1"})

      _other = live_event_binding(installation_id, %{channel_id: "channel-2"})

      assert [%TriggerMatcher{} = match] =
               TriggerMatcher.match(event(installation_id, channel_id: "channel-1"))

      assert match.binding_id == binding.id
      assert match.workflow_version_id == version.id
    end

    test "a channel-less binding matches any channel", %{installation_id: installation_id} do
      {_workflow, version, binding} = live_event_binding(installation_id, %{channel_id: nil})

      for channel <- ~w(channel-1 channel-9) do
        assert [%TriggerMatcher{binding_id: id, workflow_version_id: version_id}] =
                 TriggerMatcher.match(event(installation_id, channel_id: channel))

        assert id == binding.id
        assert version_id == version.id
      end
    end

    test "a selective binding does not match a different channel", %{
      installation_id: installation_id
    } do
      live_event_binding(installation_id, %{channel_id: "channel-1"})

      assert [] == TriggerMatcher.match(event(installation_id, channel_id: "channel-2"))
    end

    test "applies a keyword filter after indexed selection", %{installation_id: installation_id} do
      live_event_binding(installation_id, %{
        channel_id: "channel-1",
        filter_config: %{"keyword" => "deploy", "ignore_bot_messages" => false}
      })

      assert [] ==
               TriggerMatcher.match(
                 event(installation_id, data: %{text: "please ship it"}, channel_id: "channel-1")
               )

      assert [%TriggerMatcher{}] =
               TriggerMatcher.match(
                 event(installation_id,
                   data: %{text: "please Deploy now"},
                   channel_id: "channel-1"
                 )
               )
    end

    test "ignores bot-authored messages when the projection says so", %{
      installation_id: installation_id
    } do
      live_event_binding(installation_id, %{
        channel_id: "channel-1",
        filter_config: %{"keyword" => nil, "ignore_bot_messages" => true}
      })

      assert [] ==
               TriggerMatcher.match(
                 event(installation_id, bot_origin?: true, channel_id: "channel-1")
               )

      assert [%TriggerMatcher{}] =
               TriggerMatcher.match(
                 event(installation_id, bot_origin?: false, channel_id: "channel-1")
               )
    end

    test "includes bot-authored messages when the projection allows them", %{
      installation_id: installation_id
    } do
      live_event_binding(installation_id, %{
        channel_id: "channel-1",
        filter_config: %{"keyword" => nil, "ignore_bot_messages" => false}
      })

      assert [%TriggerMatcher{}] =
               TriggerMatcher.match(
                 event(installation_id, bot_origin?: true, channel_id: "channel-1")
               )
    end

    test "orders multiple matches stably by version id then binding id", %{
      installation_id: installation_id
    } do
      bindings =
        for index <- 1..3 do
          {_workflow, _version, binding} =
            live_event_binding(installation_id, %{
              channel_id: nil,
              name: "Multi #{index}"
            })

          binding
        end

      expected =
        bindings
        |> Enum.sort_by(&{&1.workflow_version_id, &1.id})
        |> Enum.map(&{&1.workflow_version_id, &1.id})

      first = ids(TriggerMatcher.match(event(installation_id, channel_id: "channel-1")))
      second = ids(TriggerMatcher.match(event(installation_id, channel_id: "channel-9")))

      assert first == expected
      assert second == expected
    end
  end

  describe "tenancy and liveness" do
    test "never returns another tenant's binding", %{installation_id: installation_id} do
      live_event_binding(installation_id, %{channel_id: "channel-1"})
      %{installation: other} = InstallationsFixtures.install()

      assert [] == TriggerMatcher.match(event(other.id, channel_id: "channel-1"))
    end

    test "never returns a disabled binding", %{installation_id: installation_id} do
      live_event_binding(installation_id, %{channel_id: "channel-1", enabled: false})

      assert [] == TriggerMatcher.match(event(installation_id, channel_id: "channel-1"))
    end

    test "never returns a binding whose version is not the live pointer", %{
      installation_id: installation_id
    } do
      workflow = drafted_workflow(installation_id)
      stale = version(workflow)
      live = version(workflow, %{source_definition: definition([delay_node(), stop_node()])})

      workflow
      |> Workflow.changeset(%{status: "active", active_version_id: live.id})
      |> Repo.update!()

      trigger_binding(stale, %{channel_id: "channel-1"})
      {_kept, _version, wanted} = live_binding_on(workflow, live, %{channel_id: "channel-1"})

      assert [%TriggerMatcher{binding_id: id}] =
               TriggerMatcher.match(event(installation_id, channel_id: "channel-1"))

      assert id == wanted.id
    end

    test "never returns a deactivated workflow", %{installation_id: installation_id} do
      {workflow, _version, _binding} =
        live_event_binding(installation_id, %{channel_id: "channel-1"})

      workflow
      |> Workflow.changeset(%{status: "inactive", active_version_id: nil})
      |> Repo.update!()

      assert [] == TriggerMatcher.match(event(installation_id, channel_id: "channel-1"))
    end

    test "never returns an uninstalled installation's binding", %{
      installation: installation,
      installation_id: installation_id
    } do
      live_event_binding(installation_id, %{channel_id: "channel-1"})

      installation
      |> Installation.changeset(%{
        status: "uninstalled",
        uninstalled_at: DateTime.utc_now()
      })
      |> Repo.update!()

      assert [] == TriggerMatcher.match(event(installation_id, channel_id: "channel-1"))
    end

    test "matches the live projection, not a later draft", %{installation_id: installation_id} do
      {workflow, _version, _binding} =
        live_event_binding(installation_id, %{channel_id: "channel-1"})

      draft =
        Definition.new(
          Trigger.new(:pumble_event, %{event: :new_message, channel_ids: ["channel-2"]}),
          [delay_node()]
        )

      workflow
      |> Workflow.changeset(%{draft_definition: Definition.encode(draft)})
      |> Repo.update!()

      assert [%TriggerMatcher{}] =
               TriggerMatcher.match(event(installation_id, channel_id: "channel-1"))

      assert [] == TriggerMatcher.match(event(installation_id, channel_id: "channel-2"))
    end

    test "the candidate query never selects draft or version JSON", %{
      installation_id: installation_id
    } do
      live_event_binding(installation_id, %{channel_id: "channel-1"})

      {sql, _params} =
        Repo.to_sql(
          :all,
          TriggerBinding.candidates(installation_id,
            kind: "pumble_event",
            type: "NEW_MESSAGE",
            channel_id: "channel-1"
          )
        )

      refute sql =~ "draft_definition"
      refute sql =~ "source_definition"
      refute sql =~ "compiled_definition"
    end
  end

  describe "manual alias" do
    test "returns the live holder of the alias", %{installation_id: installation_id} do
      {_workflow, version, binding} =
        live_manual_binding(installation_id, "deploy", %{
          filter_config: %{
            "slash_command" => true,
            "global_shortcut" => false,
            "message_shortcut" => false
          }
        })

      assert [%TriggerMatcher{binding_id: id, workflow_version_id: version_id}] =
               TriggerMatcher.match(slash(installation_id, "deploy"))

      assert id == binding.id
      assert version_id == version.id
    end

    test "respects entry-point flags after indexed alias lookup", %{
      installation_id: installation_id
    } do
      live_manual_binding(installation_id, "deploy", %{
        filter_config: %{
          "slash_command" => false,
          "global_shortcut" => true,
          "message_shortcut" => false
        }
      })

      assert [] == TriggerMatcher.match(slash(installation_id, "deploy"))

      assert [%TriggerMatcher{}] =
               TriggerMatcher.match(shortcut(installation_id, "deploy", :global_shortcut))
    end

    test "does not match a disabled alias holder", %{installation_id: installation_id} do
      live_manual_binding(installation_id, "deploy", %{enabled: false})

      assert [] == TriggerMatcher.match(slash(installation_id, "deploy"))
    end
  end

  describe "malformed filter projections" do
    test "skips a malformed binding and still returns the healthy match", %{
      installation_id: installation_id
    } do
      attach_telemetry()

      {_w, _v, bad} =
        live_event_binding(installation_id, %{
          channel_id: nil,
          name: "Broken",
          filter_config: %{"keyword" => ["not", "a", "string"], "ignore_bot_messages" => true}
        })

      {_w, _v, good} =
        live_event_binding(installation_id, %{
          channel_id: nil,
          name: "Healthy",
          filter_config: %{"keyword" => nil, "ignore_bot_messages" => false}
        })

      assert [%TriggerMatcher{binding_id: id}] =
               TriggerMatcher.match(event(installation_id, channel_id: "channel-1"))

      assert id == good.id
      refute id == bad.id

      assert_receive {:telemetry, [:pumble_automation, :ingress, :matcher, :invalid_filter],
                      %{count: 1}, metadata}

      assert metadata.kind == "pumble_event"
      assert metadata.type == "NEW_MESSAGE"
      refute Map.has_key?(metadata, :filter_config)
    end
  end

  describe "lifecycle callbacks" do
    test "never match a workflow", %{installation_id: installation_id} do
      live_event_binding(installation_id, %{channel_id: "channel-1"})

      assert [] ==
               TriggerMatcher.match(%LifecycleCommand{
                 installation_id: installation_id,
                 kind: :app_uninstalled,
                 type: "APP_UNINSTALLED",
                 workspace_id: "ws",
                 occurred_at: DateTime.utc_now(),
                 occurred_at_source: :received,
                 delivery_key: "lc"
               })
    end
  end

  describe "indexed lookup" do
    test "uses the lookup index on a representative workspace", %{
      installation_id: installation_id
    } do
      seed_workspace(installation_id, 40)

      plan =
        explain_index_plan(
          TriggerBinding.candidates(installation_id,
            kind: "pumble_event",
            type: "NEW_MESSAGE",
            channel_id: "channel-1"
          ),
          analyze: true
        )

      assert index_backed?(plan)
      refute plan =~ "Seq Scan on trigger_bindings"
      refute plan =~ "Seq Scan on workflows"
    end

    test "candidate count stays selective in a large workspace", %{
      installation_id: installation_id
    } do
      wanted =
        Enum.map(1..2, fn index ->
          {_workflow, _version, binding} =
            live_event_binding(installation_id, %{
              channel_id: "channel-1",
              name: "Wanted #{index}"
            })

          binding
        end)

      seed_noise(installation_id, 40)

      matches = TriggerMatcher.match(event(installation_id, channel_id: "channel-1"))

      assert length(matches) == 2

      assert MapSet.new(Enum.map(matches, & &1.binding_id)) ==
               MapSet.new(Enum.map(wanted, & &1.id))
    end
  end

  defp live_event_binding(installation_id, attrs) do
    {name, attrs} = Map.pop(attrs, :name, "Event #{System.unique_integer([:positive])}")
    workflow = drafted_workflow(installation_id, %{name: name})
    version = version(workflow)

    workflow =
      workflow
      |> Workflow.changeset(%{status: "active", active_version_id: version.id})
      |> Repo.update!()

    binding = trigger_binding(version, attrs)
    {workflow, version, binding}
  end

  defp live_binding_on(workflow, version, attrs) do
    binding = trigger_binding(version, attrs)
    {workflow, version, binding}
  end

  defp live_manual_binding(installation_id, alias_name, attrs) do
    workflow =
      drafted_workflow(installation_id, %{
        name: "Manual #{alias_name}",
        slug: alias_name
      })

    version = version(workflow)

    workflow =
      workflow
      |> Workflow.changeset(%{status: "active", active_version_id: version.id})
      |> Repo.update!()

    binding =
      trigger_binding(
        version,
        Map.merge(
          %{
            kind: "manual",
            type: "manual",
            alias: alias_name,
            filter_config: %{
              "slash_command" => true,
              "global_shortcut" => false,
              "message_shortcut" => false
            }
          },
          attrs
        )
      )

    {workflow, version, binding}
  end

  defp seed_workspace(installation_id, count) do
    live_event_binding(installation_id, %{channel_id: "channel-1", name: "Plan target"})
    seed_noise(installation_id, count)
  end

  defp seed_noise(installation_id, count) do
    for index <- 1..count do
      live_event_binding(installation_id, %{
        channel_id: "noise-#{index}",
        name: "Noise #{index}"
      })
    end
  end

  defp event(installation_id, opts) do
    {data, opts} = Keyword.pop(opts, :data, %{text: "hello"})
    {bot_origin?, opts} = Keyword.pop(opts, :bot_origin?, false)
    channel_id = Keyword.get(opts, :channel_id, "channel-1")
    type = Keyword.get(opts, :type, "NEW_MESSAGE")

    %AutomationEvent{
      installation_id: installation_id,
      type: type,
      channel_id: channel_id,
      occurred_at: DateTime.utc_now(),
      occurred_at_source: :received,
      delivery_key: "dk-#{System.unique_integer([:positive])}",
      bot_origin?: bot_origin?,
      data: data
    }
  end

  defp slash(installation_id, alias_name) do
    interaction(installation_id, alias_name, :slash_command)
  end

  defp shortcut(installation_id, alias_name, kind) do
    interaction(installation_id, alias_name, kind)
  end

  defp interaction(installation_id, alias_name, kind) do
    %InteractionCommand{
      installation_id: installation_id,
      kind: kind,
      type: Atom.to_string(kind),
      workspace_id: "ws",
      actor_id: "user-1",
      trigger_id: "trigger-1",
      occurred_at: DateTime.utc_now(),
      delivery_key: "int-#{System.unique_integer([:positive])}",
      data: %{alias: alias_name}
    }
  end

  defp ids(matches) do
    Enum.map(matches, &{&1.workflow_version_id, &1.binding_id})
  end

  defp attach_telemetry do
    handler = "matcher-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        TriggerMatcher.telemetry_event() ++ [:invalid_filter],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
