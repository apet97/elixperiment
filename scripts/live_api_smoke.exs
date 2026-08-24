defmodule PumbleAutomation.LiveApiSmoke do
  @moduledoc false

  @base_url "https://pumble-api-keys.addons.marketplace.cake.com"
  @contract_path "/api-docs/"
  @reviewed_contract_sha256 "85c42e355ed662ba6b1436b9c9c0e19b4bf045036e77c5d7c10622d943e54e48"
  @api_key_env "SAC_WS_API_KEY"
  @workspace_sha256 "51e6c88805f5683b953c318954f6626c0ed574c94ec3a984adcfb2baf76e6d98"
  @api_request_cap 4
  @contract_request_cap 1
  @total_request_cap @api_request_cap + @contract_request_cap
  @connect_timeout 3_000
  @receive_timeout 5_000
  @request_timeout 7_000
  @supported_command "mix run --no-start --no-compile --no-deps-check --no-listeners scripts/live_api_smoke.exs --preflight-only"
  @forbidden_started_apps [:pumble_automation, :ecto_sql, :postgrex, :oban, :phoenix, :bandit]
  @script_path __ENV__.file
  @repo_root Path.expand("..", Path.dirname(@script_path))

  @operation_keys [
    :minimal_runtime_ready,
    :contract_bound,
    :identity_read,
    :workspace_bound,
    :channel_listed,
    :channel_bound,
    :message_list_shape_read,
    :message_search_shape_read
  ]

  def main(args) do
    {receipt, exit_status} = execute(args, &System.get_env/1, &http_request/1, provenance())

    IO.puts(Jason.encode!(receipt))
    System.halt(exit_status)
  end

  @doc false
  def execute(args, getenv, transport, metadata)
      when is_list(args) and is_function(getenv, 1) and is_function(transport, 1) and
             is_map(metadata) do
    execute(
      args,
      getenv,
      transport,
      metadata,
      &started_application_names/0,
      &start_req/0
    )
  end

  @doc false
  def execute(args, getenv, transport, metadata, started_apps, starter)
      when is_list(args) and is_function(getenv, 1) and is_function(transport, 1) and
             is_map(metadata) and is_function(started_apps, 0) and is_function(starter, 0) do
    state = initial_state(metadata)

    case parse_args(args) do
      :ok -> execute_preflight(state, getenv, transport, started_apps, starter)
      {:error, reason} -> finish(state, :blocked, reason)
    end
  end

  defp execute_preflight(state, getenv, transport, started_apps, starter) do
    with :ok <- exact_candidate_allowed(state),
         {:ok, state} <- prepare_runtime(state, started_apps, starter),
         {:ok, state} <- verify_runtime_contract(state, transport),
         {:ok, state} <- load_environment(state, getenv),
         {:ok, state} <- bind_identity(state, transport),
         {:ok, state} <- bind_channel(state, transport),
         {:ok, state} <- read_message_list(state, transport),
         {:ok, state} <- read_message_search(state, transport) do
      finish(state, :passed, :preflight_complete)
    else
      {:error, reason} -> finish(state, :blocked, reason)
      {:error, reason, failed_state} -> finish(failed_state, :blocked, reason)
    end
  end

  defp initial_state(metadata) do
    %{
      api_key: nil,
      workspace_id: nil,
      user_id: nil,
      channel_id: nil,
      request_count: 0,
      contract_request_count: 0,
      operations: Map.new(@operation_keys, &{&1, false}),
      read_counts: %{channels_seen: 0, messages_seen: 0, search_matches: 0},
      reviewed_contract_sha256: reviewed_contract_sha256(metadata),
      expected_workspace_sha256: expected_workspace_sha256(metadata),
      observed_contract_sha256: "not_checked",
      contract_hash_bound: false,
      candidate_commit: Map.get(metadata, :candidate_commit, "unavailable"),
      script_sha256: Map.get(metadata, :script_sha256, "unavailable"),
      head_script_sha256: Map.get(metadata, :head_script_sha256, "unavailable"),
      worktree_clean: Map.get(metadata, :worktree_clean, false)
    }
  end

  defp parse_args(["--preflight-only"]), do: :ok
  defp parse_args(_args), do: {:error, :invalid_arguments}

  defp exact_candidate_allowed(state) do
    if exact_candidate?(state), do: :ok, else: {:error, :exact_candidate_required}
  end

  defp prepare_runtime(state, started_apps, starter) do
    with {:ok, before_start} <- safe_started_apps(started_apps),
         false <- forbidden_started?(before_start),
         :ok <- safe_start(starter),
         {:ok, after_start} <- safe_started_apps(started_apps),
         false <- forbidden_started?(after_start) do
      {:ok, operation(state, :minimal_runtime_ready)}
    else
      true -> {:error, :host_application_started, state}
      _other -> {:error, :runtime_start_failed, state}
    end
  end

  defp safe_started_apps(started_apps) do
    case started_apps.() do
      names when is_list(names) -> {:ok, names}
      _other -> {:error, :invalid_started_applications}
    end
  rescue
    _error -> {:error, :started_applications_unavailable}
  catch
    _kind, _value -> {:error, :started_applications_unavailable}
  end

  defp safe_start(starter) do
    case starter.() do
      :ok -> :ok
      _other -> {:error, :runtime_start_failed}
    end
  rescue
    _error -> {:error, :runtime_start_failed}
  catch
    _kind, _value -> {:error, :runtime_start_failed}
  end

  defp started_application_names do
    Application.started_applications() |> Enum.map(&elem(&1, 0))
  end

  defp forbidden_started?(started_apps) do
    Enum.any?(@forbidden_started_apps, &(&1 in started_apps))
  end

  defp start_req do
    case Application.ensure_all_started(:req, :temporary) do
      {:ok, _started} -> :ok
      {:error, _reason} -> {:error, :runtime_start_failed}
    end
  end

  defp verify_runtime_contract(state, transport) do
    case call_contract(state, transport, contract_request_spec()) do
      {:ok, 200, body, next_state} when is_binary(body) ->
        observed = sha256_bytes(body)

        next_state = %{
          next_state
          | observed_contract_sha256: observed,
            contract_hash_bound: observed == next_state.reviewed_contract_sha256
        }

        if next_state.contract_hash_bound do
          {:ok, operation(next_state, :contract_bound)}
        else
          {:error, :contract_drift, next_state}
        end

      {:ok, _status, _body, next_state} ->
        {:error, :contract_unavailable, next_state}

      {:error, _reason, next_state} ->
        {:error, :contract_unavailable, next_state}
    end
  end

  defp load_environment(state, getenv) do
    api_key = safe_getenv(getenv, @api_key_env)

    if present?(api_key) do
      {:ok, %{state | api_key: api_key}}
    else
      {:error, :credential_missing, state}
    end
  end

  defp bind_identity(state, transport) do
    request = api_request_spec(state, :get, "/myInfo")

    case read_200(state, transport, request, :identity_read_failed) do
      {:ok, body, next_state} -> bind_workspace(body, next_state)
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp bind_workspace(body, state) do
    case identity(body) do
      {:ok, identity} ->
        state = operation(state, :identity_read)

        if sha256_bytes(identity.workspace_id) == state.expected_workspace_sha256 do
          {:ok,
           state
           |> Map.put(:workspace_id, identity.workspace_id)
           |> Map.put(:user_id, identity.user_id)
           |> operation(:workspace_bound)}
        else
          {:error, :workspace_binding, state}
        end

      {:error, _reason} ->
        {:error, :identity_read_failed, state}
    end
  end

  defp identity(body) do
    with {:ok, map} <- decode_map(body),
         user_id when is_binary(user_id) <- Map.get(map, "id"),
         true <- present?(user_id),
         workspace_id when is_binary(workspace_id) <- Map.get(map, "workspaceId"),
         true <- present?(workspace_id),
         role when role in ["OWNER", "ADMIN", "MEMBER", "GUEST"] <- Map.get(map, "role"),
         "ACTIVATED" <- Map.get(map, "status"),
         false <- Map.get(map, "isAddonBot"),
         false <- Map.get(map, "isPumbleBot") do
      {:ok, %{user_id: user_id, workspace_id: workspace_id}}
    else
      _other -> {:error, :invalid_identity}
    end
  end

  defp bind_channel(state, transport) do
    request = api_request_spec(state, :get, "/listChannels")

    case read_200(state, transport, request, :channel_read_failed) do
      {:ok, body, next_state} -> bind_channel_response(body, next_state)
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp bind_channel_response(body, state) do
    case decode_channel_entries(body) do
      {:ok, entries} ->
        state =
          state
          |> put_in([:read_counts, :channels_seen], length(entries))
          |> operation(:channel_listed)

        case select_channel(entries, state) do
          {:ok, channel_id} ->
            {:ok,
             state
             |> Map.put(:channel_id, channel_id)
             |> operation(:channel_bound)}

          {:error, _reason} ->
            {:error, :channel_binding, state}
        end

      {:error, _reason} ->
        {:error, :channel_shape_failed, state}
    end
  end

  defp decode_channel_entries(body) do
    case decode_list(body) do
      {:ok, entries} ->
        if Enum.all?(entries, &channel_entry_shape?/1) do
          {:ok, entries}
        else
          {:error, :invalid_channel_entry}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp channel_entry_shape?(%{
         "channel" => channel,
         "pinnedMessages" => pinned_messages,
         "users" => users
       }) do
    is_map(channel) and is_list(pinned_messages) and is_list(users)
  end

  defp channel_entry_shape?(_entry), do: false

  defp select_channel(entries, state) do
    eligible_ids =
      Enum.reduce(entries, [], fn entry, ids ->
        case eligible_channel_id(entry, state) do
          {:ok, channel_id} -> [channel_id | ids]
          {:error, _reason} -> ids
        end
      end)

    case eligible_ids do
      [channel_id] -> {:ok, channel_id}
      _other -> {:error, :channel_not_unique}
    end
  end

  defp eligible_channel_id(%{"channel" => channel, "users" => users}, state) do
    channel_id = Map.get(channel, "id")

    allowed? =
      Enum.all?([
        present?(channel_id),
        Map.get(channel, "workspaceId") == state.workspace_id,
        Map.get(channel, "channelType") == "PUBLIC",
        Map.get(channel, "isArchived") == false,
        Map.get(channel, "isHidden") == false,
        Map.get(channel, "isMain") == false,
        Map.get(channel, "isInitial") == false,
        Map.get(channel, "isMember") == true,
        is_list(users) and state.user_id in users,
        sacrificial_name?(Map.get(channel, "name"))
      ])

    if allowed?, do: {:ok, channel_id}, else: {:error, :ineligible_channel}
  end

  defp eligible_channel_id(_entry, _state), do: {:error, :ineligible_channel}

  defp sacrificial_name?(name) when is_binary(name) do
    Regex.match?(~r/(?:^|[-_])(test|sandbox|automation)(?:$|[-_])/, String.downcase(name))
  end

  defp sacrificial_name?(_name), do: false

  defp read_message_list(state, transport) do
    request =
      state
      |> api_request_spec(:get, "/listMessages")
      |> Map.put(:params, %{"channelId" => state.channel_id, "limit" => 1})

    case read_200(state, transport, request, :message_list_read_failed) do
      {:ok, body, next_state} -> validate_message_list(body, next_state)
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp validate_message_list(body, state) do
    with {:ok, map} <- decode_map(body),
         messages when is_list(messages) <- Map.get(map, "messages"),
         has_more_after when is_boolean(has_more_after) <- Map.get(map, "hasMoreAfter"),
         has_more_before when is_boolean(has_more_before) <- Map.get(map, "hasMoreBefore"),
         true <- length(messages) <= 1,
         true <- Enum.all?(messages, &is_map/1) do
      {:ok,
       state
       |> put_in([:read_counts, :messages_seen], length(messages))
       |> operation(:message_list_shape_read)}
    else
      _other -> {:error, :message_list_shape_failed, state}
    end
  end

  defp read_message_search(state, transport) do
    marker =
      "phoenix-live-api-preflight-" <>
        Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    request =
      state
      |> api_request_spec(:post, "/searchMessages")
      |> Map.put(:json, %{"text" => marker, "in" => [state.channel_id]})

    case read_200(state, transport, request, :message_search_read_failed) do
      {:ok, body, next_state} -> validate_message_search(body, next_state)
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp validate_message_search(body, state) do
    with {:ok, map} <- decode_map(body),
         messages when is_list(messages) <- Map.get(map, "content"),
         has_more when is_boolean(has_more) <- Map.get(map, "hasMore"),
         total_elements when is_integer(total_elements) and total_elements >= 0 <-
           Map.get(map, "totalElements"),
         true <- Enum.all?(messages, &is_map/1) do
      if messages == [] and has_more == false and total_elements == 0 do
        {:ok,
         state
         |> put_in([:read_counts, :search_matches], 0)
         |> operation(:message_search_shape_read)}
      else
        failed_state =
          put_in(state, [:read_counts, :search_matches], max(length(messages), total_elements))

        {:error, :message_search_not_empty, failed_state}
      end
    else
      _other -> {:error, :message_search_shape_failed, state}
    end
  end

  defp read_200(state, transport, request, failure_reason) do
    case call_api(state, transport, request) do
      {:ok, 200, body, next_state} -> {:ok, body, next_state}
      {:ok, _status, _body, next_state} -> {:error, failure_reason, next_state}
      {:error, _reason, next_state} -> {:error, failure_reason, next_state}
    end
  end

  defp call_api(state, transport, request),
    do: capped_call(state, transport, request, :request_count, @api_request_cap)

  defp call_contract(state, transport, request),
    do:
      capped_call(
        state,
        transport,
        request,
        :contract_request_count,
        @contract_request_cap
      )

  defp capped_call(state, transport, request, count_key, cap) do
    if Map.fetch!(state, count_key) >= cap do
      {:error, :request_cap, state}
    else
      next_state = Map.update!(state, count_key, &(&1 + 1))
      dispatch(transport, request, next_state)
    end
  end

  defp dispatch(transport, request, state) do
    case safe_transport(transport, request) do
      {:ok, %{status: status, body: body}} when is_integer(status) ->
        {:ok, status, body, state}

      {:error, _reason} ->
        {:error, :transport, state}
    end
  end

  defp safe_transport(transport, request) do
    case transport.(request) do
      {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, _reason} -> {:error, :transport}
      _other -> {:error, :transport}
    end
  rescue
    _error -> {:error, :transport}
  catch
    _kind, _value -> {:error, :transport}
  end

  defp contract_request_spec do
    %{
      method: :get,
      path: @contract_path,
      params: %{},
      json: nil,
      headers: [{"accept", "text/html"}]
    }
  end

  defp api_request_spec(state, method, path) do
    %{
      method: method,
      path: path,
      params: %{},
      json: nil,
      headers: [{"ApiKey", state.api_key}, {"accept", "application/json"}]
    }
  end

  defp http_request(request) do
    options = [
      method: request.method,
      url: @base_url <> request.path,
      headers: request.headers,
      params: request.params,
      retry: false,
      redirect: false,
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout,
      request_timeout: @request_timeout
    ]

    options = if request.json == nil, do: options, else: Keyword.put(options, :json, request.json)

    case Req.request(options) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _error} -> {:error, :transport}
    end
  rescue
    _error -> {:error, :transport}
  catch
    _kind, _value -> {:error, :transport}
  end

  defp decode_map(body) when is_map(body), do: {:ok, body}

  defp decode_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _other -> {:error, :invalid_body}
    end
  end

  defp decode_map(_body), do: {:error, :invalid_body}

  defp decode_list(body) when is_list(body), do: {:ok, body}

  defp decode_list(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _other -> {:error, :invalid_body}
    end
  end

  defp decode_list(_body), do: {:error, :invalid_body}

  defp operation(state, key), do: put_in(state, [:operations, key], true)

  defp exact_candidate?(state) do
    state.worktree_clean == true and
      hex_string?(state.candidate_commit, 40) and
      hex_string?(state.head_script_sha256, 64) and
      exact_script?(state)
  end

  defp finish(state, outcome, reason) do
    receipt = %{
      schema_version: 4,
      command: @supported_command,
      read_only: true,
      candidate_commit: state.candidate_commit,
      script_sha256: state.script_sha256,
      recorded_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      outcome: Atom.to_string(outcome),
      reason: Atom.to_string(reason),
      request_count: state.request_count,
      contract_request_count: state.contract_request_count,
      total_request_count: state.request_count + state.contract_request_count,
      hard_request_cap: @api_request_cap,
      hard_contract_request_cap: @contract_request_cap,
      hard_total_request_cap: @total_request_cap,
      operations: state.operations,
      read_counts: state.read_counts,
      contract: %{
        reviewed_sha256: state.reviewed_contract_sha256,
        observed_sha256: state.observed_contract_sha256,
        exact_match: state.contract_hash_bound
      },
      proof_boundaries: %{
        exact_candidate_bound: exact_candidate?(state),
        exact_script_bound: exact_script?(state),
        clean_worktree_bound: state.worktree_clean == true,
        public_contract_hash_bound: state.contract_hash_bound,
        fixed_api_key_host_only: true,
        sacrificial_workspace_bound: state.operations.workspace_bound,
        sacrificial_channel_bound: state.operations.channel_bound,
        message_list_shape_proven: state.operations.message_list_shape_read,
        message_search_shape_proven: state.operations.message_search_shape_read,
        oauth_proven: false,
        callback_delivery_proven: false,
        deployment_proven: false,
        marketplace_release_proven: false
      }
    }

    exit_status = if outcome == :passed, do: 0, else: 2
    {receipt, exit_status}
  end

  defp provenance do
    commit_before = git_commit()
    script_sha256 = sha256_file(@script_path)
    head_script_sha256 = head_script_sha256()
    clean? = worktree_clean?()
    commit_after = git_commit()
    stable_head? = commit_before == commit_after and hex_string?(commit_before, 40)

    %{
      candidate_commit: if(stable_head?, do: commit_before, else: "unavailable"),
      script_sha256: script_sha256,
      head_script_sha256: head_script_sha256,
      worktree_clean: clean? and stable_head?
    }
  end

  defp reviewed_contract_sha256(metadata) do
    candidate = Map.get(metadata, :reviewed_contract_sha256)

    if Mix.env() == :test and hex_string?(candidate, 64) do
      candidate
    else
      @reviewed_contract_sha256
    end
  end

  defp expected_workspace_sha256(metadata) do
    candidate = Map.get(metadata, :expected_workspace_sha256)

    if Mix.env() == :test and hex_string?(candidate, 64) do
      candidate
    else
      @workspace_sha256
    end
  end

  defp git_commit do
    case git_command(["rev-parse", "--verify", "HEAD"]) do
      {commit, 0} ->
        commit = String.trim(commit)
        if hex_string?(commit, 40), do: commit, else: "unavailable"

      _other ->
        "unavailable"
    end
  end

  defp head_script_sha256 do
    case git_command(["show", "HEAD:scripts/live_api_smoke.exs"]) do
      {bytes, 0} -> sha256_bytes(bytes)
      _other -> "unavailable"
    end
  end

  defp worktree_clean? do
    case git_command(["status", "--porcelain=v1", "--untracked-files=all"]) do
      {"", 0} -> true
      {_output, 0} -> false
      _other -> false
    end
  end

  defp git_command(arguments) do
    System.cmd("git", ["-C", @repo_root | arguments],
      stderr_to_stdout: true,
      env: [{@api_key_env, nil}]
    )
  rescue
    _error -> {"", 1}
  end

  defp sha256_file(path) do
    case File.read(path) do
      {:ok, bytes} -> sha256_bytes(bytes)
      {:error, _reason} -> "unavailable"
    end
  end

  defp sha256_bytes(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp hex_string?(value, length) when is_binary(value) and byte_size(value) == length,
    do: Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp hex_string?(_value, _length), do: false

  defp safe_getenv(getenv, name) do
    getenv.(name)
  rescue
    _error -> nil
  catch
    _kind, _value -> nil
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false

  defp exact_script?(state) do
    hex_string?(state.script_sha256, 64) and state.script_sha256 == state.head_script_sha256
  end
end

if Mix.env() != :test do
  PumbleAutomation.LiveApiSmoke.main(System.argv())
end
