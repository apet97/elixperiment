defmodule PumbleAutomation.PumbleFake do
  @moduledoc """
  A stand-in for the Pumble authorization service and JSON API.

  Every function here installs a `Req.Test` stub for
  `PumbleAutomation.Pumble.OauthClient` or `PumbleAutomation.Pumble.Client`,
  which `config/test.exs` points those clients at. There is no socket, no port,
  and no server process: the stub is a plug called in the calling process, so a
  test needs no cleanup and no sleep, and two async tests cannot see each
  other's stub.

  `expect_api/1` is the contract-suite form: it verifies method, path, headers,
  query, and body, and fails the test on a mismatch. `stub_api_routes/2` is the
  looser unit-test form: unmatched requests still answer `599` so they cannot
  look like success.

  ## Why a stub and not a real server

  A real HTTP server would test Bandit and Finch, which are already tested. What
  needs testing here is this application's behaviour when the far side answers
  well, badly, slowly, or not at all — and a stub reaches those four cases
  directly instead of arranging for them.

  The one thing a stub cannot check is the bytes on the wire, so
  `stub_capturing/2` hands the request to the test. Use it to prove the multipart
  encoding and the hyphenated field names of `A-16`, which are the parts of this
  request a refactor could silently break.

  ## Ownership

  `Req.Test` stubs belong to the process that installs them. Phoenix's
  `ConnTest` dispatches in the test process, so a controller test that calls
  these functions is already the owner. A stub used from a spawned task needs
  `Req.Test.allow/3`.
  """

  import ExUnit.Assertions

  alias PumbleAutomation.Pumble.Client.Transport

  @client PumbleAutomation.Pumble.OauthClient
  @api_client PumbleAutomation.Pumble.Client
  @expect_key :pumble_fake_api_expectations

  @default_tokens %{
    "accessToken" => "user-access-token",
    "botToken" => "bot-access-token",
    "userId" => "pumble-user-1",
    "botId" => "pumble-bot-1",
    "workspaceId" => "pumble-workspace-1"
  }

  @doc """
  Answers `200` with a well-formed exchange response.

  `overrides` is merged over the default body, so a test names only the field it
  cares about. A `nil` value removes the field, which is how the "grant carried
  no bot token" case is built.
  """
  @spec stub_success(map()) :: :ok
  def stub_success(overrides \\ %{}) do
    body =
      @default_tokens
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    stub_json(200, body)
  end

  @doc "Answers `status` with an arbitrary JSON body."
  @spec stub_json(non_neg_integer(), map()) :: :ok
  def stub_json(status, body) do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  @doc """
  Answers `200` with a body that is not the documented shape.

  Covers both halves of "malformed": text that is not JSON at all, and JSON that
  parses but is missing a field the flow requires.
  """
  @spec stub_malformed(:not_json | :missing_field) :: :ok
  def stub_malformed(kind \\ :not_json)

  def stub_malformed(:not_json) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, "<html>maintenance</html>") end)
  end

  def stub_malformed(:missing_field) do
    stub_json(200, Map.delete(@default_tokens, "workspaceId"))
  end

  @doc "Never answers: the connection fails the way a hung service does."
  @spec stub_timeout() :: :ok
  def stub_timeout do
    stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
  end

  @doc """
  Answers `200` with a body far past the client's cap.

  The body is generated rather than stored, so this costs the test nothing until
  the client reads it — and the client is supposed to stop reading.
  """
  @spec stub_oversized() :: :ok
  def stub_oversized do
    size = @client.max_response_bytes() * 2
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", size)) end)
  end

  @doc """
  Answers `200` and sends the decoded request to `pid` as `{:pumble_request, map}`.

  The message carries the request's `content-type` and its raw body, which is
  what a multipart assertion needs.
  """
  @spec stub_capturing(pid(), map()) :: :ok
  def stub_capturing(pid, overrides \\ %{}) do
    body = Map.merge(@default_tokens, overrides)

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        pid,
        {:pumble_request,
         %{
           method: conn.method,
           path: conn.request_path,
           content_type: Plug.Conn.get_req_header(conn, "content-type"),
           headers: conn.req_headers,
           body: raw
         }}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  @doc """
  Reads a stored fixture, relative to `priv/pumble/fixtures`.

  The fixtures are sanitized recordings of shapes this application must handle.
  They exist so that a response shape lives in one reviewable file instead of
  being spelled out again in every test that needs it, and so that an unproven
  shape can be annotated where it is defined. Every identifier in them is
  obviously fake.
  """
  @spec fixture(String.t()) :: map()
  def fixture(path) when is_binary(path) do
    :pumble_automation
    |> Application.app_dir("priv/pumble/fixtures")
    |> Path.join(path)
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Answers the exchange with the stored fixture named by `name`.

  `name` is a file under `priv/pumble/fixtures/oauth`. A fixture carries the
  status it answers with, so a test names the case rather than the status.
  """
  @spec stub_oauth_fixture(String.t()) :: :ok
  def stub_oauth_fixture(name) when is_binary(name) do
    case fixture(Path.join("oauth", name)) do
      %{"status" => status, "body" => body} ->
        stub_json(status, body)

      %{"status" => status, "body_text" => text} ->
        stub(fn conn -> Plug.Conn.send_resp(conn, status, text) end)
    end
  end

  @doc "The body of an OAuth fixture, as Pumble's JSON field names."
  @spec oauth_fixture_body(String.t()) :: map()
  def oauth_fixture_body(name) when is_binary(name) do
    Map.fetch!(fixture(Path.join("oauth", name)), "body")
  end

  @doc """
  An OAuth fixture body as this application's token map.

  The same field mapping `PumbleAutomation.Pumble.OauthClient` performs, so a
  test that calls the installations context directly still starts from the
  stored shape rather than from a map written out by hand. `overrides` names the
  workspace or user a test needs to differ.
  """
  @spec tokens_from_fixture(String.t(), map() | keyword()) :: map()
  def tokens_from_fixture(name, overrides \\ %{}) do
    body = oauth_fixture_body(name)

    %{
      access_token: body["accessToken"],
      bot_token: body["botToken"],
      bot_user_id: body["botId"],
      pumble_user_id: body["userId"],
      pumble_workspace_id: body["workspaceId"]
    }
    |> Map.merge(Map.new(overrides))
  end

  @doc "The default exchange response, as this application's token map."
  @spec tokens(map()) :: map()
  def tokens(overrides \\ %{}) do
    Map.merge(
      %{
        access_token: @default_tokens["accessToken"],
        bot_token: @default_tokens["botToken"],
        bot_user_id: @default_tokens["botId"],
        pumble_user_id: @default_tokens["userId"],
        pumble_workspace_id: @default_tokens["workspaceId"]
      },
      overrides
    )
  end

  @doc "The default exchange response body, as Pumble's JSON field names."
  @spec default_response() :: map()
  def default_response, do: @default_tokens

  @doc """
  Installs a stub for the Pumble JSON API client.

  `PumbleAutomation.Pumble.Client` has a stub name of its own, separate from the
  token exchange's, so a test about an API operation and a test about the
  exchange cannot install stubs over each other.

  `fun` is a plug. Prefer `stub_api_routes/2` unless the test is about a
  response the router cannot express, such as a header or a transport failure.
  """
  @spec stub_api((Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def stub_api(fun) when is_function(fun, 1), do: Req.Test.stub(@api_client, fun)

  @doc """
  Answers each request from `routes`, and reports every request to `pid`.

  A route is `{method, path, status, body}`; `method` is an uppercase string,
  `path` is matched exactly, and `body` is encoded as JSON unless it is
  `{:raw, text}`. The first matching route answers.

  A request that matches no route is answered `599` with a marker body, so an
  unexpected call fails the test that made it instead of falling through to a
  plausible-looking success.

  Every request arrives at `pid` as `{:pumble_api_request, map}` carrying the
  method, path, query string, headers, and raw body — which is what a golden
  request assertion needs.
  """
  @spec stub_api_routes(pid(), [{String.t(), String.t(), non_neg_integer(), term()}]) :: :ok
  def stub_api_routes(pid, routes) when is_list(routes) do
    stub_api(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        pid,
        {:pumble_api_request,
         %{
           method: conn.method,
           path: conn.request_path,
           query: conn.query_string,
           headers: conn.req_headers,
           body: raw
         }}
      )

      routes
      |> Enum.find(fn {method, path, _status, _body} ->
        method == conn.method and path == conn.request_path
      end)
      |> respond(conn)
    end)
  end

  @doc """
  Installs ordered API expectations that verify the request, then answer it.

  Each expectation is a map:

    * `:method` and `:path` — exact match, required
    * `:query` — exact query string, or a map compared via `URI.decode_query/1`
    * `:headers` — name → exact value (names are lowercase)
    * `:required_headers` — names that must be present
    * `:forbidden_headers` — defaults to `authorization`
    * `:json_body` — decoded JSON that must equal the body
    * `:raw_body` — exact body bytes
    * `:status` — default `200`
    * `:response` — a JSON map, `{:raw, text}`, `:timeout`, `:malformed`,
      `:oversized`, or `:rate_limited`

  A method or path that does not match the next expectation fails the test
  immediately. A request that arrives after the list is exhausted answers `599`.
  Call `assert_api_expectations_met/0` after the adapter returns.
  """
  @spec expect_api([map()]) :: :ok
  def expect_api(expectations) when is_list(expectations) and expectations != [] do
    Process.put(@expect_key, Enum.map(expectations, &normalize_expectation/1))

    stub_api(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      case Process.get(@expect_key, []) do
        [] ->
          respond(nil, conn)

        [expected | rest] ->
          verify_expectation!(expected, conn, raw)
          Process.put(@expect_key, rest)
          emit_expected(expected, conn)
      end
    end)
  end

  @doc "Fails unless every `expect_api/1` entry was consumed."
  @spec assert_api_expectations_met() :: :ok
  def assert_api_expectations_met do
    remaining = Process.get(@expect_key, [])

    assert remaining == [],
           "Pumble fake still expected #{length(remaining)} request(s): #{inspect(remaining)}"

    :ok
  end

  @doc "Never answers: the connection fails the way a hung API does."
  @spec stub_api_timeout() :: :ok
  def stub_api_timeout do
    stub_api(fn conn -> Req.Test.transport_error(conn, :timeout) end)
  end

  @doc "Answers `200` with a body that is not JSON."
  @spec stub_api_malformed() :: :ok
  def stub_api_malformed do
    stub_api(fn conn -> Plug.Conn.send_resp(conn, 200, "<html>maintenance</html>") end)
  end

  @doc "Answers `200` with a body far past the client's cap."
  @spec stub_api_oversized() :: :ok
  def stub_api_oversized do
    size = Transport.max_response_bytes() * 2
    stub_api(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", size)) end)
  end

  @doc """
  Answers `429`.

  The status class is what the adapter must handle. The `Retry-After` header is
  an `INFERRED` hint (`H-14`, `PR-08`); this helper emits one so the existing
  classifier stays exercised, and must not be read as a proven header name.
  """
  @spec stub_api_rate_limited() :: :ok
  def stub_api_rate_limited do
    stub_api(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "2")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, ~s({"message":"slow down"}))
    end)
  end

  @doc "Root of `priv/pumble/fixtures`."
  @spec fixtures_root() :: String.t()
  def fixtures_root do
    Application.app_dir(:pumble_automation, "priv/pumble/fixtures")
  end

  @doc "The provenance catalog for every stored fixture."
  @spec catalog() :: map()
  def catalog, do: fixture("catalog.json")

  defp normalize_expectation(expected) when is_map(expected) do
    expected
    |> Map.put_new(:status, 200)
    |> Map.put_new(:response, %{})
    |> Map.put_new(:forbidden_headers, ["authorization"])
  end

  defp verify_expectation!(expected, conn, raw) do
    unless expected.method == conn.method and expected.path == conn.request_path do
      flunk(
        "Pumble fake expected #{expected.method} #{expected.path}, got #{conn.method} #{conn.request_path}"
      )
    end

    verify_query!(expected, conn)
    verify_headers!(expected, conn)
    verify_body!(expected, raw)
    :ok
  end

  defp verify_query!(expected, conn) do
    case Map.get(expected, :query) do
      nil ->
        :ok

      expected_query when is_map(expected_query) ->
        assert URI.decode_query(conn.query_string) == expected_query

      expected_query when is_binary(expected_query) ->
        assert conn.query_string == expected_query
    end
  end

  defp verify_headers!(expected, conn) do
    headers = Map.new(conn.req_headers)

    Enum.each(Map.get(expected, :headers, %{}), fn {name, value} ->
      assert headers[name] == value,
             "header #{inspect(name)}: expected #{inspect(value)}, got #{inspect(headers[name])}"
    end)

    Enum.each(Map.get(expected, :required_headers, []), fn name ->
      assert Map.has_key?(headers, name), "missing required header #{inspect(name)}"
    end)

    Enum.each(Map.get(expected, :forbidden_headers, []), fn name ->
      refute Map.has_key?(headers, name), "forbidden header #{inspect(name)} was sent"
    end)
  end

  defp verify_body!(expected, raw) do
    cond do
      Map.has_key?(expected, :raw_body) ->
        assert raw == expected.raw_body

      Map.has_key?(expected, :json_body) ->
        assert Jason.decode!(raw) == expected.json_body

      true ->
        :ok
    end
  end

  defp emit_expected(%{response: :timeout}, conn) do
    Req.Test.transport_error(conn, :timeout)
  end

  defp emit_expected(%{response: :malformed}, conn) do
    Plug.Conn.send_resp(conn, 200, "<html>maintenance</html>")
  end

  defp emit_expected(%{response: :oversized}, conn) do
    Plug.Conn.send_resp(conn, 200, String.duplicate("x", Transport.max_response_bytes() * 2))
  end

  defp emit_expected(%{response: :rate_limited}, conn) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "2")
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(429, ~s({"message":"slow down"}))
  end

  defp emit_expected(%{status: status, response: {:raw, text}}, conn) do
    Plug.Conn.send_resp(conn, status, text)
  end

  defp emit_expected(%{status: status, response: body}, conn) when is_map(body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp respond(nil, conn) do
    Plug.Conn.send_resp(conn, 599, "no stub route for #{conn.method} #{conn.request_path}")
  end

  defp respond({_method, _path, status, {:raw, text}}, conn) do
    Plug.Conn.send_resp(conn, status, text)
  end

  defp respond({_method, _path, status, body}, conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp stub(fun), do: Req.Test.stub(@client, fun)
end
