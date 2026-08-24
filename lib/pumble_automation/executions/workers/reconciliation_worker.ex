defmodule PumbleAutomation.Executions.Workers.ReconciliationWorker do
  @moduledoc """
  Bounded, idempotent repair of recoverable execution and job gaps.

  The worker does not invent state. It asks the engine to admit parked
  queued rows, restore missing wait jobs, and classify stale running
  attempts. Ambiguous writes pause as uncertain. Uninstall refuses resume.
  Duplicate runs are a no-op once the gaps are gone.

  Scheduled by Oban cron every five minutes. One incomplete job of this
  worker exists at a time. Occupancy-parked queued rows are not missing
  jobs. Pause/run-once live on `PumbleAutomation.Maintenance`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  alias PumbleAutomation.Maintenance

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Maintenance.perform(:reconcile, args)
  end
end
