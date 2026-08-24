defmodule PumbleAutomation.Executions.Nodes.Approval do
  @moduledoc """
  Prepares a durable approval wait: timeout, allowed approvers, and prompt.

  The worker calls this through `PumbleAutomation.Executions.NodeRunner`.
  Nothing here writes a row, signs a token, or talks to Pumble. Finalization
  creates the approval and timeout job; a separate delivery worker posts the
  message so the database transaction never holds a network lock.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Context
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Workflows.Node.ApprovalConfig
  alias PumbleAutomation.Workflows.Templates

  @min_seconds 1
  @max_approver_id 128
  @max_approvers 100
  @default_prompt "This workflow needs your approval."

  @doc """
  Returns a wait until `now + timeout`, or a permanent validation failure.

  `timeout_seconds` is a compiled integer. Approvers are explicit member or
  Pumble user identifiers; role-derived lists are refused. Secrets are not
  read. Delivery and token minting happen after this function returns.
  """
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    tree =
      Context.tree(%{
        context: Map.get(input, :context) || %{},
        trigger_snapshot: Map.get(input, :trigger_snapshot) || %{}
      })

    config = config(input)

    with {:ok, seconds} <- resolve_timeout(config["timeout_seconds"]),
         {:ok, member_ids} <- resolve_approver_ids(config["approver_member_ids"]),
         {:ok, prompt} <- render_prompt(config["prompt"], tree) do
      wait(seconds, member_ids, prompt, channel_id(input))
    else
      {:error, %Error{} = error} -> failure(error)
    end
  end

  defp wait(seconds, member_ids, prompt, channel_id) do
    resume_at = DateTime.add(DateTime.utc_now(), seconds, :second)

    Outcome.new(%{
      kind: :wait_approval,
      resume_at: resume_at,
      output:
        %{
          "timeout_seconds" => seconds,
          "expires_at" => DateTime.to_iso8601(resume_at),
          "prompt" => prompt,
          "approver_count" => length(member_ids)
        }
        |> put_present("channel_id", channel_id)
    })
  end

  defp resolve_timeout(seconds) when is_integer(seconds), do: validate_seconds(seconds)

  defp resolve_timeout(seconds) when is_binary(seconds) do
    case Integer.parse(String.trim(seconds)) do
      {value, ""} -> validate_seconds(value)
      _other -> {:error, invalid_timeout()}
    end
  end

  defp resolve_timeout(_other), do: {:error, missing_timeout()}

  defp validate_seconds(seconds) when is_integer(seconds) and seconds >= @min_seconds do
    if seconds <= ApprovalConfig.max_seconds() do
      {:ok, seconds}
    else
      {:error, invalid_timeout()}
    end
  end

  defp validate_seconds(_seconds) do
    {:error,
     Error.new(:validation, :invalid_approval_timeout,
       message: "The approval timeout must be between 1 second and 365 days.",
       details: %{field: "timeout_seconds"}
     )}
  end

  defp resolve_approver_ids(ids) when is_list(ids) do
    cond do
      ids == [] ->
        {:error, no_approvers()}

      length(ids) > @max_approvers ->
        {:error, no_approvers("The approval names too many approvers.")}

      Enum.any?(ids, &forbidden_selector?/1) ->
        {:error, unauthorized_approvers()}

      true ->
        validate_id_list(ids)
    end
  end

  defp resolve_approver_ids(_ids), do: {:error, no_approvers()}

  defp validate_id_list(ids) do
    cleaned = Enum.map(ids, &normalize_id/1)

    if Enum.all?(cleaned, &valid_id?/1) do
      {:ok, Enum.uniq(cleaned)}
    else
      {:error, unauthorized_approvers()}
    end
  end

  defp forbidden_selector?(id) when is_binary(id) do
    normalized = id |> String.trim() |> String.downcase()

    normalized in [
      "owner",
      "owners",
      "editor",
      "editors",
      "viewer",
      "viewers",
      "role",
      "group",
      "admins",
      "admin"
    ]
  end

  defp forbidden_selector?(_id), do: true

  defp normalize_id(id) when is_binary(id), do: String.trim(id)
  defp normalize_id(_id), do: ""

  defp valid_id?(id) when is_binary(id) do
    id != "" and byte_size(id) <= @max_approver_id and String.valid?(id)
  end

  defp valid_id?(_id), do: false

  defp render_prompt(prompt, _tree) when prompt in [nil, ""], do: {:ok, @default_prompt}

  defp render_prompt(prompt, tree) do
    case Templates.render(prompt, tree) do
      {:ok, %{value: text}} when is_binary(text) ->
        trimmed = String.trim(text)

        if trimmed == "" do
          {:ok, @default_prompt}
        else
          {:ok, trimmed}
        end

      {:ok, %{value: _other}} ->
        {:error,
         Error.new(:validation, :invalid_approval_prompt,
           message: "The approval prompt must render as text.",
           details: %{field: "prompt"}
         )}

      {:error, %Error{} = error} ->
        {:error, %{error | details: Map.put(error.details, :field, "prompt")}}
    end
  end

  defp channel_id(input) do
    snapshot = Map.get(input, :trigger_snapshot) || %{}
    data = Map.get(snapshot, "data")

    present(Map.get(snapshot, "channel_id")) ||
      present(is_map(data) && Map.get(data, "channel_id"))
  end

  defp present(id) when is_binary(id) and id != "", do: id
  defp present(_id), do: nil

  defp failure(%Error{} = error) do
    Outcome.new(%{
      kind: :permanent_error,
      error_class: "validation",
      message: error.message,
      output: failure_output(error)
    })
  end

  defp failure_output(%Error{details: details}) do
    %{}
    |> put_detail(details, :field, "field")
    |> put_detail(details, :path, "path")
  end

  defp put_detail(output, details, key, name) when is_map(details) do
    case Map.get(details, key) || Map.get(details, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> Map.put(output, name, value)
      _missing -> output
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp missing_timeout do
    Error.new(:validation, :invalid_approval_timeout,
      message: "The approval step does not name a timeout.",
      details: %{field: "timeout_seconds"}
    )
  end

  defp invalid_timeout do
    Error.new(:validation, :invalid_approval_timeout,
      message: "The approval timeout is not a whole number of seconds.",
      details: %{field: "timeout_seconds"}
    )
  end

  defp no_approvers(message \\ "The approval step does not name an approver.") do
    Error.new(:validation, :no_approvers,
      message: message,
      details: %{field: "approver_member_ids"}
    )
  end

  defp unauthorized_approvers do
    Error.new(:validation, :unauthorized_approvers,
      message: "The approval names an approver this workspace cannot use.",
      details: %{field: "approver_member_ids"}
    )
  end

  defp config(%{compiled_node: %{config: config}}) when is_map(config), do: config
  defp config(_input), do: %{}
end
