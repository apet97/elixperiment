defmodule PumbleAutomation.Oban do
  @moduledoc """
  Transactional job insertion and the operational contract around it.

  ## Why this module exists

  A durable job is only correct when it commits with the row it serves. If a
  business row is written and the job insert fails, the work is lost. If the job
  is inserted and the business row is rolled back, the worker runs against a row
  that does not exist. Both failures disappear when a single `Ecto.Multi` carries
  the business change and the job insert into one database transaction.

  Every function here takes a caller-owned `Ecto.Multi` and returns it. The
  caller keeps ownership of the transaction and decides when to run it, so the
  job insert can sit between the steps that produce the identifiers it needs.

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:execution, changeset)
      |> PumbleAutomation.Oban.insert(:dispatch, fn %{execution: execution} ->
        MyApp.Workers.Execute.new(%{execution_id: execution.id})
      end)
      |> PumbleAutomation.Repo.transaction()

  ## Invariant: job payloads carry identifiers only

  A job `args` map holds database identifiers and small scalar discriminators,
  and nothing else. It never holds an access token, a signing secret, an
  encryption key, a decrypted credential, a Pumble message body, or any other
  private payload.

  The reasons are durable and operational: `oban_jobs` rows outlive the request
  that created them, they are readable by anyone with database or dashboard
  access, and they are copied into backups and error reports. A worker reads the
  identifier, loads the row inside its own transaction, and applies the current
  authorization checks. That also keeps a retry from acting on a stale copy of
  data that changed after the job was enqueued.

  This invariant is a convention, not a runtime check. Review job payloads when
  a worker is added.

  ## Operations

  ### Shutdown grace

  `:shutdown_grace_period` is 30 seconds (`config/config.exs`). On shutdown Oban
  stops fetching new jobs and waits up to that period for executing jobs to
  finish. A job still running at the end of the period is terminated, is left in
  the `executing` state, and is rescued back to `available` by
  `Oban.Plugins.Lifeline` after `:rescue_after` (30 minutes). Because a rescued
  job runs again, every worker must be idempotent (ADR-0006).

  Deployment platforms must allow a termination grace period longer than 30
  seconds, otherwise the container is killed before the wait completes.

  ### Pause and drain a queue

      # stop fetching new jobs on one node
      Oban.pause_queue(queue: :executions)

      # stop fetching across the whole cluster
      Oban.pause_queue(queue: :executions, all_nodes: true)

      # resume
      Oban.resume_queue(queue: :executions, all_nodes: true)

      # pause every queue, for example before a risky migration
      Oban.pause_all_queues(all_nodes: true)

  Pausing lets jobs that already started finish. To drain, pause the queue and
  then wait for `executing` to reach zero:

      import Ecto.Query

      PumbleAutomation.Repo.aggregate(
        from(j in "oban_jobs", where: j.state == "executing"),
        :count
      )

  Concurrency can also be changed live, without a deployment:

      Oban.scale_queue(queue: :ingress, limit: 5, all_nodes: true)

  Pause state is stored in the database, so it survives a node restart. Resume
  every paused queue before declaring an incident closed.

  ### Health

  Queue depth per state, which is the readiness signal for job execution:

      SELECT queue, state, count(*)
      FROM oban_jobs
      GROUP BY queue, state
      ORDER BY queue, state;
  """

  alias Ecto.Multi
  alias Oban.Job

  @typedoc "A job, or a function that builds one from the results so far."
  @type changeset_or_fun :: Job.changeset() | (map() -> Job.changeset())

  @typedoc "Many jobs, or a function that builds them from the results so far."
  @type changesets_or_fun :: [Job.changeset()] | (map() -> [Job.changeset()])

  @doc """
  Adds one job insert to `multi` under `name`.

  `changeset_or_fun` is either an `Oban.Job` changeset or a one-argument
  function that receives the results of the earlier steps and returns one. Use
  the function form whenever the payload needs an identifier produced by an
  earlier step.

  `opts` accepts the usual `Oban.insert/4` options, such as `:on_conflict` for a
  unique job.
  """
  @spec insert(Multi.t(), Multi.name(), changeset_or_fun(), keyword()) :: Multi.t()
  def insert(multi, name, changeset_or_fun, opts \\ []) do
    Oban.insert(multi, name, changeset_or_fun, opts)
  end

  @doc """
  Adds a bulk job insert to `multi` under `name`.

  Bulk insertion skips per-job unique checks, so it is for fan-out where the
  caller already knows the jobs are distinct.
  """
  @spec insert_all(Multi.t(), Multi.name(), changesets_or_fun(), keyword()) :: Multi.t()
  def insert_all(multi, name, changesets_or_fun, opts \\ []) do
    Oban.insert_all(multi, name, changesets_or_fun, opts)
  end
end
