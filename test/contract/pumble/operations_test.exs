defmodule PumbleAutomation.Contract.Pumble.OperationsTest do
  @moduledoc """
  Every retained Client operation against stored request fixtures and the fake
  that verifies method, path, headers, and body. Failure emitters are named.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.InstallationsFixtures

  alias PumbleAutomation.Pumble.Blocks
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.Pumble.Client.Error
  alias PumbleAutomation.PumbleFake

  @token "bot-access-token"

  setup do
    %{installation: installation} =
      install(tokens: %{bot_user_id: "B_FAKE001", bot_token: @token})

    {:ok, client: Client.new(installation.id)}
  end

  test "every retained operation has an API request fixture" do
    fixture_ops =
      PumbleFake.catalog()["fixtures"]
      |> Enum.filter(&(&1["kind"] == "api_request"))
      |> Enum.map(&Path.basename(&1["path"], ".json"))
      |> MapSet.new()

    named =
      Client.operations()
      |> Enum.reject(&(&1 == :send_direct_message))
      |> Enum.map(&Atom.to_string/1)
      |> MapSet.new()

    assert fixture_ops == named
  end

  test "get_profile matches A-14", %{client: client} do
    expect_fixture("get_profile.json")
    assert {:ok, %{}} = Client.get_profile(client)
    PumbleFake.assert_api_expectations_met()
  end

  test "get_workspace_info matches A-13", %{client: client} do
    expect_fixture("get_workspace_info.json")
    assert {:ok, %{}} = Client.get_workspace_info(client)
    PumbleFake.assert_api_expectations_met()
  end

  test "post_message matches A-1", %{client: client} do
    expect_fixture("post_message.json")
    assert {:ok, nil} = Client.post_message(client, "C_FAKE001", "hello")
    PumbleFake.assert_api_expectations_met()
  end

  test "reply matches A-2", %{client: client} do
    expect_fixture("reply.json")
    assert {:ok, nil} = Client.reply(client, "C_FAKE001", "M_FAKE001", "in thread")
    PumbleFake.assert_api_expectations_met()
  end

  test "get_direct_channel matches A-4 lookup", %{client: client} do
    expect_fixture("get_direct_channel.json")

    assert {:ok, %{"channel" => %{"id" => "D_FAKE001"}}} =
             Client.get_direct_channel(client, ["U_FAKE001"])

    PumbleFake.assert_api_expectations_met()
  end

  test "create_direct_channel matches A-4 create", %{client: client} do
    expect_fixture("create_direct_channel.json")

    assert {:ok, %{"channel" => %{"id" => "D_FAKE001"}}} =
             Client.create_direct_channel(client, ["U_FAKE001"])

    PumbleFake.assert_api_expectations_met()
  end

  test "send_direct_message looks up then posts when the channel exists", %{client: client} do
    PumbleFake.expect_api([
      expectation("get_direct_channel.json"),
      %{
        method: "POST",
        path: "/v1/channels/D_FAKE001/messages",
        headers: api_headers(),
        json_body: %{"text" => "hello"},
        status: 200,
        response: {:raw, ""}
      }
    ])

    assert {:ok, nil} = Client.send_direct_message(client, "U_FAKE001", "hello")
    PumbleFake.assert_api_expectations_met()
  end

  test "add_reaction matches A-5", %{client: client} do
    expect_fixture("add_reaction.json")
    assert {:ok, nil} = Client.add_reaction(client, "M_FAKE001", ":tada:", 3)
    PumbleFake.assert_api_expectations_met()
  end

  test "remove_reaction matches A-6 DELETE with JSON body", %{client: client} do
    expect_fixture("remove_reaction.json")
    assert {:ok, nil} = Client.remove_reaction(client, "M_FAKE001", ":tada:")
    PumbleFake.assert_api_expectations_met()
  end

  test "publish_home_view matches A-15", %{client: client} do
    expect_fixture("publish_home_view.json")

    assert {:ok, nil} =
             Client.publish_home_view(client, "U_FAKE001", [Blocks.rich_text("Welcome")])

    PumbleFake.assert_api_expectations_met()
  end

  test "a write timeout is ambiguous", %{client: client} do
    PumbleFake.stub_api_timeout()

    assert {:error, %Error{class: :ambiguous_transport}} =
             Client.post_message(client, "C_FAKE001", "hello")
  end

  test "a read timeout is transient", %{client: client} do
    PumbleFake.stub_api_timeout()
    assert {:error, %Error{class: :transient_transport}} = Client.get_workspace_info(client)
  end

  test "a malformed body is a typed provider error", %{client: client} do
    PumbleFake.stub_api_malformed()
    assert {:error, %Error{class: :remote_permanent}} = Client.get_workspace_info(client)
  end

  test "an oversized body is refused", %{client: client} do
    PumbleFake.stub_api_oversized()
    assert {:error, %Error{class: :resource_limit}} = Client.get_workspace_info(client)
  end

  test "a 429 is rate limited; Retry-After remains an inferred hint", %{client: client} do
    PumbleFake.stub_api_rate_limited()

    assert {:error, %Error{class: :rate_limited, status: 429} = error} =
             Client.get_workspace_info(client)

    assert is_integer(error.retry_after)
  end

  defp expect_fixture(name), do: PumbleFake.expect_api([expectation(name)])

  defp expectation(name) do
    record = PumbleFake.fixture(Path.join("api", name))
    request = record["request"]
    response = record["response"]

    %{
      method: request["method"],
      path: request["path"],
      headers: api_headers(),
      required_headers: request["required_headers"],
      forbidden_headers: request["forbidden_headers"],
      status: response["status"],
      response: response_payload(response)
    }
    |> maybe_put(:json_body, request["json_body"])
    |> maybe_put(:query, request["query"])
  end

  defp response_payload(%{"raw_body" => text}), do: {:raw, text}
  defp response_payload(%{"body" => body}), do: body

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp api_headers do
    %{
      "token" => @token,
      "x-app-token" => "test-app-key"
    }
  end
end
