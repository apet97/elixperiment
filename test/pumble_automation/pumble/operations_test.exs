defmodule PumbleAutomation.Pumble.OperationsTest do
  @moduledoc """
  The product half of the Pumble boundary: one golden request per operation, the
  payload constructors, the scope map, and the manifest.

  A golden test here asserts the method, the path, and the body bytes, because
  those are the three things a refactor can break silently and a unit test that
  only checks the return value would not notice.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.InstallationsFixtures

  alias PumbleAutomation.Pumble.Blocks
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.Pumble.Manifest
  alias PumbleAutomation.Pumble.Scopes
  alias PumbleAutomation.PumbleFake

  @message %{"id" => "message1", "text" => "hello"}
  @direct_channel %{"channel" => %{"id" => "direct1"}}

  setup do
    %{installation: installation} = install(tokens: %{bot_user_id: "bot1"})
    {:ok, installation: installation, client: Client.new(installation.id)}
  end

  describe "identity operations" do
    test "get_profile is GET /oauth2/me, outside /v1 (A-14)", %{client: client} do
      PumbleFake.stub_api_routes(self(), [{"GET", "/oauth2/me", 200, %{"id" => "user1"}}])

      assert {:ok, %{"id" => "user1"}} = Client.get_profile(client)
      assert_receive {:pumble_api_request, %{method: "GET", path: "/oauth2/me", body: ""}}
    end

    test "get_workspace_info is GET /v1/workspace (A-13)", %{client: client} do
      PumbleFake.stub_api_routes(self(), [{"GET", "/v1/workspace", 200, %{"id" => "w1"}}])

      assert {:ok, %{"id" => "w1"}} = Client.get_workspace_info(client)
      assert_receive {:pumble_api_request, %{method: "GET", path: "/v1/workspace"}}
    end
  end

  describe "message operations" do
    test "post_message is POST /v1/channels/{cId}/messages (A-1)", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel1/messages", 200, @message}
      ])

      assert {:ok, @message} = Client.post_message(client, "channel1", "hello")
      assert_receive {:pumble_api_request, request}

      assert request.method == "POST"
      assert Jason.decode!(request.body) == %{"text" => "hello"}
      assert Map.new(request.headers)["content-type"] =~ "application/json"
    end

    test "reply posts to the message path of the thread root (A-2)", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel1/messages/root1", 200, @message}
      ])

      assert {:ok, @message} = Client.reply(client, "channel1", "root1", "in thread")
      assert_receive {:pumble_api_request, request}

      assert request.path == "/v1/channels/channel1/messages/root1"
      assert Jason.decode!(request.body) == %{"text" => "in thread"}
    end

    test "a body built by Blocks is sent as built", %{client: client} do
      {:ok, body} =
        Blocks.approval_message(
          "Approve the deploy?",
          {"Approve", "approve", "run-1"},
          {"Reject", "reject", "run-1"}
        )

      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel1/messages", 200, @message}
      ])

      assert {:ok, _message} = Client.post_message(client, "channel1", body)
      assert_receive {:pumble_api_request, request}

      assert Jason.decode!(request.body) == body
    end
  end

  describe "direct message" do
    test "an existing direct channel is used without creating one", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"GET", "/v1/channels/direct", 200, @direct_channel},
        {"POST", "/v1/channels/direct1/messages", 200, @message}
      ])

      assert {:ok, @message} = Client.send_direct_message(client, "user1", "hello")

      assert_receive {:pumble_api_request, lookup}
      assert_receive {:pumble_api_request, post}

      # The lookup carries the caller and the target, deduplicated and joined.
      assert lookup.path == "/v1/channels/direct"
      assert URI.decode_query(lookup.query) == %{"participantIds" => "bot1,user1"}
      assert post.path == "/v1/channels/direct1/messages"

      refute_received {:pumble_api_request, %{method: "POST", path: "/v1/channels/direct"}}
    end

    test "a missing direct channel is created, then used", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"GET", "/v1/channels/direct", 404, %{"message" => "not found"}},
        {"POST", "/v1/channels/direct", 200, @direct_channel},
        {"POST", "/v1/channels/direct1/messages", 200, @message}
      ])

      assert {:ok, @message} = Client.send_direct_message(client, "user1", "hello")

      assert_receive {:pumble_api_request, _lookup}
      assert_receive {:pumble_api_request, create}
      assert_receive {:pumble_api_request, post}

      # The create body carries the other participant only; the caller is
      # implied by the credential.
      assert create.path == "/v1/channels/direct"
      assert Jason.decode!(create.body) == %{"participantIds" => ["user1"]}
      assert post.path == "/v1/channels/direct1/messages"
    end

    test "a lookup that fails for another reason is not turned into a create", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"GET", "/v1/channels/direct", 403, %{"message" => "forbidden"}}
      ])

      assert {:error, error} = Client.send_direct_message(client, "user1", "hello")
      assert error.class == :authorization
    end

    test "more participants than a direct channel holds is refused locally", %{client: client} do
      ids = Enum.map(1..9, &"user#{&1}")

      assert {:error, error} = Client.create_direct_channel(client, ids)
      assert error.class == :validation
    end
  end

  describe "reactions" do
    test "add_reaction posts the reaction as the body (A-5)", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/messages/message1/reactions", 200, {:raw, ""}}
      ])

      assert {:ok, nil} = Client.add_reaction(client, "message1", ":tada:", 3)
      assert_receive {:pumble_api_request, request}

      assert request.path == "/v1/messages/message1/reactions"
      assert Jason.decode!(request.body) == %{"code" => ":tada:", "skinTone" => 3}
    end

    test "remove_reaction sends a JSON body on DELETE (A-6)", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"DELETE", "/v1/messages/message1/reactions", 200, {:raw, ""}}
      ])

      assert {:ok, nil} = Client.remove_reaction(client, "message1", ":tada:")
      assert_receive {:pumble_api_request, request}

      assert request.method == "DELETE"
      assert Jason.decode!(request.body) == %{"code" => ":tada:"}
      assert request.query == ""
    end

    test "a reaction code outside the documented shape never reaches the network", %{
      client: client
    } do
      assert {:error, %{class: :validation}} = Client.add_reaction(client, "message1", "tada")
      assert {:error, %{class: :validation}} = Client.add_reaction(client, "message1", "::")

      assert {:error, %{class: :validation}} =
               Client.add_reaction(client, "message1", ":#{String.duplicate("x", 200)}:")
    end
  end

  describe "home view" do
    test "publish_home_view posts blocks to the workspace user path (A-15)", %{client: client} do
      blocks = [Blocks.rich_text("Welcome")]

      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/app/homeView/workspaceUsers/user1", 200, {:raw, ""}}
      ])

      assert {:ok, nil} = Client.publish_home_view(client, "user1", blocks)
      assert_receive {:pumble_api_request, request}

      assert Jason.decode!(request.body) == %{"blocks" => blocks}
    end
  end

  describe "payload limits" do
    test "message text is bounded by a local cap that names its probe" do
      assert {:error, error} = Blocks.message(String.duplicate("x", Blocks.max_text_bytes() + 1))
      assert error.class == :validation
      assert error.body_summary =~ "PR-12"
    end

    test "message text must be present, textual, and valid UTF-8" do
      assert {:error, _error} = Blocks.message("")
      assert {:error, _error} = Blocks.message("  ")
      assert {:error, _error} = Blocks.message(nil)
      assert {:error, _error} = Blocks.message(<<0xFF, 0xFE>>)
    end

    test "blocks are bounded and must be maps" do
      assert {:error, _error} =
               Blocks.message("hello", List.duplicate(%{}, Blocks.max_blocks() + 1))

      assert {:error, _error} = Blocks.message("hello", ["not a block"])
    end

    test "a button label is bounded at the documented 75 characters" do
      long = String.duplicate("x", 76)

      assert {:error, error} =
               Blocks.approval_message("Approve?", {long, "approve", "1"}, {"No", "reject", "1"})

      assert error.class == :validation
    end

    test "approval buttons never start a spinner this application cannot stop" do
      {:ok, body} =
        Blocks.approval_message("Approve?", {"Yes", "approve", "1"}, {"No", "reject", "1"})

      [_text_block, actions] = body["blocks"]

      assert Enum.map(actions["elements"], & &1["loadingTimeout"]) == [0, 0]
      assert Enum.map(actions["elements"], & &1["onAction"]) == ["approve", "reject"]
    end
  end

  describe "scope map" do
    test "every operation has a mapping and every mapping is a catalog scope" do
      for operation <- Client.operations() do
        mapping = Scopes.mapping(operation)

        case Scopes.scope_of(mapping) do
          nil -> assert match?({:unverified, _probe}, mapping)
          scope -> assert scope in Scopes.catalog()
        end
      end
    end

    test "an unproven mapping is a distinct shape and carries its probe" do
      assert {:inferred, "messages:write", "PR-07"} = Scopes.mapping(:post_message)
      assert {:unverified, "PR-07"} = Scopes.mapping(:publish_home_view)
      assert {:unverified, "PR-07"} = Scopes.mapping(:invented_operation)
    end

    test "each v1 action maps to the scope the matrix names" do
      assert Scopes.scope(:post_message) == "messages:write"
      assert Scopes.scope(:reply) == "messages:write"
      assert Scopes.scope(:send_direct_message) == "messages:write"
      assert Scopes.scope(:create_direct_channel) == "channels:write"
      assert Scopes.scope(:add_reaction) == "reaction:write"
      assert Scopes.scope(:remove_reaction) == "reaction:write"
      assert Scopes.scope(:get_workspace_info) == "workspace:read"
    end

    test "the gate refuses a call the snapshot proves cannot work" do
      assert {:error, error} = Scopes.check(:post_message, ["workspace:read"])
      assert error.class == :missing_scope
      assert error.body_summary =~ "messages:write"
      assert error.body_summary =~ "PR-07"
    end

    test "the gate passes when the snapshot proves the grant" do
      assert :ok = Scopes.check(:post_message, ["messages:write"])
    end

    test "an empty snapshot means unknown, never absent" do
      assert :ok = Scopes.check(:post_message, [])
    end

    test "an unverified mapping never blocks a call" do
      assert :ok = Scopes.check(:publish_home_view, ["messages:write"])
    end

    test "a verified mapping gates without a probe caveat" do
      assert {:error, error} = Scopes.check_mapping({:verified, "users:list"}, ["user:read"])
      assert error.class == :missing_scope
      refute error.body_summary =~ "PR-"
      assert :ok = Scopes.check_mapping({:verified, "users:list"}, ["users:list"])
    end
  end

  describe "the scope gate runs before the network" do
    test "a proven-absent scope fails with no stub installed" do
      %{installation: installation} = install()

      installation
      |> Ecto.Changeset.change(bot_scopes: ["workspace:read"])
      |> Repo.update!()

      client = Client.new(installation.id)

      # No stub: a request would raise rather than return an error.
      assert {:error, error} = Client.post_message(client, "channel1", "hello")
      assert error.class == :missing_scope
      assert error.status == nil
    end
  end

  describe "retry safety" do
    test "reads and reaction writes may be repeated; message writes may not" do
      assert Client.retry_safety(:get_profile) == :read_only
      assert Client.retry_safety(:get_workspace_info) == :read_only
      assert Client.retry_safety(:get_direct_channel) == :read_only
      assert Client.retry_safety(:add_reaction) == :idempotent_effect
      assert Client.retry_safety(:remove_reaction) == :idempotent_effect
      assert Client.retry_safety(:post_message) == :not_idempotent
      assert Client.retry_safety(:reply) == :not_idempotent
      assert Client.retry_safety(:send_direct_message) == :not_idempotent
      assert Client.retry_safety(:create_direct_channel) == :not_idempotent
      assert Client.retry_safety(:publish_home_view) == :not_idempotent
    end

    test "an unknown operation is assumed unsafe to repeat" do
      assert Client.retry_safety(:invented_operation) == :not_idempotent
    end

    test "every operation declares one" do
      for operation <- Client.operations() do
        assert Client.retry_safety(operation) in [
                 :read_only,
                 :idempotent_effect,
                 :not_idempotent
               ]
      end
    end
  end

  describe "manifest" do
    test "the frozen entry points are the three the contract names" do
      manifest = Manifest.build()
      rendered = Manifest.render(manifest)

      assert rendered["name"] == "workflow-automation"
      assert rendered["displayName"] == "Workflow Automation"
      assert rendered["bot"] == true
      assert [%{"command" => "/workflow"}] = rendered["slashCommands"]

      assert [
               %{
                 "displayName" => "Run workflow",
                 "shortcutType" => "GLOBAL",
                 "name" => "run_workflow"
               },
               %{"displayName" => "Run workflow on message", "shortcutType" => "ON_MESSAGE"}
             ] = rendered["shortcuts"]
    end

    test "shortcut names are normalized the way the callback will spell them" do
      assert Manifest.normalize_name("Run workflow on message") == "run_workflow_on_message"
    end

    test "every callback class reaches the one configured callback path" do
      rendered = Manifest.build() |> Manifest.render()
      url = rendered["eventSubscriptions"]["url"]

      assert url =~ "/pumble/callbacks"
      assert rendered["blockInteraction"]["url"] == url
      assert rendered["viewAction"]["url"] == url
      assert rendered["dynamicMenus"] == [%{"onAction" => "pick_workflow", "url" => url}]
      assert Enum.all?(rendered["shortcuts"], &(&1["url"] == url))
    end

    test "the subscribed events are the trigger and lifecycle sets, and nothing else" do
      events = Manifest.build() |> Manifest.render() |> get_in(["eventSubscriptions", "events"])

      assert "NEW_MESSAGE" in events
      assert "APP_UNINSTALLED" in events
      assert length(events) == 7
    end

    test "no secret can appear in a rendered manifest" do
      json = Manifest.build() |> Manifest.to_json()

      refute json =~ "test-app-key"
      refute json =~ "test-client-secret"
      refute json =~ "test-signing-secret"
      assert json =~ "test-client-id"
    end
  end
end
