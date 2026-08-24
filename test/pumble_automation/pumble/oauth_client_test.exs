defmodule PumbleAutomation.Pumble.OauthClientTest do
  @moduledoc """
  The code exchange, against a stub standing in for Pumble.

  The wire assertions here are the ones a refactor could break silently: the
  hyphenated multipart field names, the absence of the authentication headers
  every other Pumble call carries, and the path. They are transcribed from
  `docs/evidence/pumble_source_matrix.md` entries `A-16` and `H-16`, which are
  SDK-source-verified rather than inferred.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Pumble.OauthClient
  alias PumbleAutomation.PumbleFake

  describe "exchange_code/1 wire format" do
    test "posts multipart/form-data to /oauth2/access with hyphenated field names" do
      PumbleFake.stub_capturing(self())

      assert {:ok, _tokens} = OauthClient.exchange_code("the-authorization-code")

      assert_receive {:pumble_request, request}

      assert request.method == "POST"
      assert request.path == "/oauth2/access"
      assert [content_type] = request.content_type
      assert content_type =~ "multipart/form-data"
      assert content_type =~ "boundary="

      assert request.body =~ ~s(name="client-id")
      assert request.body =~ ~s(name="client-secret")
      assert request.body =~ ~s(name="code")
      assert request.body =~ "the-authorization-code"
      assert request.body =~ "test-client-id"

      # The underscored spellings are the plausible mistake, so they are asserted
      # against rather than assumed absent.
      refute request.body =~ ~s(name="client_id")
      refute request.body =~ ~s(name="client_secret")
    end

    test "sends no token and no x-app-token header: the exchange is unauthenticated" do
      PumbleFake.stub_capturing(self())

      assert {:ok, _tokens} = OauthClient.exchange_code("code")

      assert_receive {:pumble_request, request}

      names = Enum.map(request.headers, fn {name, _value} -> String.downcase(name) end)

      refute "token" in names
      refute "x-app-token" in names
      refute "authorization" in names
    end

    test "goes to the configured base URL and never to one derived from a payload" do
      assert OauthClient.base_url() ==
               Application.fetch_env!(:pumble_automation, :pumble)[:api_base_url]
    end
  end

  describe "exchange_code/1 success" do
    test "renames the five documented fields into this application's vocabulary" do
      PumbleFake.stub_success()

      assert {:ok, tokens} = OauthClient.exchange_code("code")

      assert tokens.access_token == "user-access-token"
      assert tokens.bot_token == "bot-access-token"
      assert tokens.bot_user_id == "pumble-bot-1"
      assert tokens.pumble_user_id == "pumble-user-1"
      assert tokens.pumble_workspace_id == "pumble-workspace-1"
    end

    test "treats the bot fields as optional, because the response says they are" do
      PumbleFake.stub_success(%{"botToken" => nil, "botId" => nil})

      assert {:ok, tokens} = OauthClient.exchange_code("code")

      assert is_nil(tokens.bot_token)
      assert is_nil(tokens.bot_user_id)
      assert tokens.access_token == "user-access-token"
    end

    test "ignores fields the documented response does not have" do
      PumbleFake.stub_success(%{"expiresIn" => 3600, "refreshToken" => "nope"})

      assert {:ok, tokens} = OauthClient.exchange_code("code")

      refute Map.has_key?(tokens, :expires_in)
      refute Map.has_key?(tokens, :refresh_token)
      assert map_size(tokens) == 5
    end
  end

  describe "exchange_code/1 failure" do
    test "rejects a body that is not JSON" do
      PumbleFake.stub_malformed(:not_json)

      assert {:error, error} = OauthClient.exchange_code("code")
      assert error.code == :oauth_response_malformed
      assert error.class == :dependency
    end

    test "rejects JSON that parses but is missing a required field" do
      PumbleFake.stub_malformed(:missing_field)

      assert {:error, error} = OauthClient.exchange_code("code")
      assert error.code == :oauth_response_malformed
      assert error.details.missing_field == "workspaceId"
    end

    test "rejects a required field that is present but empty" do
      PumbleFake.stub_success(%{"accessToken" => ""})

      assert {:error, error} = OauthClient.exchange_code("code")
      assert error.code == :oauth_response_malformed
    end

    test "reports a timeout as a timeout, and as retryable" do
      PumbleFake.stub_timeout()

      assert {:error, error} = OauthClient.exchange_code("code")
      assert error.class == :timeout
      assert error.code == :oauth_exchange_timeout
      assert error.retryable?
    end

    test "abandons a response past the size cap" do
      PumbleFake.stub_oversized()

      assert {:error, error} = OauthClient.exchange_code("code")
      assert error.code == :oauth_response_too_large
      assert error.details.limit_bytes == OauthClient.max_response_bytes()
    end

    test "a 4xx is not retryable and a 5xx is" do
      PumbleFake.stub_json(400, %{"error" => "invalid_grant"})
      assert {:error, client_error} = OauthClient.exchange_code("code")
      assert client_error.code == :oauth_exchange_rejected
      assert client_error.details.http_status == 400
      refute client_error.retryable?

      PumbleFake.stub_json(503, %{})
      assert {:error, server_error} = OauthClient.exchange_code("code")
      assert server_error.details.http_status == 503
      assert server_error.retryable?
    end

    test "does not follow a redirect away from the token endpoint" do
      Req.Test.stub(OauthClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.test/collect")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, error} = OauthClient.exchange_code("code")
      assert error.code == :oauth_exchange_rejected
      assert error.details.http_status == 302
    end

    test "refuses an absent or empty code without making a request" do
      Req.Test.stub(OauthClient, fn _conn ->
        flunk("the client must not send a request without a code")
      end)

      for bad <- [nil, "", 42] do
        assert {:error, error} = OauthClient.exchange_code(bad)
        assert error.code == :oauth_code_missing
      end
    end
  end

  describe "exchange_code/1 does not retry" do
    test "sends the code exactly once, however the service answers" do
      parent = self()

      Req.Test.stub(OauthClient, fn conn ->
        send(parent, :attempt)
        Plug.Conn.send_resp(conn, 500, "")
      end)

      assert {:error, _error} = OauthClient.exchange_code("single-use-code")

      assert_receive :attempt
      refute_receive :attempt, 50
    end

    test "does not retry after a transport failure either" do
      parent = self()

      Req.Test.stub(OauthClient, fn conn ->
        send(parent, :attempt)
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, _error} = OauthClient.exchange_code("single-use-code")

      assert_receive :attempt
      refute_receive :attempt, 50
    end
  end

  describe "redaction" do
    test "no error carries the code, the client secret, or a token" do
      code = "super-secret-code-9f3a"

      stubs = [
        fn -> PumbleFake.stub_malformed(:not_json) end,
        fn -> PumbleFake.stub_malformed(:missing_field) end,
        fn -> PumbleFake.stub_timeout() end,
        fn -> PumbleFake.stub_oversized() end,
        fn -> PumbleFake.stub_json(400, %{"code" => code}) end
      ]

      for install <- stubs do
        install.()

        assert {:error, error} = OauthClient.exchange_code(code)

        rendered = inspect(error, limit: :infinity, printable_limit: :infinity)

        refute rendered =~ code
        refute rendered =~ "test-client-secret"
        refute rendered =~ "bot-access-token"
        refute rendered =~ "user-access-token"
      end
    end

    test "a details map that names a secret is redacted by the error type" do
      PumbleFake.stub_json(400, %{})

      assert {:error, error} = OauthClient.exchange_code("code")

      assert error.details
             |> Map.keys()
             |> Enum.all?(fn key ->
               not Regex.match?(PumbleAutomation.Error.secret_key_pattern(), to_string(key))
             end)
    end
  end
end
