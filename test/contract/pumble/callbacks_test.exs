defmodule PumbleAutomation.Contract.Pumble.CallbacksTest do
  @moduledoc """
  Every stored callback fixture classifies, normalizes, and maps to the
  documented HTTP response. Catalog expected values are the oracle.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Ingress.AutomationEvent
  alias PumbleAutomation.Ingress.InteractionCommand
  alias PumbleAutomation.Ingress.LifecycleCommand
  alias PumbleAutomation.Pumble.Classifier
  alias PumbleAutomation.Pumble.Normalizer
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Pumble.Response
  alias PumbleAutomation.PumbleFake

  @installation_id "11111111-2222-3333-4444-555555555555"
  @raw_body ~s({"messageType":"PUMBLE_EVENT"})
  @signature "a1b2c3"
  @received_at ~U[2026-02-02 12:00:00.000000Z]

  test "every callback fixture matches catalog classifier, normalizer, and response" do
    for entry <- callback_entries() do
      envelope = PumbleFake.fixture(entry["path"])
      assert {:ok, payload} = Classifier.classify(envelope)
      assert Payload.kind(payload) == expected_kind(entry)

      case entry["expected"]["type"] do
        nil ->
          :ok

        "NEW_MESSAGE" ->
          assert payload.event_type == "NEW_MESSAGE"

        "UPDATED_MESSAGE" ->
          assert payload.event_type == "UPDATED_MESSAGE"

        "REACTION_ADDED" ->
          assert payload.event_type == "REACTION_ADDED"

        "CHANNEL_CREATED" ->
          assert payload.event_type == "CHANNEL_CREATED"

        "WORKSPACE_USER_JOINED" ->
          assert payload.event_type == "WORKSPACE_USER_JOINED"

        "APP_UNINSTALLED" ->
          assert payload.event_type == "APP_UNINSTALLED"

        "APP_UNAUTHORIZED" ->
          assert payload.event_type == "APP_UNAUTHORIZED"

        "SUBMIT" ->
          assert payload.view_action_type == "SUBMIT"

        "CLOSE" ->
          assert payload.view_action_type == "CLOSE"
      end

      assert {:ok, normalized} = Normalizer.normalize(payload, context())
      assert normalizer_module(entry) == normalized.__struct__
      assert response_for(payload) == expected_response(entry["expected"]["response"])
    end
  end

  test "VIEW_ACTION CLOSE is classified and acked like SUBMIT" do
    envelope = PumbleFake.fixture("callbacks/view_action_close.json")
    assert {:ok, %Payload.ViewAction{} = payload} = Classifier.classify(envelope)
    assert payload.view_action_type == "CLOSE"
    assert {:ok, %InteractionCommand{type: "CLOSE"}} = Normalizer.normalize(payload, context())
    assert Response.ack() == {:json, 200, %{}}
  end

  defp callback_entries do
    Enum.filter(PumbleFake.catalog()["fixtures"], &(&1["kind"] == "callback"))
  end

  defp expected_kind(entry) do
    String.to_existing_atom(entry["expected"]["classifier_kind"])
  end

  defp normalizer_module(entry) do
    case entry["expected"]["normalizer"] do
      "automation_event" -> AutomationEvent
      "lifecycle_command" -> LifecycleCommand
      "interaction_command" -> InteractionCommand
    end
  end

  defp response_for(payload) do
    case Payload.kind(payload) do
      :event ->
        Response.event_ack()

      :dynamic_menu ->
        Response.nack("This add-on offers no dynamic menu options.")

      _other ->
        Response.ack()
    end
  end

  defp expected_response(%{"encoding" => "text", "status" => status, "body" => body}) do
    {:text, status, body}
  end

  defp expected_response(%{"encoding" => "json", "status" => status, "body" => body}) do
    {:json, status, body}
  end

  defp context do
    %{
      installation_id: @installation_id,
      raw_body: @raw_body,
      signature: @signature,
      received_at: @received_at
    }
  end
end
