defmodule PumbleAutomation.Pumble.ClassifierTest do
  @moduledoc """
  Classification of every stored callback fixture, and of everything else.

  The happy-path tests read `priv/pumble/fixtures/callbacks`, so a fixture and
  the classifier cannot drift apart without a failure here. The refusal tests
  build their bodies inline, because a body that must be refused is not a shape
  worth storing.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Error
  alias PumbleAutomation.Pumble.Classifier
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.PumbleFake

  @fixtures %{
    "event_new_message.json" => Payload.Event,
    "event_updated_message.json" => Payload.Event,
    "event_reaction_added.json" => Payload.Event,
    "event_channel_created.json" => Payload.Event,
    "event_workspace_user_joined.json" => Payload.Event,
    "event_app_uninstalled.json" => Payload.Event,
    "event_app_unauthorized.json" => Payload.Event,
    "slash_command.json" => Payload.SlashCommand,
    "global_shortcut.json" => Payload.GlobalShortcut,
    "message_shortcut.json" => Payload.MessageShortcut,
    "block_interaction_view.json" => Payload.BlockInteraction,
    "block_interaction_message.json" => Payload.BlockInteraction,
    "block_interaction_ephemeral_message.json" => Payload.BlockInteraction,
    "view_action_submit.json" => Payload.ViewAction,
    "view_action_close.json" => Payload.ViewAction,
    "dynamic_menu.json" => Payload.DynamicMenu
  }

  describe "one fixture per class" do
    for {file, module} <- @fixtures do
      test "#{file} classifies as #{inspect(module)}" do
        assert {:ok, payload} = classify(unquote(file))

        assert payload.__struct__ == unquote(module)
      end
    end

    test "every callback class in the evidence matrix has a fixture" do
      kinds =
        @fixtures
        |> Map.keys()
        |> Enum.map(fn file ->
          {:ok, payload} = classify(file)
          Payload.kind(payload)
        end)
        |> Enum.uniq()
        |> Enum.sort()

      assert kinds == [
               :block_interaction,
               :dynamic_menu,
               :event,
               :global_shortcut,
               :message_shortcut,
               :slash_command,
               :view_action
             ]
    end
  end

  describe "an event envelope" do
    test "decodes the nested JSON string body" do
      assert {:ok, event} = classify("event_new_message.json")

      assert event.event_type == "NEW_MESSAGE"
      assert event.workspace_id == "W_FAKE001"
      assert event.workspace_user_ids == ["U_FAKE001"]
      assert event.body["tx"] == "deploy the release please"
      assert event.body["aId"] == "U_FAKE001"
    end

    test "accepts APP_EVENT as well as PUMBLE_EVENT" do
      assert {:ok, event} = classify("event_app_uninstalled.json")

      assert event.message_type == "APP_EVENT"
      assert event.event_type == "APP_UNINSTALLED"
    end

    test "a body that is not JSON is an error, not an exception" do
      assert {:error, %Error{code: :malformed_event_body} = error} =
               classify("event_new_message.json", %{"body" => "{not json"})

      assert error.class == :validation
      refute error.retryable?
      assert error.details == %{field: "body"}
    end

    test "a body that decodes to something other than an object is refused" do
      assert {:error, %Error{code: :invalid_field}} =
               classify("event_new_message.json", %{"body" => "[1,2,3]"})
    end

    test "a body that is not a string at all is refused" do
      assert {:error, %Error{code: :invalid_field}} =
               classify("event_new_message.json", %{"body" => %{"tx" => "already decoded"}})
    end

    test "an unknown event name has its own code, distinct from an unknown class" do
      assert {:error, %Error{code: :unknown_event_type}} =
               classify("event_new_message.json", %{"eventType" => "MESSAGE_DELETED"})
    end

    test "workspaceUserIds must be a list of strings when present" do
      assert {:error, %Error{code: :invalid_field}} =
               classify("event_new_message.json", %{"workspaceUserIds" => ["U", 7]})

      assert {:ok, event} = classify("event_new_message.json", %{"workspaceUserIds" => nil})
      assert event.workspace_user_ids == []
    end
  end

  describe "the interactive classes" do
    test "a shortcut splits on its type" do
      assert {:ok, %Payload.GlobalShortcut{}} = classify("global_shortcut.json")
      assert {:ok, %Payload.MessageShortcut{}} = classify("message_shortcut.json")
    end

    test "a block interaction keeps its source type and its opaque value" do
      assert {:ok, block} = classify("block_interaction_message.json")

      assert block.source_type == "MESSAGE"
      assert block.source_id == "M_FAKE001"
      assert block.payload == "approve"
      assert block.loading_timeout == 0
    end

    test "a slash command with no text classifies with an empty one" do
      assert {:ok, slash} = classify("slash_command.json", %{"text" => nil})

      assert slash.text == ""
      assert slash.thread_root_id == "TR_FAKE001"
    end

    test "an unrecognized secondary discriminator is refused" do
      for {file, field, value} <- [
            {"global_shortcut.json", "type", "ON_CHANNEL"},
            {"block_interaction_view.json", "sourceType", "SIDEBAR"},
            {"view_action_submit.json", "viewActionType", "CANCEL"}
          ] do
        assert {:error, %Error{code: :invalid_field, details: %{field: ^field}}} =
                 classify(file, %{field => value})
      end
    end
  end

  describe "required fields" do
    test "a missing required field is refused and names only the field" do
      for {file, field} <- [
            {"slash_command.json", "triggerId"},
            {"global_shortcut.json", "shortcut"},
            {"message_shortcut.json", "messageId"},
            {"block_interaction_view.json", "sourceId"},
            {"view_action_submit.json", "userId"},
            {"dynamic_menu.json", "onAction"},
            {"event_new_message.json", "workspaceId"}
          ] do
        assert {:error, %Error{code: :invalid_field} = error} = classify(file, %{field => nil})

        assert error.details == %{field: field}
        assert error.message == "The callback could not be classified."
      end
    end

    test "a required field of the wrong type is refused like a missing one" do
      for value <- [7, %{}, [], true] do
        assert {:error, %Error{code: :invalid_field, details: %{field: "triggerId"}}} =
                 classify("slash_command.json", %{"triggerId" => value})
      end
    end

    test "an optional field of the wrong type is still refused" do
      assert {:error, %Error{code: :invalid_field, details: %{field: "channelId"}}} =
               classify("block_interaction_view.json", %{"channelId" => 7})

      assert {:error, %Error{code: :invalid_field, details: %{field: "loadingTimeout"}}} =
               classify("block_interaction_view.json", %{"loadingTimeout" => "0"})

      assert {:error, %Error{code: :invalid_field, details: %{field: "view"}}} =
               classify("view_action_submit.json", %{"view" => "VIEW_FAKE001"})
    end
  end

  describe "bodies that are not callbacks" do
    test "an unknown messageType is refused with its own code" do
      assert {:error, %Error{code: :unknown_message_type, details: %{field: "messageType"}}} =
               Classifier.classify(%{"messageType" => "TELEPATHY"})
    end

    test "a missing messageType is refused" do
      assert {:error, %Error{code: :invalid_field, details: %{field: "messageType"}}} =
               Classifier.classify(%{"slashCommand" => "/workflow"})
    end

    test "anything that is not an object is refused" do
      for value <- [
            [],
            "callback",
            7,
            nil,
            %Payload.DynamicMenu{
              on_action: "x",
              workspace_id: "W",
              user_id: "U",
              trigger_id: "T"
            }
          ] do
        assert {:error, %Error{code: :callback_not_an_object}} = Classifier.classify(value)
      end
    end

    test "fuzzed envelopes are refused rather than raising" do
      base = PumbleFake.fixture("callbacks/slash_command.json")

      for key <- Map.keys(base), value <- [nil, 7, [], %{}, true] do
        result = Classifier.classify(Map.put(base, key, value))

        assert match?({:ok, _payload}, result) or match?({:error, %Error{}}, result)
      end
    end
  end

  describe "ambiguous bodies" do
    test "a body carrying another class's recognized discriminator is refused" do
      for {file, field, value} <- [
            {"slash_command.json", "sourceType", "VIEW"},
            {"slash_command.json", "type", "GLOBAL"},
            {"dynamic_menu.json", "viewActionType", "SUBMIT"},
            {"event_new_message.json", "sourceType", "MESSAGE"},
            {"view_action_submit.json", "sourceType", "VIEW"}
          ] do
        assert {:error, %Error{code: :ambiguous_callback, details: %{field: ^field}}} =
                 classify(file, %{field => value})
      end
    end

    test "the class that owns a discriminator is not called ambiguous by carrying it" do
      assert {:ok, %Payload.GlobalShortcut{}} = classify("global_shortcut.json")
      assert {:ok, %Payload.BlockInteraction{}} = classify("block_interaction_view.json")
      assert {:ok, %Payload.ViewAction{}} = classify("view_action_submit.json")
    end

    test "an unrecognized value of another class's discriminator is not ambiguous" do
      assert {:ok, %Payload.SlashCommand{}} =
               classify("slash_command.json", %{"sourceType" => "SOMETHING_ELSE"})
    end
  end

  describe "unknown fields" do
    test "are recorded by name and type, bounded, and never by value" do
      assert {:ok, slash} =
               classify("slash_command.json", %{
                 "newField" => "a value nobody has seen",
                 "anotherField" => 7
               })

      assert slash.unknown == %{"newField" => :string, "anotherField" => :integer}
    end

    test "a known field never appears as unknown" do
      assert {:ok, event} = classify("event_new_message.json")

      assert event.unknown == %{}
    end
  end

  defp classify(file, overrides \\ %{}) do
    "callbacks/#{file}"
    |> PumbleFake.fixture()
    |> Map.merge(overrides)
    |> Classifier.classify()
  end
end
