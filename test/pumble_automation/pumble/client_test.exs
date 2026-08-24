defmodule PumbleAutomation.Pumble.ClientTest do
  @moduledoc """
  The transport half of the Pumble boundary: headers, bounds, classification of
  what comes back, and the local refusals that happen before anything is sent.

  Every test here goes through a named operation, because a named operation is
  the only way into the transport.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.InstallationsFixtures

  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.Pumble.Client.Error
  alias PumbleAutomation.Pumble.Client.Transport
  alias PumbleAutomation.PumbleFake

  setup do
    %{installation: installation} = install()
    {:ok, installation: installation, client: Client.new(installation.id)}
  end

  describe "headers" do
    test "every call carries token and x-app-token, and no Authorization", %{client: client} do
      PumbleFake.stub_api_routes(self(), [{"GET", "/v1/workspace", 200, %{"id" => "w-1"}}])

      assert {:ok, _body} = Client.get_workspace_info(client)
      assert_receive {:pumble_api_request, request}

      headers = Map.new(request.headers)

      assert headers["token"] == "bot-access-token"
      assert headers["x-app-token"] == "test-app-key"
      refute Map.has_key?(headers, "authorization")
    end

    test "a user credential sends that member's token, not the bot's" do
      %{installation: installation} =
        install(tokens: %{access_token: "member-access-token", pumble_user_id: "member-1"})

      client = Client.new(installation.id, {:user, "member-1"})

      PumbleFake.stub_api_routes(self(), [{"GET", "/oauth2/me", 200, %{"id" => "member-1"}}])

      assert {:ok, _body} = Client.get_profile(client)
      assert_receive {:pumble_api_request, request}

      assert Map.new(request.headers)["token"] == "member-access-token"
    end
  end

  describe "credential binding" do
    test "two workspaces produce two clients, each with its own credential" do
      %{installation: first} = install(tokens: %{bot_token: "bot-token-first"})
      %{installation: second} = install(tokens: %{bot_token: "bot-token-second"})

      PumbleFake.stub_api_routes(self(), [{"GET", "/v1/workspace", 200, %{"id" => "w"}}])

      assert {:ok, _body} = first.id |> Client.new() |> Client.get_workspace_info()
      assert_receive {:pumble_api_request, first_request}

      assert {:ok, _body} = second.id |> Client.new() |> Client.get_workspace_info()
      assert_receive {:pumble_api_request, second_request}

      assert Map.new(first_request.headers)["token"] == "bot-token-first"
      assert Map.new(second_request.headers)["token"] == "bot-token-second"
    end

    test "a client names its installation and nothing can move it", %{
      client: client,
      installation: installation
    } do
      assert client.installation_id == installation.id
      assert client.credential_kind == :bot

      # There is no setter, and the struct is the only place the id lives.
      refute Enum.any?(Client.__info__(:functions), fn {name, _arity} ->
               name in [:put_installation, :with_installation, :rebind]
             end)
    end
  end

  describe "local refusals happen before the network" do
    test "a revoked installation fails with no stub installed at all", %{
      installation: installation,
      client: client
    } do
      {:ok, _installation} = Lifecycle.mark_unauthorized(installation.id)

      # No `stub_api` call in this test: reaching the network would raise
      # instead of returning, so a passing assertion proves nothing was sent.
      assert {:error, error} = Client.post_message(client, "channel1", "hello")
      assert error.class == :installation_revoked
      assert error.status == nil
    end

    test "an unknown installation is not found" do
      client = Client.new(Ecto.UUID.generate())

      assert {:error, error} = Client.get_workspace_info(client)
      assert error.class == :not_found
    end

    test "a member who never authorized fails before the network", %{
      installation: installation
    } do
      client = Client.new(installation.id, {:user, "stranger"})

      assert {:error, error} = Client.get_profile(client)
      assert error.class == :authentication
    end

    test "an identifier that could reshape the URL is refused", %{client: client} do
      assert {:error, error} = Client.post_message(client, "../../v1/app/installation", "hi")
      assert error.class == :validation
      assert error.body_summary =~ "channel id"
    end

    test "an empty message is refused before the network", %{client: client} do
      assert {:error, error} = Client.post_message(client, "channel1", "   ")
      assert error.class == :validation
    end
  end

  describe "response handling" do
    test "a timeout on a write is ambiguous rather than transient", %{client: client} do
      PumbleFake.stub_api(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, error} = Client.post_message(client, "channel1", "hello")
      assert error.class == :ambiguous_transport
    end

    test "a timeout on a read is transient", %{client: client} do
      PumbleFake.stub_api(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, error} = Client.get_workspace_info(client)
      assert error.class == :transient_transport
    end

    test "a body past the cap is refused instead of decoded", %{client: client} do
      oversized = String.duplicate("x", Transport.max_response_bytes() * 2)

      PumbleFake.stub_api(fn conn -> Plug.Conn.send_resp(conn, 200, oversized) end)

      assert {:error, error} = Client.get_workspace_info(client)
      assert error.class == :resource_limit
    end

    test "a 200 that is not JSON is a typed provider error", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"GET", "/v1/workspace", 200, {:raw, "<html>maintenance</html>"}}
      ])

      assert {:error, error} = Client.get_workspace_info(client)
      assert error.class == :remote_permanent
      assert error.body_summary =~ "not JSON"
    end

    test "a 2xx with an empty body is a success", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/messages/message1/reactions", 204, {:raw, ""}}
      ])

      assert {:ok, nil} = Client.add_reaction(client, "message1", ":tada:")
    end

    test "a 429 carries the bounded retry hint", %{client: client} do
      PumbleFake.stub_api(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "45")
        |> Plug.Conn.send_resp(429, ~s({"message":"slow down"}))
      end)

      assert {:error, error} = Client.get_workspace_info(client)
      assert error.class == :rate_limited
      assert error.retry_after == 45
    end

    test "a 401 is never transient", %{client: client} do
      PumbleFake.stub_api_routes(self(), [{"GET", "/v1/workspace", 401, %{"message" => "no"}}])

      assert {:error, error} = Client.get_workspace_info(client)
      assert error.class == :authentication
      refute Error.retryable?(error)
    end

    test "an error body is summarized with its secrets redacted", %{client: client} do
      PumbleFake.stub_api_routes(self(), [
        {"GET", "/v1/workspace", 400, %{"token" => "leaked-token", "message" => "bad"}}
      ])

      assert {:error, error} = Client.get_workspace_info(client)
      refute error.body_summary =~ "leaked-token"
      assert error.body_summary =~ "REDACTED"
    end

    test "the provider's request id is carried into the error", %{client: client} do
      PumbleFake.stub_api(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-request-id", "provider-req-9")
        |> Plug.Conn.send_resp(500, "{}")
      end)

      assert {:error, error} = Client.get_workspace_info(client)
      assert error.provider_request_id == "provider-req-9"
    end
  end

  describe "telemetry" do
    test "a call reports its workspace, operation, and correlation", %{
      installation: installation
    } do
      correlation_id = "client-test-#{System.unique_integer([:positive])}"
      client = Client.new(installation.id, :bot, correlation_id: correlation_id)
      handler = "pumble-client-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        Transport.telemetry_event() ++ [:stop],
        fn event, measurements, metadata, expected_correlation_id ->
          if metadata.correlation_id == expected_correlation_id do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        correlation_id
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      PumbleFake.stub_api_routes(self(), [{"GET", "/v1/workspace", 200, %{"id" => "w"}}])
      assert {:ok, _body} = Client.get_workspace_info(client)

      assert_receive {:telemetry, _event, %{duration: duration}, metadata}
      assert is_integer(duration)
      assert metadata.operation == :get_workspace_info
      assert metadata.workspace_id == installation.pumble_workspace_id
      assert metadata.correlation_id == correlation_id
      assert metadata.status == :ok
    end

    test "no token reaches telemetry metadata", %{installation: installation} do
      correlation_id = "client-secret-test-#{System.unique_integer([:positive])}"
      client = Client.new(installation.id, :bot, correlation_id: correlation_id)
      handler = "pumble-client-secrets-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        Transport.telemetry_event() ++ [:start],
        fn _event, _measurements, metadata, expected_correlation_id ->
          if metadata.correlation_id == expected_correlation_id do
            send(test_pid, {:telemetry_start, metadata})
          end
        end,
        correlation_id
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      PumbleFake.stub_api_routes(self(), [{"GET", "/v1/workspace", 200, %{"id" => "w"}}])
      assert {:ok, _body} = Client.get_workspace_info(client)

      assert_receive {:telemetry_start, metadata}
      refute inspect(metadata) =~ "bot-access-token"
      refute Enum.any?(Map.keys(metadata), &(&1 in [:token, :headers, :body]))
    end
  end
end
