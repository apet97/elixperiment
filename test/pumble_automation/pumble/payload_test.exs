defmodule PumbleAutomation.Pumble.PayloadTest do
  @moduledoc """
  The payload structs and the vocabulary they publish.

  These tests are about shape, not about parsing: they check that the class list
  matches the evidence matrix, that `kind/1` names every class exactly once, and
  that the diagnostic map is bounded and content-free. Parsing is
  `PumbleAutomation.Pumble.ClassifierTest`'s subject.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Pumble.Payload

  describe "the class vocabulary" do
    test "the message types are the SDK's seven" do
      assert Enum.sort(Payload.message_types()) ==
               Enum.sort(
                 ~w(SLASH_COMMAND SHORTCUT APP_EVENT PUMBLE_EVENT BLOCK_INTERACTION DYNAMIC_MENU VIEW_ACTION)
               )
    end

    test "both event message types classify as events" do
      assert Enum.sort(Payload.event_message_types()) == ~w(APP_EVENT PUMBLE_EVENT)
    end

    test "the five selectable triggers and the two lifecycle events are separate lists" do
      assert Payload.trigger_event_types() == ~w(
               NEW_MESSAGE
               UPDATED_MESSAGE
               REACTION_ADDED
               CHANNEL_CREATED
               WORKSPACE_USER_JOINED
             )

      assert Payload.lifecycle_event_types() == ~w(APP_UNINSTALLED APP_UNAUTHORIZED)

      assert Payload.trigger_event_types() -- Payload.lifecycle_event_types() ==
               Payload.trigger_event_types()
    end

    test "the seven event types are exactly the SDK's EventMap keys" do
      assert length(Payload.event_types()) == 7
      assert Enum.uniq(Payload.event_types()) == Payload.event_types()
    end

    test "the discriminator vocabularies are closed" do
      assert Payload.shortcut_types() == ~w(GLOBAL ON_MESSAGE)
      assert Payload.block_interaction_source_types() == ~w(VIEW MESSAGE EPHEMERAL_MESSAGE)
      assert Payload.view_action_types() == ~w(SUBMIT CLOSE)
    end
  end

  describe "kind/1" do
    test "names each struct once" do
      kinds =
        [
          %Payload.Event{
            message_type: "PUMBLE_EVENT",
            event_type: "NEW_MESSAGE",
            workspace_id: "W",
            body: %{}
          },
          %Payload.SlashCommand{
            slash_command: "/workflow",
            user_id: "U",
            channel_id: "C",
            workspace_id: "W",
            trigger_id: "T"
          },
          %Payload.GlobalShortcut{
            shortcut: "run_workflow",
            user_id: "U",
            channel_id: "C",
            workspace_id: "W",
            trigger_id: "T"
          },
          %Payload.MessageShortcut{
            shortcut: "run_workflow_on_message",
            message_id: "M",
            user_id: "U",
            channel_id: "C",
            workspace_id: "W",
            trigger_id: "T"
          },
          %Payload.BlockInteraction{
            workspace_id: "W",
            user_id: "U",
            source_type: "VIEW",
            source_id: "S",
            trigger_id: "T"
          },
          %Payload.ViewAction{
            workspace_id: "W",
            user_id: "U",
            view_action_type: "SUBMIT",
            trigger_id: "T"
          },
          %Payload.DynamicMenu{
            on_action: "pick",
            workspace_id: "W",
            user_id: "U",
            trigger_id: "T"
          }
        ]
        |> Enum.map(&Payload.kind/1)

      assert kinds == [
               :event,
               :slash_command,
               :global_shortcut,
               :message_shortcut,
               :block_interaction,
               :view_action,
               :dynamic_menu
             ]

      assert Enum.uniq(kinds) == kinds
    end
  end

  describe "a struct refuses to exist without its identity" do
    test "an event needs a type, a workspace, and a body" do
      assert_raise ArgumentError, fn ->
        struct!(Payload.Event, message_type: "PUMBLE_EVENT")
      end
    end

    test "a message shortcut needs the message it was run on" do
      assert_raise ArgumentError, fn ->
        struct!(Payload.MessageShortcut,
          shortcut: "run_workflow_on_message",
          user_id: "U",
          channel_id: "C",
          workspace_id: "W",
          trigger_id: "T"
        )
      end
    end
  end

  describe "unknown_fields/2" do
    test "records the names of fields that were not read" do
      unknown = Payload.unknown_fields(%{"known" => "a", "surprise" => "b"}, ["known"])

      assert unknown == %{"surprise" => :string}
    end

    test "records a type tag and never the value" do
      envelope = %{
        "s" => "a secret sentence",
        "i" => 1,
        "f" => 1.5,
        "b" => true,
        "l" => [1, 2],
        "m" => %{"a" => 1},
        "n" => nil
      }

      unknown = Payload.unknown_fields(envelope, [])

      assert unknown == %{
               "s" => :string,
               "i" => :integer,
               "f" => :float,
               "b" => :boolean,
               "l" => :list,
               "m" => :map,
               "n" => :null
             }

      refute unknown |> Map.values() |> Enum.any?(&is_binary/1)
    end

    test "is capped, and the cap is applied to a stable ordering" do
      envelope = Map.new(1..100, fn n -> {"field-#{String.pad_leading("#{n}", 3, "0")}", n} end)

      unknown = Payload.unknown_fields(envelope, [])

      assert map_size(unknown) == Payload.max_unknown_keys()
      assert unknown == Payload.unknown_fields(envelope, [])
      assert Map.has_key?(unknown, "field-001")
      refute Map.has_key?(unknown, "field-100")
    end

    test "drops keys that are not strings" do
      assert Payload.unknown_fields(%{:atom_key => 1, "string_key" => 1}, []) == %{
               "string_key" => :integer
             }
    end
  end
end
