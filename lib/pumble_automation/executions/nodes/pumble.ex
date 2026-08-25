defmodule PumbleAutomation.Executions.Nodes.Pumble do
  @moduledoc """
  Dispatches compiled Pumble message and reaction actions.

  `send_message`, `reply_message`, `direct_message`, `add_reaction`, and
  `remove_reaction` are the v1 writers. Live calls go through
  `PumbleAutomation.Pumble.Client` with the bot token. Dry-run renders and
  validates the same payload and returns a request summary without resolving
  credentials or touching the network.

  Reaction already-present and already-absent status codes are not rewritten:
  PR-09 is still open, so the provider response is preserved. Ambiguous
  reaction network outcomes stay uncertain until that probe proves
  idempotent convergence.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Context
  alias PumbleAutomation.Executions.Nodes.PumbleAddReaction
  alias PumbleAutomation.Executions.Nodes.PumbleDm
  alias PumbleAutomation.Executions.Nodes.PumbleRemoveReaction
  alias PumbleAutomation.Executions.Nodes.PumbleReply
  alias PumbleAutomation.Executions.Nodes.PumbleSendMessage
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Pumble.Blocks
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.Pumble.Client.Error, as: ClientError
  alias PumbleAutomation.Workflows.Templates

  @telemetry_event [:pumble_automation, :executions, :pumble_action]
  @id_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @uncertain_classes [:ambiguous_transport, :side_effect_uncertain]
  @retryable_classes [:rate_limited, :transient_transport, :remote_transient]

  @client_messages %{
    validation: "The Pumble action could not be sent.",
    authentication: "The Pumble credential is no longer usable.",
    authorization: "The Pumble action is not authorized.",
    missing_scope: "The recorded install request omits a required Pumble permission.",
    installation_revoked: "This workspace is no longer authorized.",
    not_found: "The Pumble target does not exist.",
    conflict: "The Pumble target is in a conflicting state.",
    rate_limited: "Pumble asked this action to wait before retrying.",
    transient_transport: "The Pumble request did not leave this application.",
    remote_transient: "Pumble returned a temporary error.",
    remote_permanent: "Pumble rejected this action.",
    ambiguous_transport: "The Pumble write may have been delivered.",
    side_effect_uncertain: "Pumble returned an error after the write was dispatched.",
    resource_limit: "The Pumble response was too large.",
    internal_invariant: "The Pumble client refused the request."
  }

  @doc "Runs the compiled Pumble action in `input`."
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    case action(input) do
      "send_message" -> PumbleSendMessage.run(input)
      "reply_message" -> PumbleReply.run(input)
      "direct_message" -> PumbleDm.run(input)
      "add_reaction" -> PumbleAddReaction.run(input)
      "remove_reaction" -> PumbleRemoveReaction.run(input)
      _other -> unimplemented(input)
    end
  end

  @doc "The telemetry event this adapter emits before a live or dry-run send."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc "The JSON tree a Pumble action may read."
  @spec tree(map()) :: map()
  def tree(input) when is_map(input) do
    Context.tree(%{
      context: Map.get(input, :context) || %{},
      trigger_snapshot: Map.get(input, :trigger_snapshot) || %{}
    })
  end

  @doc "Renders a required text field against the resolution tree."
  @spec render_text(map(), map(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def render_text(input, tree, field) when is_binary(field) do
    case Templates.render(config(input)[field], tree) do
      {:ok, %{value: text}} when is_binary(text) -> {:ok, text}
      {:ok, %{value: _other}} -> {:error, invalid_field(field, "This field must render as text.")}
      {:error, %Error{} = error} -> {:error, with_field(error, field)}
    end
  end

  @doc """
  Resolves a Pumble identifier from the compiled field, then trigger keys.

  The compiled value wins when it renders. An absent compiled field falls
  back through `trigger_keys` on the trigger snapshot, in order.
  """
  @spec target_id(map(), map(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def target_id(input, tree, field, trigger_keys)
      when is_binary(field) and is_list(trigger_keys) do
    case compiled_id(config(input)[field], tree, field) do
      {:ok, id} -> {:ok, id}
      {:error, :missing} -> trigger_id(input, trigger_keys, field)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Builds a bounded workflow message body from rendered text and optional blocks."
  @spec payload(map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def payload(input, text) when is_binary(text) do
    case Blocks.workflow_message(text, config(input)["blocks"]) do
      {:ok, body} -> {:ok, body}
      {:error, %ClientError{} = error} -> {:error, payload_error(error)}
    end
  end

  @doc "Validates a reaction code and optional skin tone against documented limits."
  @spec reaction_payload(String.t(), integer() | nil) :: {:ok, map()} | {:error, Error.t()}
  def reaction_payload(code, skin_tone \\ nil) when is_binary(code) do
    case Blocks.reaction(code, skin_tone) do
      {:ok, body} -> {:ok, body}
      {:error, %ClientError{} = error} -> {:error, reaction_error(error)}
    end
  end

  @doc "The optional compiled skin tone, or a refusal when it is not an integer."
  @spec skin_tone(map()) :: {:ok, integer() | nil} | {:error, Error.t()}
  def skin_tone(input) when is_map(input) do
    case config(input)["skin_tone"] || config(input)["skinTone"] do
      nil -> {:ok, nil}
      tone when is_integer(tone) -> {:ok, tone}
      _other -> {:error, invalid_field("skin_tone", "A skin tone is an integer.")}
    end
  end

  @doc """
  Refuses a target whose trigger workspace is not this execution's workspace.

  The check runs only when both identities are present. A missing workspace
  id is not proof of a match, and the client is still bound to the current
  installation.
  """
  @spec same_workspace(map(), map()) :: {:ok, :same} | {:error, Error.t()}
  def same_workspace(input, tree) when is_map(input) and is_map(tree) do
    current = workspace_id(tree["workspace"])
    claimed = trigger_workspace_id(input)

    if is_binary(current) and is_binary(claimed) and current != claimed do
      {:error, invalid_field("message_id", "This target is not in the current Pumble workspace.")}
    else
      {:ok, :same}
    end
  end

  @doc "The bot credential, or a refusal when a user token is requested."
  @spec credential_kind(map()) :: {:ok, :bot} | {:error, Error.t()}
  def credential_kind(input) when is_map(input) do
    if user_token_requested?(config(input)) do
      {:error,
       Error.new(:validation, :user_token_not_allowed,
         message: "This action may only run as the workspace bot."
       )}
    else
      {:ok, :bot}
    end
  end

  @doc "Sends `fun` through the client, or returns a dry-run summary."
  @spec dispatch(map(), map(), (Client.t() -> {:ok, term()} | {:error, ClientError.t()})) ::
          {:ok, Outcome.t()} | {:error, Error.t()}
  def dispatch(input, request, fun)
      when is_map(input) and is_map(request) and is_function(fun, 1) do
    emit(input, request.operation)

    if dry_run?(input) do
      dry_run_success(input, request)
    else
      call_client(input, request, fun)
    end
  end

  @doc "A permanent validation (or other domain) failure."
  @spec permanent(Error.t(), map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def permanent(%Error{} = error, input \\ %{}) do
    Outcome.new(%{
      kind: :permanent_error,
      error_class: error_class(error),
      message: error.message,
      output: failure_output(error, input)
    })
  end

  @doc "Maps a Pumble client error onto the execution outcome kinds."
  @spec from_client(ClientError.t(), map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def from_client(%ClientError{} = error, input) when is_map(input) do
    class = client_error_class(error)

    Outcome.new(%{
      kind: client_kind(error, class),
      error_class: Atom.to_string(class),
      message: client_message(error, class),
      remote_reference: error.provider_request_id,
      output: client_output(error, input)
    })
  end

  defp unimplemented(_input) do
    Outcome.new(%{
      kind: :permanent_error,
      error_class: "internal_invariant",
      message: "The stored Pumble action is not supported."
    })
  end

  defp call_client(input, request, fun) do
    case fun.(client(input)) do
      {:ok, response} -> live_success(input, request, response)
      {:error, %ClientError{} = error} -> from_client(error, input)
    end
  end

  defp client(input) do
    Client.new(input.installation_id, :bot, correlation_id: Map.get(input, :effect_key))
  end

  defp live_success(input, request, response) do
    Outcome.new(%{
      kind: :success,
      edge: Outcome.linear(),
      remote_reference: provider_message_id(response) || request[:message_id],
      output: success_output(input, request, response, dry_run?: false)
    })
  end

  defp dry_run_success(input, request) do
    Outcome.new(%{
      kind: :success,
      edge: Outcome.linear(),
      output: success_output(input, request, %{}, dry_run?: true)
    })
  end

  defp success_output(input, request, response, opts) do
    dry_run? = Keyword.fetch!(opts, :dry_run?)

    %{}
    |> put_present("operation", operation_name(request.operation))
    |> put_present("effect_key", Map.get(input, :effect_key))
    |> put_present("as", "bot")
    |> put_present("channel_id", request[:channel_id] || provider_channel_id(response))
    |> put_present("user_id", request[:user_id])
    |> put_present("thread_root_id", request[:thread_root_id])
    |> put_present("message_id", request[:message_id] || provider_message_id(response))
    |> put_present("reaction", request[:reaction])
    |> put_present("skin_tone", request[:skin_tone])
    |> put_dry_run(request, dry_run?)
  end

  defp put_dry_run(output, request, true) do
    output
    |> Map.put("dry_run", true)
    |> put_present("text_bytes", text_bytes(request[:payload]))
    |> put_present("blocks_count", blocks_count(request[:payload]))
  end

  defp put_dry_run(output, _request, false), do: output

  defp compiled_id(nil, _tree, _field), do: {:error, :missing}
  defp compiled_id("", _tree, _field), do: {:error, :missing}

  defp compiled_id(value, tree, field) do
    case Templates.render(value, tree) do
      {:ok, %{value: rendered}} -> validate_id(rendered, field)
      {:error, %Error{code: :path_missing}} -> {:error, :missing}
      {:error, %Error{} = error} -> {:error, with_field(error, field)}
    end
  end

  defp trigger_id(input, keys, field) do
    snapshot = Map.get(input, :trigger_snapshot) || %{}

    keys
    |> Enum.find_value(fn key -> present_id(Map.get(snapshot, key)) end)
    |> case do
      nil -> {:error, missing_target(field)}
      id -> validate_id(id, field)
    end
  end

  defp present_id(id) when is_binary(id) and id != "", do: id
  defp present_id(_id), do: nil

  defp validate_id(id, field) when is_binary(id) do
    if Regex.match?(@id_pattern, id) do
      {:ok, id}
    else
      {:error, invalid_field(field, "This is not a Pumble identifier.")}
    end
  end

  defp validate_id(_id, field) do
    {:error, invalid_field(field, "This field must render as a Pumble identifier.")}
  end

  defp missing_target(field) do
    invalid_field(field, "This action has no Pumble target.")
  end

  defp invalid_field(field, message) do
    Error.new(:validation, :invalid_pumble_target,
      message: message,
      details: %{field: field}
    )
  end

  defp with_field(%Error{} = error, field) do
    %{error | details: Map.put(error.details, :field, field)}
  end

  defp payload_error(_error) do
    Error.new(:validation, :invalid_pumble_payload, message: "The Pumble message is not valid.")
  end

  defp reaction_error(%ClientError{body_summary: summary}) do
    field = if skin_tone_summary?(summary), do: "skin_tone", else: "reaction"

    Error.new(:validation, :invalid_pumble_reaction,
      message: "The Pumble reaction is not valid.",
      details: %{field: field}
    )
  end

  defp skin_tone_summary?(summary) when is_binary(summary) do
    String.contains?(summary, "skin tone")
  end

  defp skin_tone_summary?(_summary), do: false

  defp workspace_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp workspace_id(_workspace), do: nil

  defp trigger_workspace_id(input) do
    snapshot = Map.get(input, :trigger_snapshot) || %{}
    data = Map.get(snapshot, "data")

    present_id(Map.get(snapshot, "workspace_id")) ||
      present_id(is_map(data) && Map.get(data, "workspace_id"))
  end

  defp user_token_requested?(config) do
    value =
      config["as"] || config["credential"] || config["credential_kind"] || config["token_kind"]

    is_binary(value) and value not in ["", "bot"]
  end

  defp emit(input, operation) do
    attempt = Map.get(input, :attempt) || %{}

    :telemetry.execute(@telemetry_event, %{system_time: System.system_time()}, %{
      operation: operation,
      effect_key: Map.get(input, :effect_key),
      run_mode: Map.get(input, :run_mode),
      dry_run?: dry_run?(input),
      installation_id: Map.get(input, :installation_id),
      attempt_id: Map.get(attempt, :id)
    })
  end

  defp dry_run?(%{run_mode: "dry_run"}), do: true
  defp dry_run?(_input), do: false

  defp action(input), do: config(input)["action"]
  defp config(%{compiled_node: %{config: config}}) when is_map(config), do: config
  defp config(_input), do: %{}

  defp client_kind(_error, class) when class in @uncertain_classes, do: :uncertain
  defp client_kind(_error, class) when class in @retryable_classes, do: :retryable_error
  defp client_kind(_error, _class), do: :permanent_error

  defp client_error_class(%ClientError{} = error) do
    cond do
      reaction_ambiguous_status?(error) -> :side_effect_uncertain
      reaction_ambiguous_transport?(error) -> :ambiguous_transport
      true -> error.class
    end
  end

  defp reaction_ambiguous_status?(%ClientError{operation: operation, status: status})
       when operation in [:add_reaction, :remove_reaction] and is_integer(status) do
    status >= 500
  end

  defp reaction_ambiguous_status?(_error), do: false

  defp reaction_ambiguous_transport?(%ClientError{
         operation: operation,
         class: :transient_transport,
         body_summary: summary
       })
       when operation in [:add_reaction, :remove_reaction] do
    ambiguous_transport_summary?(summary)
  end

  defp reaction_ambiguous_transport?(_error), do: false

  defp ambiguous_transport_summary?(summary) when is_binary(summary) do
    String.contains?(summary, ":timeout") or String.contains?(summary, ":closed")
  end

  defp ambiguous_transport_summary?(_summary), do: false

  defp client_message(%ClientError{status: 403}, class)
       when class in [:authorization, :missing_scope] do
    "Pumble refused this action. Review the app permissions before starting a new run."
  end

  defp client_message(_error, class) do
    Map.get(@client_messages, class, "The Pumble action failed.")
  end

  defp client_output(%ClientError{} = error, input) do
    %{}
    |> put_present("effect_key", Map.get(input, :effect_key))
    |> put_present("operation", operation_name(error.operation))
    |> put_present("remote_status", error.status)
    |> put_present("retry_after", error.retry_after)
  end

  defp failure_output(%Error{} = error, input) do
    %{}
    |> put_present("effect_key", Map.get(input, :effect_key))
    |> put_detail(error.details, :field, "field")
    |> put_detail(error.details, :path, "path")
  end

  defp provider_message_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp provider_message_id(%{"message" => %{"id" => id}}) when is_binary(id) and id != "", do: id
  defp provider_message_id(_response), do: nil

  defp provider_channel_id(%{"channelId" => id}) when is_binary(id) and id != "", do: id
  defp provider_channel_id(%{"channel_id" => id}) when is_binary(id) and id != "", do: id
  defp provider_channel_id(%{"channel" => %{"id" => id}}) when is_binary(id) and id != "", do: id
  defp provider_channel_id(_response), do: nil

  defp text_bytes(%{"text" => text}) when is_binary(text), do: byte_size(text)
  defp text_bytes(_payload), do: nil

  defp blocks_count(%{"blocks" => blocks}) when is_list(blocks), do: length(blocks)
  defp blocks_count(payload) when is_map(payload), do: 0
  defp blocks_count(_payload), do: nil

  defp operation_name(operation) when is_atom(operation), do: Atom.to_string(operation)
  defp operation_name(operation) when is_binary(operation), do: operation
  defp operation_name(_operation), do: nil

  defp error_class(%Error{code: :installation_revoked}), do: "installation_revoked"
  defp error_class(%Error{class: class}), do: Atom.to_string(class)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_detail(output, details, key, name) when is_map(details) do
    case Map.get(details, key) || Map.get(details, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> Map.put(output, name, value)
      _missing -> output
    end
  end

  defp put_detail(output, _details, _key, _name), do: output
end
