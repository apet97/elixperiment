defmodule PumbleAutomation.Executions.Nodes.PumbleDm do
  @moduledoc """
  Direct-messages a workspace user through the Pumble client.

  Lookup, create-if-missing, and send are the client's documented sequence.
  The compiled `user_id` is rendered first; the triggering actor is the
  fallback identity. The bot token is the only credential this action may use.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Nodes.Pumble
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Pumble.Client

  @doc "Sends the compiled direct message in `input`."
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    tree = Pumble.tree(input)

    with {:ok, :bot} <- Pumble.credential_kind(input),
         {:ok, user_id} <- Pumble.target_id(input, tree, "user_id", ["actor_id"]),
         {:ok, text} <- Pumble.render_text(input, tree, "text"),
         {:ok, payload} <- Pumble.payload(input, text) do
      Pumble.dispatch(
        input,
        %{
          operation: :send_direct_message,
          user_id: user_id,
          payload: payload
        },
        &Client.send_direct_message(&1, user_id, payload)
      )
    else
      {:error, %Error{} = error} -> Pumble.permanent(error, input)
    end
  end
end
