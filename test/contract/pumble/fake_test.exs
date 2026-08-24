defmodule PumbleAutomation.Contract.Pumble.FakeTest do
  @moduledoc """
  The fake fails loudly on unexpected calls and checks method, path, headers,
  and body on expected ones.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.InstallationsFixtures

  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.PumbleFake

  setup do
    %{installation: installation} = install()
    {:ok, client: Client.new(installation.id)}
  end

  test "an unmatched route answers 599 instead of a plausible success", %{client: client} do
    PumbleFake.stub_api_routes(self(), [])

    assert {:error, error} = Client.get_workspace_info(client)
    assert error.status == 599
    assert error.body_summary =~ "no stub route"
  end

  test "expect_api verifies headers, forbids Authorization, and consumes the call", %{
    client: client
  } do
    PumbleFake.expect_api([
      %{
        method: "GET",
        path: "/v1/workspace",
        headers: %{
          "token" => "bot-access-token",
          "x-app-token" => "test-app-key"
        },
        required_headers: ["token", "x-app-token"],
        response: %{}
      }
    ])

    assert {:ok, %{}} = Client.get_workspace_info(client)
    PumbleFake.assert_api_expectations_met()
  end

  test "a second call after expectations are exhausted is 599", %{client: client} do
    PumbleFake.expect_api([
      %{method: "GET", path: "/v1/workspace", response: %{}}
    ])

    assert {:ok, %{}} = Client.get_workspace_info(client)
    assert {:error, error} = Client.get_workspace_info(client)
    assert error.status == 599
  end
end
