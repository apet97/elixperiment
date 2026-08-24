Code.require_file(Path.expand("../../scripts/live_api_smoke.exs", __DIR__))

defmodule PumbleAutomation.Verification.LiveApiSmokeTest do
  use ExUnit.Case, async: true

  alias PumbleAutomation.LiveApiSmoke

  @contract_body "<html>reviewed test contract</html>"
  @contract_sha :crypto.hash(:sha256, @contract_body) |> Base.encode16(case: :lower)
  @workspace_id "fixture-workspace-id"
  @workspace_sha :crypto.hash(:sha256, @workspace_id) |> Base.encode16(case: :lower)
  @command "mix run --no-start --no-compile --no-deps-check --no-listeners scripts/live_api_smoke.exs --preflight-only"
  @forbidden_apps [:pumble_automation, :ecto_sql, :postgrex, :oban, :phoenix, :bandit]
  @metadata %{
    candidate_commit: String.duplicate("a", 40),
    script_sha256: String.duplicate("b", 64),
    head_script_sha256: String.duplicate("b", 64),
    worktree_clean: true,
    reviewed_contract_sha256: @contract_sha,
    expected_workspace_sha256: @workspace_sha
  }

  test "preflight binds the contract, candidate, workspace, and sacrificial channel" do
    secret = "offline-only-api-key"
    fake = start_fake()
    {receipt, 0} = run(fake, secret)
    state = Agent.get(fake, & &1)
    calls = Enum.reverse(state.calls)
    encoded = Jason.encode!(receipt)

    assert receipt.outcome == "passed"
    assert receipt.reason == "preflight_complete"
    assert receipt.command == @command
    assert receipt.read_only
    assert receipt.request_count == 4
    assert receipt.contract_request_count == 1
    assert receipt.total_request_count == 5
    assert {receipt.hard_request_cap, receipt.hard_contract_request_cap} == {4, 1}
    assert receipt.hard_total_request_cap == 5
    assert Enum.all?(receipt.operations, fn {_name, complete?} -> complete? end)
    assert receipt.read_counts == %{channels_seen: 1, messages_seen: 0, search_matches: 0}
    assert receipt.contract.exact_match
    assert receipt.contract.reviewed_sha256 == @contract_sha
    assert receipt.contract.observed_sha256 == @contract_sha

    proven = [
      :exact_candidate_bound,
      :exact_script_bound,
      :clean_worktree_bound,
      :public_contract_hash_bound,
      :fixed_api_key_host_only,
      :sacrificial_workspace_bound,
      :sacrificial_channel_bound,
      :message_list_shape_proven,
      :message_search_shape_proven
    ]

    assert Enum.all?(proven, &Map.fetch!(receipt.proof_boundaries, &1))

    assert Enum.map(calls, & &1.path) == [
             "/api-docs/",
             "/myInfo",
             "/listChannels",
             "/listMessages",
             "/searchMessages"
           ]

    [contract_call | api_calls] = calls
    refute has_key?(contract_call, secret)
    assert contract_call.headers == [{"accept", "text/html"}]
    assert Enum.all?(api_calls, &has_key?(&1, secret))

    list_call = Enum.find(calls, &(&1.path == "/listMessages"))
    search_call = Enum.find(calls, &(&1.path == "/searchMessages"))
    assert list_call.params == %{"channelId" => state.channel_id, "limit" => 1}
    assert Map.keys(search_call.json) |> Enum.sort() == ["in", "text"]
    assert search_call.json["in"] == [state.channel_id]
    assert String.starts_with?(state.search_text, "phoenix-live-api-preflight-")

    for forbidden <- [
          secret,
          state.workspace_id,
          state.user_id,
          state.channel_id,
          state.channel_name,
          state.search_text,
          "private-user@example.invalid"
        ] do
      refute encoded =~ forbidden
    end
  end

  test "invalid arguments fail before every request" do
    parent = self()
    transport = fn request -> send(parent, {:unexpected, request.path}) end

    for args <- [[], ["--unknown"], ["--preflight-only", "extra"]] do
      {receipt, 2} = LiveApiSmoke.execute(args, env("key"), transport, @metadata)
      assert receipt.reason == "invalid_arguments"
      assert receipt.total_request_count == 0
    end

    refute_receive {:unexpected, _path}
  end

  test "dirty or non-HEAD candidates fail before every request" do
    parent = self()
    transport = fn request -> send(parent, {:unexpected, request.path}) end

    for metadata <- [
          %{@metadata | worktree_clean: false},
          %{@metadata | head_script_sha256: String.duplicate("c", 64)}
        ] do
      {receipt, 2} =
        LiveApiSmoke.execute(["--preflight-only"], env("key"), transport, metadata)

      assert receipt.reason == "exact_candidate_required"
      assert receipt.total_request_count == 0
      refute receipt.proof_boundaries.exact_candidate_bound
    end

    refute_receive {:unexpected, _path}
  end

  test "the minimal runtime starts Req only after it confirms that the host app is absent" do
    parent = self()
    fake = start_fake()

    started_apps = fn ->
      send(parent, :checked_started_applications)
      []
    end

    starter = fn ->
      send(parent, :started_req)
      :ok
    end

    {receipt, 0} =
      LiveApiSmoke.execute(
        ["--preflight-only"],
        env("key"),
        fake_transport(fake),
        @metadata,
        started_apps,
        starter
      )

    assert receipt.operations.minimal_runtime_ready
    assert_receive :checked_started_applications
    assert_receive :started_req
    assert_receive :checked_started_applications
  end

  test "every forbidden application blocks before HTTP when present before or after Req start" do
    parent = self()
    transport = fn request -> send(parent, {:unexpected_request, request.path}) end

    for app <- @forbidden_apps, position <- [:before_start, :after_start] do
      {receipt, 2} =
        LiveApiSmoke.execute(
          ["--preflight-only"],
          env("key"),
          transport,
          @metadata,
          started_apps_provider(app, position),
          fn -> :ok end
        )

      assert receipt.reason == "host_application_started"
      assert receipt.request_count == 0
      assert receipt.contract_request_count == 0
      refute receipt.operations.minimal_runtime_ready
    end

    refute_receive {:unexpected_request, _path}
  end

  test "contract drift blocks before an API-key request" do
    secret = "offline-only-api-key"
    fake = start_fake(contract_body: "<html>changed contract</html>")
    {receipt, 2} = run(fake, secret)
    [contract_call] = fake |> Agent.get(& &1.calls) |> Enum.reverse()

    assert receipt.reason == "contract_drift"
    assert receipt.request_count == 0
    assert receipt.contract_request_count == 1
    refute receipt.contract.exact_match
    refute receipt.proof_boundaries.public_contract_hash_bound
    refute has_key?(contract_call, secret)
    refute Jason.encode!(receipt) =~ secret
  end

  test "the API key is required only after the public contract check" do
    fake = start_fake()
    {receipt, 2} = run(fake, nil)
    [contract_call] = fake |> Agent.get(& &1.calls) |> Enum.reverse()

    assert receipt.reason == "credential_missing"
    assert receipt.request_count == 0
    assert receipt.contract_request_count == 1
    refute Enum.any?(contract_call.headers, fn {name, _value} -> name == "ApiKey" end)
  end

  test "the pinned sacrificial workspace cannot be replaced by an environment value" do
    fake = start_fake(workspace_id: "different-workspace")
    {receipt, 2} = run(fake, "key", canonical_override: "different-workspace")

    assert receipt.reason == "workspace_binding"
    assert receipt.request_count == 1
    assert receipt.operations.identity_read
    refute receipt.operations.workspace_bound
    refute receipt.operations.channel_listed
    refute source() =~ "SAC_WS_CANONICAL_ID"
  end

  test "an environment channel ID cannot bypass the sacrificial channel-name rule" do
    fake = start_fake(channel_name: "general")
    {receipt, 2} = run(fake, "key", channel_id: "raw-channel-id")

    assert receipt.reason == "channel_binding"
    assert receipt.request_count == 2
    assert receipt.operations.channel_listed
    refute receipt.operations.channel_bound
    refute source() =~ "SAC_CHANNEL_ID"
  end

  test "channel and live-observed message response shapes are required" do
    cases = [
      {[channels_body: %{"channels" => []}], "channel_shape_failed", 2},
      {[list_body: []], "message_list_shape_failed", 3},
      {[
         list_body: %{"messages" => [], "hasMoreBefore" => false}
       ], "message_list_shape_failed", 3},
      {[search_body: []], "message_search_shape_failed", 4},
      {[
         search_body: %{"content" => [], "hasMore" => false}
       ], "message_search_shape_failed", 4}
    ]

    for {options, reason, request_count} <- cases do
      fake = start_fake(options)
      {receipt, 2} = run(fake, "key")
      assert receipt.reason == reason
      assert receipt.request_count == request_count
      assert receipt.contract_request_count == 1
    end
  end

  test "message bounds and a nonempty search result block the preflight" do
    raw_message_id = "raw-message-id-that-must-never-appear"
    raw_message_text = "raw-message-text-that-must-never-appear"

    fake =
      start_fake(
        list_body: %{
          "messages" => [%{}, %{}],
          "hasMoreAfter" => false,
          "hasMoreBefore" => false
        }
      )

    {receipt, 2} = run(fake, "key")
    assert receipt.reason == "message_list_shape_failed"
    assert receipt.request_count == 3

    fake =
      start_fake(
        search_body: %{
          "content" => [%{"id" => raw_message_id, "text" => raw_message_text}],
          "hasMore" => false,
          "totalElements" => 1
        }
      )

    {receipt, 2} = run(fake, "key")
    assert receipt.reason == "message_search_not_empty"
    assert receipt.request_count == 4
    assert receipt.read_counts.search_matches == 1

    encoded = Jason.encode!(receipt)
    refute encoded =~ raw_message_id
    refute encoded =~ raw_message_text
  end

  test "transport errors cannot put secret or provider data in the receipt" do
    secret = "secret-that-must-never-appear"
    raw_id = "raw-provider-id-that-must-never-appear"
    email = "private-user@example.invalid"

    transport = fn request ->
      case request.path do
        "/api-docs/" -> {:ok, %{status: 200, body: @contract_body}}
        _api_path -> raise "#{secret} #{raw_id} #{email} raw response body"
      end
    end

    {receipt, 2} =
      LiveApiSmoke.execute(
        ["--preflight-only"],
        env(secret, canonical_override: raw_id),
        transport,
        @metadata,
        fn -> [] end,
        fn -> :ok end
      )

    encoded = Jason.encode!(receipt)
    assert receipt.reason == "identity_read_failed"
    assert {receipt.request_count, receipt.contract_request_count} == {1, 1}

    for forbidden <- [secret, raw_id, email, "raw response body"] do
      refute encoded =~ forbidden
    end
  end

  test "the source has one fixed host and no write implementation" do
    source = source()

    assert source =~ "https://pumble-api-keys.addons.marketplace.cake.com"
    assert source =~ "85c42e355ed662ba6b1436b9c9c0e19b4bf045036e77c5d7c10622d943e54e48"
    assert source =~ "@api_request_cap 4"
    assert source =~ "@contract_request_cap 1"
    assert source =~ @command
    assert source =~ "Application.started_applications()"
    assert source =~ "Application.ensure_all_started(:req, :temporary)"
    assert source =~ "{\"ApiKey\", state.api_key}"
    assert source =~ "retry: false"
    assert source =~ "redirect: false"

    for forbidden <- [
          "/sendMessage",
          "/sendReply",
          "/addReaction",
          "/removeReaction",
          "/deleteMessage",
          "PUMBLE_API_KEY",
          "base_url_env",
          "cleanup",
          "mutation"
        ] do
      refute source =~ forbidden
    end

    refute source =~ "Application.ensure_all_started(:pumble_automation"

    for app <- @forbidden_apps do
      assert source =~ inspect(app)
    end
  end

  test "the contract note states the read-only implementation boundary" do
    note = File.read!(Path.expand("../../docs/evidence/pumble_api_key_live_contract.md", __DIR__))

    assert note =~ "https://pumble-api-keys.addons.marketplace.cake.com/api-docs/"
    assert note =~ "85c42e355ed662ba6b1436b9c9c0e19b4bf045036e77c5d7c10622d943e54e48"
    assert note =~ "does not implement write operations"
    assert note =~ "live-observed pagination"

    assert note =~
             "This document does not\nclaim that the public examples and the live runtime agree."

    assert note =~ "API key is not OAuth application credentials"
  end

  test "all operator documentation uses only the isolated Mix command" do
    paths = [
      "../../README.md",
      "../../docs/engineering/verification.md",
      "../../docs/evidence/pumble_api_key_live_contract.md"
    ]

    for path <- paths do
      text = File.read!(Path.expand(path, __DIR__))
      assert text =~ @command
      assert text =~ "Do not use the default `mix run` command."
      refute text =~ "mix run scripts/live_api_smoke.exs --preflight-only"
    end
  end

  defp source, do: File.read!(Path.expand("../../scripts/live_api_smoke.exs", __DIR__))

  defp run(fake, api_key, options \\ []) do
    LiveApiSmoke.execute(
      ["--preflight-only"],
      env(api_key, options),
      fake_transport(fake),
      @metadata,
      fn -> [] end,
      fn -> :ok end
    )
  end

  defp env(api_key, options \\ []) do
    channel_id = Keyword.get(options, :channel_id)
    canonical_override = Keyword.get(options, :canonical_override)

    fn
      "SAC_WS_API_KEY" -> api_key
      "SAC_CHANNEL_ID" -> channel_id
      "SAC_WS_CANONICAL_ID" -> canonical_override
      _other -> nil
    end
  end

  defp has_key?(request, secret) do
    Enum.any?(request.headers, fn {name, value} -> name == "ApiKey" and value == secret end)
  end

  defp start_fake(options \\ []) do
    start_supervised!({Agent, fn -> fake_state(options) end}, id: make_ref())
  end

  defp started_apps_provider(app, position) do
    counter = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    fn ->
      Agent.get_and_update(counter, &next_started_apps(&1, app, position))
    end
  end

  defp next_started_apps(count, app, position) do
    next_count = count + 1

    apps =
      if {position, next_count} in [{:before_start, 1}, {:after_start, 2}], do: [app], else: []

    {apps, next_count}
  end

  defp fake_transport(fake) do
    fn request -> Agent.get_and_update(fake, &fake_response(request, &1)) end
  end

  defp fake_state(options) do
    %{
      calls: [],
      contract_body: Keyword.get(options, :contract_body, @contract_body),
      workspace_id: Keyword.get(options, :workspace_id, @workspace_id),
      user_id: "raw-user-id",
      channel_id: "raw-channel-id",
      channel_name: Keyword.get(options, :channel_name, "team-automation-test"),
      channels_body: Keyword.get(options, :channels_body, :default),
      list_body:
        Keyword.get(options, :list_body, %{
          "messages" => [],
          "hasMoreAfter" => false,
          "hasMoreBefore" => false
        }),
      search_body:
        Keyword.get(options, :search_body, %{
          "content" => [],
          "hasMore" => false,
          "totalElements" => 0
        }),
      search_text: nil
    }
  end

  defp fake_response(request, state) do
    state = %{state | calls: [request | state.calls]}

    case {request.method, request.path} do
      {:get, "/api-docs/"} ->
        reply(200, state.contract_body, state)

      {:get, "/myInfo"} ->
        reply(200, identity(state), state)

      {:get, "/listChannels"} ->
        body =
          if state.channels_body == :default,
            do: [channel_entry(state)],
            else: state.channels_body

        reply(200, body, state)

      {:get, "/listMessages"} ->
        reply(200, state.list_body, state)

      {:post, "/searchMessages"} ->
        state = %{state | search_text: request.json["text"]}
        reply(200, state.search_body, state)

      _other ->
        {{:error, :unexpected_request}, state}
    end
  end

  defp reply(status, body, state), do: {{:ok, %{status: status, body: body}}, state}

  defp identity(state) do
    %{
      "id" => state.user_id,
      "email" => "private-user@example.invalid",
      "role" => "MEMBER",
      "status" => "ACTIVATED",
      "workspaceId" => state.workspace_id,
      "isAddonBot" => false,
      "isPumbleBot" => false
    }
  end

  defp channel_entry(state) do
    %{
      "channel" => %{
        "id" => state.channel_id,
        "name" => state.channel_name,
        "channelType" => "PUBLIC",
        "workspaceId" => state.workspace_id,
        "isArchived" => false,
        "isHidden" => false,
        "isMain" => false,
        "isInitial" => false,
        "isMember" => true
      },
      "pinnedMessages" => [],
      "users" => [state.user_id]
    }
  end
end
