defmodule PumbleAutomation.Executions.Nodes.PumbleReply do
  @moduledoc """
  Replies in a Pumble thread through the client.

  A reply needs a channel and a thread-root (or message) identity. Those come
  from the compiled fields when they render, otherwise from the triggering
  event's `channel_id` and `thread_root_id`/`resource_id`. Missing either is a
  permanent validation failure, not a network call.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Nodes.Pumble
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Pumble.Client

  @doc "Sends the compiled threaded reply in `input`."
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    tree = Pumble.tree(input)

    with {:ok, :bot} <- Pumble.credential_kind(input),
         {:ok, channel_id} <- Pumble.target_id(input, tree, "channel_id", ["channel_id"]),
         {:ok, thread_root_id} <-
           Pumble.target_id(input, tree, "message_id", ["thread_root_id", "resource_id"]),
         {:ok, text} <- Pumble.render_text(input, tree, "text"),
         {:ok, payload} <- Pumble.payload(input, text) do
      Pumble.dispatch(
        input,
        %{
          operation: :reply,
          channel_id: channel_id,
          thread_root_id: thread_root_id,
          payload: payload
        },
        &Client.reply(&1, channel_id, thread_root_id, payload)
      )
    else
      {:error, %Error{} = error} -> Pumble.permanent(error, input)
    end
  end
end
