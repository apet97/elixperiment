defmodule PumbleAutomation.Workflows.ScheduleTest do
  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Workflows.Schedule

  setup do
    %{installation: %{id: installation_id}} = InstallationsFixtures.install()
    workflow = drafted_workflow(installation_id)
    version = version(workflow)

    %{installation_id: installation_id, workflow: workflow, version: version}
  end

  describe "the migration" do
    test "creates the due index and the one-clock-per-workflow index" do
      definitions = index_definitions("schedules")

      assert definitions =~ "schedules_due_index"
      assert definitions =~ "(enabled, next_run_at)"
      assert definitions =~ "schedules_enabled_workflow_index"
      assert definitions =~ "WHERE enabled"
    end

    test "binds only to a workflow and a version of its own tenant" do
      keys = foreign_keys("schedules")

      assert keys =~ "(workflow_id, installation_id)"
      assert keys =~ "(workflow_version_id, installation_id)"
    end
  end

  describe "the due index" do
    test "serves the due-schedule predicate with an index scan", %{version: version} do
      schedule(version, %{next_run_at: minutes_ago(5)})

      plan = explain_index_plan(Schedule.due(DateTime.utc_now()))

      assert index_backed?(plan)
    end
  end

  describe "due/1" do
    test "returns a schedule whose time has come", %{version: version} do
      ready = schedule(version, %{next_run_at: minutes_ago(1)})

      assert [found] = Repo.all(Schedule.due(DateTime.utc_now()))
      assert found.id == ready.id
    end

    test "does not return one whose time has not", %{version: version} do
      schedule(version, %{next_run_at: minutes_ago(-30)})

      assert [] == Repo.all(Schedule.due(DateTime.utc_now()))
    end

    test "does not return one with no next run", %{version: version} do
      schedule(version, %{next_run_at: nil})

      assert [] == Repo.all(Schedule.due(DateTime.utc_now()))
    end

    test "never returns a disabled schedule, however overdue", %{version: version} do
      schedule(version, %{next_run_at: minutes_ago(600), enabled: false})

      assert [] == Repo.all(Schedule.due(DateTime.utc_now()))
    end

    test "orders the oldest due schedule first", %{
      installation_id: installation_id,
      version: version
    } do
      older = schedule(version, %{next_run_at: minutes_ago(60)})

      newer =
        installation_id
        |> drafted_workflow(%{name: "Second"})
        |> version()
        |> schedule(%{next_run_at: minutes_ago(1)})

      assert Enum.map(Repo.all(Schedule.due(DateTime.utc_now())), & &1.id) == [older.id, newer.id]
    end
  end

  describe "one enabled schedule per workflow" do
    test "refuses a second enabled schedule for one workflow", %{
      workflow: workflow,
      version: version
    } do
      schedule(version)

      second = version(workflow, %{source_definition: definition([message_node()])})

      assert {:error, changeset} =
               %Schedule{}
               |> Schedule.changeset(%{
                 installation_id: second.installation_id,
                 workflow_id: second.workflow_id,
                 workflow_version_id: second.id,
                 schedule_type: "daily",
                 timezone: "Etc/UTC"
               })
               |> Repo.insert()

      assert %{workflow_id: [_message]} = errors_on(changeset)
    end

    test "accepts the replacement once the old one is disabled", %{
      workflow: workflow,
      version: version
    } do
      first = schedule(version)
      first |> Schedule.changeset(%{enabled: false}) |> Repo.update!()

      second = version(workflow, %{source_definition: definition([message_node()])})

      assert {:ok, _schedule} =
               %Schedule{}
               |> Schedule.changeset(%{
                 installation_id: second.installation_id,
                 workflow_id: second.workflow_id,
                 workflow_version_id: second.id,
                 schedule_type: "daily",
                 timezone: "Etc/UTC"
               })
               |> Repo.insert()
    end
  end

  describe "claim/2" do
    test "takes the schedule and moves its next run", %{version: version} do
      ready = schedule(version, %{next_run_at: minutes_ago(1)})
      next = minutes_ago(-60)

      assert {:ok, claimed} =
               Schedule.claim(ready,
                 next_run_at: next,
                 last_run_at: DateTime.utc_now(),
                 last_dispatch_status: "enqueued"
               )

      assert claimed.lock_version == ready.lock_version + 1
      assert claimed.dispatch_count == 1
      assert DateTime.compare(claimed.next_run_at, DateTime.utc_now()) == :gt
    end

    test "the loser of a race claims nothing", %{version: version} do
      ready = schedule(version, %{next_run_at: minutes_ago(1)})

      assert {:ok, _claimed} = Schedule.claim(ready, next_run_at: minutes_ago(-60))
      assert :error == Schedule.claim(ready, next_run_at: minutes_ago(-60))

      assert Repo.get!(Schedule, ready.id).dispatch_count == 1
    end

    test "a disabled schedule cannot be claimed", %{version: version} do
      ready = schedule(version, %{next_run_at: minutes_ago(1)})
      disabled = ready |> Schedule.changeset(%{enabled: false}) |> Repo.update!()

      assert :error == Schedule.claim(disabled, next_run_at: minutes_ago(-60))
    end
  end

  describe "the timezone" do
    test "accepts identifiers that look like IANA zones" do
      for zone <- ~w(UTC Etc/UTC Europe/Belgrade America/Argentina/Buenos_Aires Etc/GMT+3) do
        assert Schedule.valid_timezone?(zone), zone
      end
    end

    test "refuses what does not look like one" do
      for zone <- ["", "  ", "/Belgrade", "Europe/Belgrade/Extra/Deep", "Europe Belgrade", 7] do
        refute Schedule.valid_timezone?(zone), inspect(zone)
      end
    end

    test "does not claim a zone that looks right actually exists" do
      # Deliberate: shape only until Phase 11. See the module documentation.
      assert Schedule.valid_timezone?("Europe/Atlantis")
    end

    test "the changeset refuses a malformed zone", %{version: version} do
      changeset =
        Schedule.changeset(%Schedule{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          schedule_type: "daily",
          timezone: "not a zone"
        })

      assert %{timezone: [_message]} = errors_on(changeset)
    end

    test "the database refuses one too, whatever the changeset did", %{version: version} do
      assert_raise Postgrex.Error, ~r/schedules_timezone_check/, fn ->
        Repo.query!(
          """
          INSERT INTO schedules
            (id, installation_id, workflow_id, workflow_version_id, schedule_type,
             config, timezone, enabled, lock_version, dispatch_count,
             inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, 'daily', '{}'::jsonb, 'not a zone', true, 0, 0, now(), now())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(version.installation_id),
            Ecto.UUID.dump!(version.workflow_id),
            Ecto.UUID.dump!(version.id)
          ]
        )
      end
    end
  end

  describe "changeset/2" do
    test "requires a tenant, a workflow, a version, a type, and a zone" do
      changeset = Schedule.changeset(%Schedule{}, %{})

      assert %{
               installation_id: [_],
               workflow_id: [_],
               workflow_version_id: [_],
               schedule_type: [_]
             } = errors_on(changeset)
    end

    test "refuses an unknown schedule type", %{version: version} do
      changeset =
        Schedule.changeset(%Schedule{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          schedule_type: "fortnightly",
          timezone: "Etc/UTC"
        })

      assert %{schedule_type: [_message]} = errors_on(changeset)
    end
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  defp index_definitions(table) do
    %{rows: rows} = Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])
    Enum.map_join(rows, "\n", &hd/1)
  end

  defp foreign_keys(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pg_get_constraintdef(c.oid)
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname = $1 AND c.contype = 'f'
        """,
        [table]
      )

    Enum.map_join(rows, "\n", &hd/1)
  end
end
