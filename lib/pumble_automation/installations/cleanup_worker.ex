defmodule PumbleAutomation.Installations.CleanupWorker do
  @moduledoc """
  Hourly OAuth/session cleanup and operational integrity checks.

  Cron passes `kind` in the args: `"cleanup"` deletes expired OAuth states and
  unusable sessions; `"integrity"` repairs safe projection drift, enqueues due
  tenant purges, restores missing wait/timeout jobs through
  `Engine.reconcile/1`, and emits alerts for orphan secret references.

  One incomplete job per kind. Args are kind, optional tenant id, batch size,
  and cursor only. Pause/run-once live on `PumbleAutomation.Maintenance`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:kind], states: :incomplete]

  alias PumbleAutomation.Maintenance

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Maintenance.perform(kind(args), args)
  end

  defp kind(args) when is_map(args) do
    case Map.get(args, "kind") || Map.get(args, :kind) do
      "integrity" -> :integrity
      :integrity -> :integrity
      _other -> :cleanup
    end
  end
end
