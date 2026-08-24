defmodule PumbleAutomation.EchoWorker do
  @moduledoc """
  A trivial worker used only by the Oban tests.

  It proves that a job inserted through `PumbleAutomation.Oban` can be executed,
  without depending on a business context that does not exist yet. Following the
  payload invariant, its args carry an identifier only.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    {:ok, id}
  end
end
