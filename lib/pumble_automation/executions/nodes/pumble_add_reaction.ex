defmodule PumbleAutomation.Executions.Nodes.PumbleAddReaction do
  @moduledoc """
  Adds a Pumble reaction through the client.

  The compiled `message_id` and `reaction` are rendered against the run tree.
  Message identity may also come from the triggering event. An optional skin
  tone is validated against the documented integer form. The bot token is the
  only credential this action may use.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Nodes.Pumble
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Pumble.Client

  @doc "Adds the compiled reaction in `input`."
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    tree = Pumble.tree(input)

    with {:ok, :bot} <- Pumble.credential_kind(input),
         {:ok, :same} <- Pumble.same_workspace(input, tree),
         {:ok, message_id} <-
           Pumble.target_id(input, tree, "message_id", ["resource_id", "message_id"]),
         {:ok, code} <- Pumble.render_text(input, tree, "reaction"),
         {:ok, skin_tone} <- Pumble.skin_tone(input),
         {:ok, _body} <- Pumble.reaction_payload(code, skin_tone) do
      Pumble.dispatch(
        input,
        %{
          operation: :add_reaction,
          message_id: message_id,
          reaction: code,
          skin_tone: skin_tone
        },
        &Client.add_reaction(&1, message_id, code, skin_tone)
      )
    else
      {:error, %Error{} = error} -> Pumble.permanent(error, input)
    end
  end
end
