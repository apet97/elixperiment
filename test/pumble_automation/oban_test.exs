defmodule PumbleAutomation.ObanTest do
  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  alias PumbleAutomation.EchoWorker

  # A scratch table stands in for a business table. It is created inside the
  # sandbox transaction, so it disappears with the test and no migration or
  # domain schema is needed to prove the transactional guarantee.
  setup do
    Repo.query!("CREATE TEMPORARY TABLE scratch_rows (id uuid PRIMARY KEY) ON COMMIT DROP")
    :ok
  end

  describe "migration" do
    test "creates the oban_jobs table" do
      assert %{rows: [[table]]} = Repo.query!("SELECT to_regclass('public.oban_jobs')::text")
      assert table == "oban_jobs"
    end

    test "records the pinned schema version" do
      assert %{rows: [[comment]]} =
               Repo.query!("SELECT obj_description('public.oban_jobs'::regclass, 'pg_class')")

      assert comment == "14"
    end
  end

  describe "insert/4" do
    test "commits the business row and the job in one transaction" do
      id = Ecto.UUID.generate()

      assert {:ok, %{job: %Oban.Job{}}} =
               Ecto.Multi.new()
               |> insert_scratch_row(id)
               |> PumbleAutomation.Oban.insert(:job, EchoWorker.new(%{id: id}))
               |> Repo.transaction()

      assert scratch_row_count() == 1
      assert_enqueued(worker: EchoWorker, args: %{id: id}, queue: :maintenance)
    end

    test "builds the payload from an earlier step" do
      id = Ecto.UUID.generate()

      assert {:ok, _changes} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:row, fn _repo, _changes -> {:ok, %{id: id}} end)
               |> PumbleAutomation.Oban.insert(:job, fn %{row: row} ->
                 EchoWorker.new(%{id: row.id})
               end)
               |> Repo.transaction()

      assert_enqueued(worker: EchoWorker, args: %{id: id})
    end

    test "rollback removes both the business row and the job" do
      id = Ecto.UUID.generate()

      assert {:error, :guard, :rejected, _changes} =
               Ecto.Multi.new()
               |> insert_scratch_row(id)
               |> PumbleAutomation.Oban.insert(:job, EchoWorker.new(%{id: id}))
               |> Ecto.Multi.run(:guard, fn _repo, _changes -> {:error, :rejected} end)
               |> Repo.transaction()

      assert scratch_row_count() == 0
      refute_enqueued(worker: EchoWorker, args: %{id: id})
      assert Repo.aggregate(Oban.Job, :count) == 0
    end
  end

  describe "insert_all/4" do
    test "enqueues every job in the transaction" do
      ids = Enum.map(1..3, fn _index -> Ecto.UUID.generate() end)

      assert {:ok, %{jobs: jobs}} =
               Ecto.Multi.new()
               |> PumbleAutomation.Oban.insert_all(
                 :jobs,
                 Enum.map(ids, &EchoWorker.new(%{id: &1}))
               )
               |> Repo.transaction()

      assert length(jobs) == 3
      for id <- ids, do: assert_enqueued(worker: EchoWorker, args: %{id: id})
    end

    test "rollback removes every job" do
      ids = Enum.map(1..3, fn _index -> Ecto.UUID.generate() end)

      assert {:error, :guard, :rejected, _changes} =
               Ecto.Multi.new()
               |> PumbleAutomation.Oban.insert_all(
                 :jobs,
                 Enum.map(ids, &EchoWorker.new(%{id: &1}))
               )
               |> Ecto.Multi.run(:guard, fn _repo, _changes -> {:error, :rejected} end)
               |> Repo.transaction()

      assert Repo.aggregate(Oban.Job, :count) == 0
    end
  end

  describe "worker" do
    test "performs a job whose payload carries an identifier only" do
      id = Ecto.UUID.generate()

      assert {:ok, ^id} = perform_job(EchoWorker, %{id: id})
    end
  end

  describe "configuration" do
    test "declares the four planned queues at the planned concurrency" do
      queues = Application.fetch_env!(:pumble_automation, :queue_concurrency)

      assert Enum.sort(queues) == [executions: 20, ingress: 20, maintenance: 2, schedules: 2]
    end

    test "enables Cron for the dispatcher and the four maintenance ticks" do
      plugins = Keyword.get(Application.fetch_env!(:pumble_automation, Oban), :plugins, [])

      cron =
        Enum.find_value(plugins, fn
          {Oban.Plugins.Cron, opts} -> opts
          Oban.Plugins.Cron -> []
          _other -> nil
        end)

      assert cron[:crontab] == [
               {"* * * * *", PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker},
               {"*/5 * * * *", PumbleAutomation.Executions.Workers.ReconciliationWorker},
               {"17 * * * *", PumbleAutomation.Installations.CleanupWorker,
                args: %{kind: "cleanup"}},
               {"47 * * * *", PumbleAutomation.Installations.CleanupWorker,
                args: %{kind: "integrity"}},
               {"23 3 * * *", PumbleAutomation.Executions.Workers.RetentionWorker}
             ]
    end
  end

  defp insert_scratch_row(multi, id) do
    Ecto.Multi.insert_all(multi, :row, "scratch_rows", [%{id: Ecto.UUID.dump!(id)}])
  end

  defp scratch_row_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM scratch_rows")
    count
  end
end
