defmodule PumbleAutomation.Executions.Nodes.PumbleSendMessage do
  @moduledoc """
  Posts a channel message through the Pumble client.

  The compiled `channel_id` and `text` are rendered against the run tree.
  Channel identity may also come from the triggering event. The bot token is
  the only credential this action may use.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Nodes.Pumble
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Pumble.Client

  @doc "Sends the compiled channel message in `input`."
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    tree = Pumble.tree(input)

    with {:ok, :bot} <- Pumble.credential_kind(input),
         {:ok, channel_id} <- Pumble.target_id(input, tree, "channel_id", ["channel_id"]),
         {:ok, text} <- Pumble.render_text(input, tree, "text"),
         {:ok, payload} <- Pumble.payload(input, text) do
      Pumble.dispatch(
        input,
        %{
          operation: :post_message,
          channel_id: channel_id,
          payload: payload
        },
        &Client.post_message(&1, channel_id, payload)
      )
    else
      {:error, %Error{} = error} -> Pumble.permanent(error, input)
    end
  end
end
