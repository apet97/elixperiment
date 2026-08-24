defmodule PumbleAutomation.Pumble.NormalizerTest do
  @moduledoc """
  Normalization of every stored fixture into this application's vocabulary.

  The golden tests assert the whole normalized value, not one field at a time: a
  field that silently stops being populated is exactly the kind of regression
  that a per-field assertion misses.

  One assertion runs against every fixture and is the point of the module: no
  key anywhere in a normalized value may be a Pumble wire name.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.AutomationEvent
  alias PumbleAutomation.Ingress.InteractionCommand
  alias PumbleAutomation.Ingress.LifecycleCommand
  alias PumbleAutomation.Pumble.Classifier
  alias PumbleAutomation.Pumble.Normalizer
  alias PumbleAutomation.PumbleFake

  @installation_id "11111111-2222-3333-4444-555555555555"
  @raw_body ~s({"messageType":"PUMBLE_EVENT"})
  @signature "a1b2c3"
  @received_at ~U[2026-02-02 12:00:00.000000Z]

  # Every abbreviated wire name from `E-1` to `E-5`, plus the envelope's own.
  @wire_names ~w(
    aId cId mId trId tsm tx wId uId rid mat rc cN cU cT uN uE afp asp
    sts pt pp ro ib eph stc trMt lId att bl md mc mu au st ty
    messageType eventType workspaceId workspaceUserIds triggerId sourceId
    sourceType viewActionType slashCommand threadRootId onAction
  )

  @all_fixtures ~w(
    event_new_message.json
    event_updated_message.json
    event_reaction_added.json
    event_channel_created.json
    event_workspace_user_joined.json
    event_app_uninstalled.json
    event_app_unauthorized.json
    slash_command.json
    global_shortcut.json
    message_shortcut.json
    block_interaction_view.json
    block_interaction_message.json
    block_interaction_ephemeral_message.json
    view_action_submit.json
    view_action_close.json
    dynamic_menu.json
  )

  describe "the five selectable trigger events" do
    test "NEW_MESSAGE normalizes whole" do
      assert {:ok, %AutomationEvent{} = event} = normalize("event_new_message.json")

      assert event.provider == :pumble
      assert event.installation_id == @installation_id
      assert event.kind == :event
      assert event.type == "NEW_MESSAGE"
      assert event.actor_id == "U_FAKE001"
      assert event.channel_id == "C_FAKE001"
      assert event.resource_id == "M_FAKE001"
      assert event.thread_root_id == "TR_FAKE001"
      assert event.occurred_at == ~U[2026-01-01 00:00:00.000Z]
      assert event.occurred_at_source == :provider
      assert event.bot_origin? == nil

      assert event.data == %{
               also_sent_to_channel: "false",
               edited?: false,
               ephemeral?: false,
               file_count: 0,
               mentions_channel: [],
               mentions_direct: [],
               mentions_user: [],
               message_id: "M_FAKE001",
               subtype: "",
               provider_request_id: "RID_FAKE001",
               provider_timestamp_ms: 1_767_225_600_000,
               text: "deploy the release please",
               thread_root_id: "TR_FAKE001",
               workspace_id: "W_FAKE001",
               workspace_user_ids: ["U_FAKE001"]
             }
    end

    test "UPDATED_MESSAGE carries the edit flag" do
      assert {:ok, event} = normalize("event_updated_message.json")

      assert event.type == "UPDATED_MESSAGE"
      assert event.data.edited? == true
      assert event.occurred_at_source == :provider
    end

    test "REACTION_ADDED separates the reactor from the message author" do
      assert {:ok, event} = normalize("event_reaction_added.json")

      assert event.actor_id == "U_FAKE001"
      assert event.resource_id == "M_FAKE001"
      assert event.data.message_author_id == "U_FAKE002"
      assert event.data.reaction_code == "thumbsup"
    end

    test "CHANNEL_CREATED names the channel and counts its members" do
      assert {:ok, event} = normalize("event_channel_created.json")

      assert event.actor_id == nil
      assert event.channel_id == "C_FAKE002"
      assert event.resource_id == "C_FAKE002"
      assert event.data.channel_name == "release-train"
      assert event.data.channel_member_count == 2
    end

    test "WORKSPACE_USER_JOINED normalizes the joining user" do
      assert {:ok, event} = normalize("event_workspace_user_joined.json")

      assert event.actor_id == "U_FAKE003"
      assert event.resource_id == "U_FAKE003"
      assert event.data.user_name == "Fake Person"
      assert event.data.timezone == "Europe/Belgrade"
    end
  end

  describe "the two lifecycle events" do
    test "APP_UNINSTALLED becomes a lifecycle command, never an automation event" do
      assert {:ok, %LifecycleCommand{} = command} = normalize("event_app_uninstalled.json")

      assert command.kind == :app_uninstalled
      assert command.type == "APP_UNINSTALLED"
      assert command.workspace_id == "W_FAKE001"
      assert command.provider_event_id == "EVT_FAKE001"
      assert command.occurred_at == ~U[2026-01-01 00:00:00.000Z]
      assert command.occurred_at_source == :provider
      assert command.data.bot_user_id == "U_FAKE_BOT"
    end

    test "APP_UNAUTHORIZED carries the granted scopes and the grant flag" do
      assert {:ok, %LifecycleCommand{} = command} = normalize("event_app_unauthorized.json")

      assert command.kind == :app_unauthorized
      assert command.data.granted_scopes == ["messages:read", "messages:write"]
      assert command.data.access_granted? == false
      assert command.occurred_at_source == :received
    end

    test "no lifecycle fixture can become something a workflow may match" do
      for file <- ~w(event_app_uninstalled.json event_app_unauthorized.json) do
        assert {:ok, normalized} = normalize(file)

        assert normalized.__struct__ == LifecycleCommand,
               "#{file} normalized to #{inspect(normalized.__struct__)}"
      end
    end

    test "an ISO 8601 uninstall time is accepted too" do
      assert {:ok, command} =
               normalize("event_app_uninstalled.json",
                 body: %{"uninstalledAt" => "2026-03-04T05:06:07Z"}
               )

      assert command.occurred_at == ~U[2026-03-04 05:06:07Z]
      assert command.occurred_at_source == :provider
    end
  end

  describe "the interactive classes" do
    test "a slash command becomes an interaction command, never an event" do
      assert {:ok, %InteractionCommand{} = command} = normalize("slash_command.json")

      assert command.kind == :slash_command
      assert command.type == "/workflow"
      assert command.actor_id == "U_FAKE001"
      assert command.channel_id == "C_FAKE001"
      assert command.thread_root_id == "TR_FAKE001"
      assert command.trigger_id == "TRIG_FAKE001"
      assert command.occurred_at == @received_at
      assert command.occurred_at_source == :received
      assert command.data.text == "run nightly-report"
    end

    test "a message shortcut keeps the message it was run on" do
      assert {:ok, command} = normalize("message_shortcut.json")

      assert command.kind == :message_shortcut
      assert command.resource_id == "M_FAKE001"
      assert command.data.shortcut == "run_workflow_on_message"
    end

    test "a block interaction keeps the source object and the opaque value" do
      assert {:ok, command} = normalize("block_interaction_view.json")

      assert command.kind == :block_interaction
      assert command.resource_id == "VIEW_FAKE001"
      assert command.data.source_type == "VIEW"
      assert command.data.block_value == "approve"
      assert command.data.view_id == "VIEW_FAKE001"
      assert command.data.loading_timeout == 0
    end

    test "a view action resolves the view it belongs to" do
      assert {:ok, command} = normalize("view_action_submit.json")

      assert command.kind == :view_action
      assert command.type == "SUBMIT"
      assert command.resource_id == "VIEW_FAKE001"
    end

    test "a view action CLOSE is a distinct type of the same class" do
      assert {:ok, command} = normalize("view_action_close.json")

      assert command.kind == :view_action
      assert command.type == "CLOSE"
      assert command.resource_id == "VIEW_FAKE001"
    end

    test "a dynamic menu keeps its query" do
      assert {:ok, command} = normalize("dynamic_menu.json")

      assert command.kind == :dynamic_menu
      assert command.data.query == "nightly"
      assert command.channel_id == nil
    end
  end

  describe "the delivery key" do
    test "is the digest of the received bytes and signature, not a payload field" do
      assert {:ok, event} = normalize("event_new_message.json")

      assert event.delivery_key == Normalizer.delivery_key(@raw_body, @signature)
      assert String.starts_with?(event.delivery_key, "sha256:")
      refute event.delivery_key =~ "RID_FAKE001"
    end

    test "is identical for a byte-identical redelivery and different otherwise" do
      assert {:ok, first} = normalize("event_new_message.json")
      assert {:ok, second} = normalize("event_new_message.json")
      assert {:ok, other} = normalize("event_new_message.json", signature: "different")

      assert first.delivery_key == second.delivery_key
      refute first.delivery_key == other.delivery_key
    end

    test "cannot be forged by moving bytes across the separator" do
      refute Normalizer.delivery_key("ab", "c") == Normalizer.delivery_key("a", "bc")
    end
  end

  describe "time" do
    test "an unusable provider time falls back to the receive time and says so" do
      for value <- [nil, "not a time", 0, -1, 99_999_999_999_999, %{}, []] do
        assert {:ok, event} = normalize("event_new_message.json", body: %{"tsm" => value})

        assert event.occurred_at == @received_at
        assert event.occurred_at_source == :received
      end
    end

    test "an event with no provider time at all uses the receive time" do
      assert {:ok, event} = normalize("event_reaction_added.json")

      assert event.occurred_at == @received_at
      assert event.occurred_at_source == :received
    end

    test "a provider time given as a digit string is accepted" do
      assert {:ok, event} = normalize("event_new_message.json", body: %{"tsm" => "1767225600000"})

      assert event.occurred_at == ~U[2026-01-01 00:00:00.000Z]
      assert event.occurred_at_source == :provider
    end
  end

  describe "bot origin" do
    test "is decided only when the caller supplied the stored bot user id" do
      assert {:ok, event} = normalize("event_new_message.json")
      assert event.bot_origin? == nil

      assert {:ok, own} = normalize("event_new_message.json", bot_user_id: "U_FAKE001")
      assert own.bot_origin? == true

      assert {:ok, other} = normalize("event_new_message.json", bot_user_id: "U_FAKE_BOT")
      assert other.bot_origin? == false
    end

    test "stays unanswered when the event carries no author" do
      assert {:ok, event} =
               normalize("event_new_message.json",
                 body: %{"aId" => nil},
                 bot_user_id: "U_FAKE_BOT"
               )

      assert event.bot_origin? == nil
    end

    test "is never guessed for an event class that has no author field" do
      assert {:ok, event} = normalize("event_channel_created.json", bot_user_id: "U_FAKE_BOT")

      assert event.bot_origin? == nil
    end
  end

  describe "the bounded data map" do
    test "drops fields the payload did not carry" do
      assert {:ok, event} = normalize("event_new_message.json", body: %{"tx" => nil, "st" => nil})

      refute Map.has_key?(event.data, :text)
      refute Map.has_key?(event.data, :subtype)
      refute event.data |> Map.values() |> Enum.any?(&is_nil/1)
    end

    test "caps the number of keys" do
      extra = Map.new(1..100, fn n -> {"extra#{n}", "value"} end)

      assert {:ok, event} = normalize("event_new_message.json", body: extra)

      assert map_size(event.data) <= Normalizer.max_data_keys()
    end

    test "caps the size of a string" do
      long = String.duplicate("x", Normalizer.max_binary_bytes() * 2)

      assert {:ok, event} = normalize("event_new_message.json", body: %{"tx" => long})

      assert byte_size(event.data.text) == Normalizer.max_binary_bytes()
    end

    test "keeps a capped provider string valid when the byte boundary crosses a codepoint" do
      prefix = String.duplicate("x", Normalizer.max_binary_bytes() - 1)

      assert {:ok, event} =
               normalize("event_new_message.json", body: %{"tx" => prefix <> "😀"})

      assert event.data.text == prefix
      assert String.valid?(event.data.text)
      assert {:ok, _json} = Jason.encode(event.data)
    end

    test "caps a list" do
      assert {:ok, event} =
               normalize("event_new_message.json", body: %{"md" => Enum.map(1..100, &"U#{&1}")})

      assert length(event.data.mentions_direct) == 32
    end

    test "drops a list element that is not a scalar rather than carrying it" do
      assert {:ok, event} =
               normalize("event_new_message.json", body: %{"md" => ["U_FAKE001", %{"a" => 1}]})

      assert event.data.mentions_direct == ["U_FAKE001"]
    end
  end

  describe "the adapter boundary" do
    test "no normalized value carries a Pumble wire name, at any depth" do
      for file <- @all_fixtures do
        assert {:ok, normalized} = normalize(file)

        keys = keys_of(normalized)

        assert keys != []

        for name <- @wire_names do
          refute name in keys, "#{file} leaked the wire name #{name}"
        end
      end
    end

    test "every data key is a snake_case atom" do
      for file <- @all_fixtures do
        assert {:ok, normalized} = normalize(file)

        for key <- Map.keys(normalized.data) do
          assert is_atom(key)
          assert Atom.to_string(key) =~ ~r/^[a-z][a-z0-9_]*\??$/
        end
      end
    end
  end

  describe "scoping" do
    test "a context with no installation is a permanent error" do
      assert {:error, %Error{} = error} =
               normalize("event_new_message.json", installation_id: nil)

      assert error.class == :validation
      assert error.code == :unmappable_identity
      refute error.retryable?
    end

    test "a context with no bytes to key on is a permanent error" do
      assert {:error, %Error{code: :unmappable_identity}} =
               normalize("event_new_message.json", raw_body: nil)

      assert {:error, %Error{code: :unmappable_identity}} =
               normalize("event_new_message.json", signature: nil)
    end

    test "the correlation id is carried through unchanged" do
      assert {:ok, event} = normalize("event_new_message.json", correlation_id: "corr-1")

      assert event.correlation_id == "corr-1"
    end
  end

  defp normalize(file, opts \\ []) do
    payload =
      "callbacks/#{file}"
      |> PumbleFake.fixture()
      |> override_body(Keyword.get(opts, :body))
      |> classify!()

    context =
      %{
        installation_id: Keyword.get(opts, :installation_id, @installation_id),
        raw_body: Keyword.get(opts, :raw_body, @raw_body),
        signature: Keyword.get(opts, :signature, @signature),
        received_at: @received_at,
        correlation_id: Keyword.get(opts, :correlation_id),
        bot_user_id: Keyword.get(opts, :bot_user_id)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Normalizer.normalize(payload, context)
  end

  defp override_body(envelope, nil), do: envelope

  defp override_body(%{"body" => body} = envelope, overrides) do
    merged =
      body
      |> Jason.decode!()
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{envelope | "body" => Jason.encode!(merged)}
  end

  defp classify!(envelope) do
    {:ok, payload} = Classifier.classify(envelope)

    payload
  end

  defp keys_of(%_struct{} = value) do
    value |> Map.from_struct() |> keys_of()
  end

  defp keys_of(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} -> [to_string(key) | keys_of(nested)] end)
  end

  defp keys_of(value) when is_list(value), do: Enum.flat_map(value, &keys_of/1)
  defp keys_of(_value), do: []
end
