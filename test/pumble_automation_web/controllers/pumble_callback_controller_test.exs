defmodule PumbleAutomationWeb.PumbleCallbackControllerTest do
  @moduledoc """
  The response table, exercised through the real endpoint.

  Every request here is signed with the configured test secret and posted to
  `POST /pumble/callbacks`, so each assertion covers the whole path: the body
  reader, the signature plug, classification, the ingress boundary, and the
  response. A test that built a `conn` by hand would prove none of that.

  Not async: two tests change application configuration and one attaches a
  telemetry handler by a fixed name.
  """

  use PumbleAutomationWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Ingress.ManualTrigger
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Response
  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomationWeb.PumbleCallbackController

  @secret "test-signing-secret"
  @timestamp "1767225600000"

  @events ~w(
    event_new_message.json
    event_updated_message.json
    event_reaction_added.json
    event_channel_created.json
    event_workspace_user_joined.json
    event_app_uninstalled.json
    event_app_unauthorized.json
  )

  @interactions ~w(
    slash_command.json
    global_shortcut.json
    message_shortcut.json
    block_interaction_view.json
    block_interaction_message.json
    block_interaction_ephemeral_message.json
    view_action_submit.json
  )

  describe "the response table" do
    test "every event class is acknowledged with plain 200 ok" do
      for file <- @events do
        conn = post_fixture(file)

        assert response(conn, 200) == "ok"
        assert response_content_type(conn, :text) =~ "text/plain"
      end
    end

    test "every interactive class is acknowledged with 200 and a JSON object" do
      for file <- @interactions do
        conn = post_fixture(file)
        body = json_response(conn, 200)

        assert is_map(body)
      end
    end

    test "a dynamic menu is refused with a stable non-retryable nack" do
      conn = post_fixture("dynamic_menu.json")

      assert json_response(conn, 400) == %{
               "message" => "This add-on offers no dynamic menu options."
             }
    end

    test "the refusal for a dynamic menu is identical every time" do
      first = post_fixture("dynamic_menu.json")
      second = post_fixture("dynamic_menu.json")

      assert first.resp_body == second.resp_body
      assert first.status == second.status
    end

    test "a registered dynamic menu returns the exact bounded options envelope" do
      context = install_menu_workspace("W_FAKE001")
      activate_menu_workflow!(context, "nightly")
      activate_menu_workflow!(context, "daytime")

      conn = post_fixture("dynamic_menu.json", %{"value" => "nightly"})

      assert json_response(conn, 200) == %{
               "onAction" => "pick_workflow",
               "options" => [
                 %{
                   "text" => %{"type" => "plain_text", "text" => "nightly"},
                   "value" => "nightly"
                 }
               ],
               "triggerId" => "TRIG_FAKE001",
               "value" => "nightly"
             }
    end

    test "a signed replay is read-only and returns the same menu response" do
      context = install_menu_workspace("W_FAKE001")
      activate_menu_workflow!(context, "nightly")

      first = post_fixture("dynamic_menu.json")
      second = post_fixture("dynamic_menu.json")

      assert first.status == 200
      assert second.status == 200
      assert first.resp_body == second.resp_body
      assert Repo.aggregate(ReceivedEvent, :count) == 0
      assert Repo.aggregate(Execution, :count) == 0
    end

    test "an unknown registered action reveals no tenant data" do
      context = install_menu_workspace("W_FAKE001")
      activate_menu_workflow!(context, "private_alias")

      conn = post_fixture("dynamic_menu.json", %{"onAction" => "unknown_menu", "query" => nil})

      assert json_response(conn, 400) == %{
               "message" => "This add-on offers no dynamic menu options."
             }

      refute conn.resp_body =~ "private_alias"
      assert Repo.aggregate(ReceivedEvent, :count) == 0
      assert Repo.aggregate(Execution, :count) == 0
    end

    test "one dynamic menu response is capped before serialization" do
      put_active_workflow_limit(30)
      context = install_menu_workspace("W_FAKE001")

      for index <- 0..25 do
        alias_name = "menu-" <> String.pad_leading(Integer.to_string(index), 2, "0")
        activate_menu_workflow!(context, alias_name)
      end

      conn = post_fixture("dynamic_menu.json", %{"query" => nil})
      options = json_response(conn, 200)["options"]

      assert length(options) == 25

      assert Enum.map(options, & &1["value"]) ==
               Enum.map(0..24, &("menu-" <> String.pad_leading(Integer.to_string(&1), 2, "0")))

      assert length(options) == ManualTrigger.dynamic_menu_option_limit()
    end

    test "a malformed callback is refused with 400 after the signature was accepted" do
      for body <- [
            ~s({"messageType":"TELEPATHY"}),
            ~s({"messageType":"SLASH_COMMAND"}),
            ~s({"messageType":"DYNAMIC_MENU","workspaceId":"W","userId":"U","triggerId":"T"}),
            ~s({"messageType":"DYNAMIC_MENU","onAction":"pick_workflow","query":{},"workspaceId":"W","userId":"U","triggerId":"T"}),
            ~s({"nothing":"useful"}),
            ~s([1,2,3]),
            ~s({"messageType":"PUMBLE_EVENT","eventType":"NEW_MESSAGE","workspaceId":"W","body":"{not json"})
          ] do
        conn = post_body(body)

        assert json_response(conn, 400) == %{"message" => "This callback could not be processed."}
        assert conn.private[:pumble_signature_verified]
      end
    end

    test "an event naming an unknown event type is acknowledged and dropped" do
      body =
        ~s({"messageType":"PUMBLE_EVENT","eventType":"MESSAGE_DELETED","workspaceId":"W_FAKE001",) <>
          ~s("workspaceUserIds":[],"body":"{}"})

      conn = post_body(body)

      assert response(conn, 200) == "ok"
    end

    test "a refusal names no class, field, module, or callback content" do
      conn = post_fixture("slash_command.json", %{"triggerId" => nil})

      %{"message" => message} = json_response(conn, 400)

      refute message =~ "triggerId"
      refute message =~ "SLASH_COMMAND"
      refute message =~ "Pumble"
      refute message =~ "nightly"
    end

    test "an unsigned request never reaches the table at all" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/pumble/callbacks", ~s({"messageType":"SLASH_COMMAND"}))

      assert response(conn, 401) == "unauthorized"
    end

    test "an unsigned dynamic-menu request cannot read aliases" do
      context = install_menu_workspace("W_FAKE001")
      activate_menu_workflow!(context, "private_alias")
      body = PumbleFake.fixture("callbacks/dynamic_menu.json") |> Jason.encode!()

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/pumble/callbacks", body)

      assert response(conn, 401) == "unauthorized"
      refute conn.resp_body =~ "private_alias"
      assert Repo.aggregate(ReceivedEvent, :count) == 0
      assert Repo.aggregate(Execution, :count) == 0
    end
  end

  describe "exactly one response per request" do
    test "each class sends one body and one content type" do
      for file <- ["dynamic_menu.json" | @events ++ @interactions] do
        conn = post_fixture(file)

        assert conn.state == :sent
        assert length(Plug.Conn.get_resp_header(conn, "content-type")) == 1
        assert is_binary(conn.resp_body)
      end
    end

    test "one request produces exactly one terminal telemetry event" do
      with_telemetry([PumbleCallbackController.telemetry_event() ++ [:stop]], fn ->
        post_fixture("slash_command.json")

        assert_receive {:telemetry, _event, _measurements, %{class: :slash_command}}
        refute_receive {:telemetry, _event, _measurements, _metadata}, 50
      end)
    end
  end

  describe "the response module is the only place a shape is decided" do
    test "each constructor produces the documented status and body" do
      assert Response.event_ack() == {:text, 200, "ok"}
      assert Response.ack() == {:json, 200, %{}}
      assert Response.ack("done") == {:json, 200, %{"message" => "done"}}
      assert Response.nack("no") == {:json, 400, %{"message" => "no"}}
      assert Response.nack("no", 409) == {:json, 409, %{"message" => "no"}}
      assert Response.response(%{"view" => %{}}) == {:json, 200, %{"view" => %{}}}
    end
  end

  describe "latency" do
    test "every callback is measured, with its class and outcome" do
      with_telemetry([PumbleCallbackController.telemetry_event() ++ [:stop]], fn ->
        post_fixture("event_new_message.json")

        assert_receive {:telemetry, _event, %{duration: duration}, metadata}

        assert is_integer(duration)
        assert duration >= 0
        assert metadata == %{class: :event, outcome: :accepted, status: 200}
      end)
    end

    test "the warning threshold is well below Pumble's three-second deadline" do
      assert PumbleCallbackController.latency_warning_ms() < 3_000
    end

    test "exceeding the threshold reports the callback as slow" do
      put_latency_warning_ms(0)

      log =
        capture_log(fn ->
          with_telemetry([PumbleCallbackController.telemetry_event() ++ [:slow]], fn ->
            post_fixture("slash_command.json")

            assert_receive {:telemetry, _event, %{threshold_ms: 0}, %{class: :slash_command}}
          end)
        end)

      assert log =~ "pumble.callback"
      assert log =~ "error_code=slow"
    end

    test "a callback under the threshold is not reported as slow" do
      with_telemetry([PumbleCallbackController.telemetry_event() ++ [:slow]], fn ->
        post_fixture("event_new_message.json")

        refute_receive {:telemetry, _event, _measurements, _metadata}, 50
      end)
    end
  end

  defp post_fixture(file, overrides \\ %{}) do
    "callbacks/#{file}"
    |> PumbleFake.fixture()
    |> Map.merge(overrides)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Jason.encode!()
    |> post_body()
  end

  defp post_body(body) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-pumble-request-timestamp", @timestamp)
    |> Plug.Conn.put_req_header(
      "x-pumble-request-signature",
      Signature.compute(@secret, @timestamp, body)
    )
    |> post(~p"/pumble/callbacks", body)
  end

  defp with_telemetry(events, fun) do
    handler = "test-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, metadata, _config ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end
  end

  defp put_latency_warning_ms(milliseconds) do
    settings = Application.fetch_env!(:pumble_automation, :pumble_callbacks)
    on_exit(fn -> Application.put_env(:pumble_automation, :pumble_callbacks, settings) end)

    Application.put_env(
      :pumble_automation,
      :pumble_callbacks,
      Keyword.put(settings, :latency_warning_ms, milliseconds)
    )
  end

  defp install_menu_workspace(workspace_id) do
    %{installation: installation, member: member} =
      InstallationsFixtures.install(workspace: workspace_id)

    %{installation: installation, scope: Scope.new(member)}
  end

  defp activate_menu_workflow!(context, alias_name) do
    definition =
      Definition.new(
        Trigger.new(:manual, %{
          manual_alias: alias_name,
          slash_command: false,
          global_shortcut: true,
          message_shortcut: false
        }),
        [delay_node()]
      )

    workflow =
      drafted_workflow(context.installation.id, %{
        name: "Menu #{alias_name}",
        slug: alias_name,
        draft_definition: Definition.encode(definition)
      })

    {:ok, result} = Workflows.activate_workflow(context.scope, workflow.id, 0)
    result
  end

  defp put_active_workflow_limit(limit) do
    limits = Application.get_env(:pumble_automation, :limits, %{})
    on_exit(fn -> Application.put_env(:pumble_automation, :limits, limits) end)
    Application.put_env(:pumble_automation, :limits, Map.put(limits, :active_workflows, limit))
  end
end
