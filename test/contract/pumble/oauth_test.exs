defmodule PumbleAutomation.Contract.Pumble.OauthTest do
  @moduledoc """
  Token exchange against stored OAuth fixtures. Error JSON field names stay
  probe-tagged (PR-15).
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Error
  alias PumbleAutomation.Pumble.OauthClient
  alias PumbleAutomation.PumbleFake

  test "a complete grant fixture is accepted" do
    PumbleFake.stub_oauth_fixture("exchange_success.json")
    assert {:ok, tokens} = OauthClient.exchange_code("unused-code")
    body = PumbleFake.oauth_fixture_body("exchange_success.json")
    assert tokens.access_token == body["accessToken"]
    assert tokens.bot_token == body["botToken"]
    assert tokens.pumble_workspace_id == body["workspaceId"]
  end

  test "a grant without a bot token still parses; install is what refuses it" do
    PumbleFake.stub_oauth_fixture("exchange_success_without_bot_token.json")
    assert {:ok, tokens} = OauthClient.exchange_code("unused-code")
    assert is_nil(tokens.bot_token)
    assert is_nil(tokens.bot_user_id)
  end

  test "a rejected exchange is an error; field names remain a PR-15 hypothesis" do
    fixture = PumbleFake.fixture("oauth/exchange_error.json")
    assert fixture["_meta"]["live_probe"] == "PR-15"
    assert fixture["_meta"]["shape_status"] == "PROBE"

    PumbleFake.stub_oauth_fixture("exchange_error.json")

    assert {:error, %Error{code: :oauth_exchange_rejected} = error} =
             OauthClient.exchange_code("unused-code")

    assert error.details.http_status == 400
  end

  test "malformed and non-JSON bodies are errors, not exceptions" do
    PumbleFake.stub_oauth_fixture("exchange_malformed.json")
    assert {:error, %Error{}} = OauthClient.exchange_code("unused-code")

    PumbleFake.stub_oauth_fixture("exchange_not_json.json")
    assert {:error, %Error{}} = OauthClient.exchange_code("unused-code")
  end

  test "timeout and oversized emitters fail closed" do
    PumbleFake.stub_timeout()
    assert {:error, %Error{}} = OauthClient.exchange_code("unused-code")

    PumbleFake.stub_oversized()
    assert {:error, %Error{}} = OauthClient.exchange_code("unused-code")
  end

  test "the exchange sends no token or x-app-token header" do
    PumbleFake.stub_capturing(self())
    assert {:ok, _tokens} = OauthClient.exchange_code("unused-code")
    assert_receive {:pumble_request, request}

    names = Enum.map(request.headers, &elem(&1, 0))
    refute "token" in names
    refute "x-app-token" in names
    refute "authorization" in names
    assert request.method == "POST"
    assert request.path == "/oauth2/access"
  end
end
