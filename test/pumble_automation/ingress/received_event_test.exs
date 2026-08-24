defmodule PumbleAutomation.Ingress.ReceivedEventTest do
  @moduledoc """
  Durable received-event constraints: identity, sanitization, and retention.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.IngressFixtures

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.ExecutionsFixtures
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.InstallationsFixtures

  setup do
    %{installation: %{id: installation_id}} = InstallationsFixtures.install()
    %{installation_id: installation_id}
  end

  describe "the migration" do
    test "creates the table with dedup uniqueness and lookup indexes" do
      assert %{rows: [["received_events"]]} =
               Repo.query!("SELECT to_regclass('public.received_events')::text")

      definitions = index_definitions("received_events")
      assert definitions =~ "received_events_installation_id_provider_dedup_key_index"
      assert definitions =~ "UNIQUE"
      assert definitions =~ "(installation_id, provider, dedup_key)"
      assert definitions =~ "received_events_retain_until_index"
      assert definitions =~ "(retain_until)"
      assert definitions =~ "received_events_installation_id_processing_state_index"

      assert "received_events_processing_state_check" in check_constraints("received_events")
      assert "received_events_retention_window_check" in check_constraints("received_events")
      assert "received_events_raw_body_hash_check" in check_constraints("received_events")
    end

    test "gives executions.received_event_id a foreign key that nilifies" do
      assert foreign_keys("executions") =~ "received_events"
      assert foreign_keys("executions") =~ "ON DELETE SET NULL"
    end

    test "does not create a raw body or credential column" do
      fields = ReceivedEvent.__schema__(:fields)
      refute :raw_body in fields
      refute :body in fields
      refute :payload in fields
      refute :token in fields
    end
  end

  describe "the retention index" do
    test "serves due_for_retention/1 with an index scan", %{installation_id: installation_id} do
      received_event(installation_id)

      plan = explain_index_plan(ReceivedEvent.due_for_retention(DateTime.utc_now()))

      assert index_backed?(plan)
    end
  end

  describe "changeset and insert" do
    test "inserts a received receipt bound to its installation", %{
      installation_id: installation_id
    } do
      event = received_event(installation_id)

      assert event.installation_id == installation_id
      assert event.provider == "pumble"
      assert event.class == "event"
      assert event.processing_state == "received"

      assert event.retain_until ==
               DateTime.add(event.received_at, ReceivedEvent.retention_days(), :day)

      assert byte_size(event.raw_body_hash) == ReceivedEvent.hash_bytes()
    end

    test "defaults retain_until to thirty days after receipt", %{installation_id: installation_id} do
      received_at = ~U[2026-01-01 00:00:00.000000Z]

      event =
        received_event(installation_id, %{
          received_at: received_at,
          occurred_at: received_at
        })

      assert event.retain_until == ~U[2026-01-31 00:00:00.000000Z]
    end

    test "refuses a duplicate dedup key in one tenant", %{installation_id: installation_id} do
      received_event(installation_id, %{dedup_key: "same-delivery"})

      assert {:error, changeset} =
               %ReceivedEvent{}
               |> ReceivedEvent.changeset(%{
                 installation_id: installation_id,
                 provider: "pumble",
                 class: "event",
                 type: "NEW_MESSAGE",
                 dedup_key: "same-delivery",
                 raw_body_hash: ReceivedEvent.hash_body("other-bytes"),
                 occurred_at: DateTime.utc_now()
               })
               |> Repo.insert()

      assert %{dedup_key: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows the same dedup key in another tenant", %{installation_id: installation_id} do
      received_event(installation_id, %{dedup_key: "same-delivery"})
      %{installation: other} = InstallationsFixtures.install()

      assert %ReceivedEvent{} = received_event(other.id, %{dedup_key: "same-delivery"})
    end

    test "refuses a provider, class, or processing state outside the closed set", %{
      installation_id: installation_id
    } do
      attrs = %{
        installation_id: installation_id,
        provider: "pumble",
        class: "event",
        type: "NEW_MESSAGE",
        dedup_key: "k",
        raw_body_hash: ReceivedEvent.hash_body("body"),
        occurred_at: DateTime.utc_now()
      }

      assert %{provider: [_]} =
               errors_on(ReceivedEvent.changeset(%ReceivedEvent{}, %{attrs | provider: "slack"}))

      assert %{class: [_]} =
               errors_on(ReceivedEvent.changeset(%ReceivedEvent{}, %{attrs | class: "unknown"}))

      assert %{processing_state: [_]} =
               errors_on(
                 ReceivedEvent.changeset(
                   %ReceivedEvent{},
                   Map.put(attrs, :processing_state, "queued")
                 )
               )
    end

    test "refuses a hash that is not 32 bytes", %{installation_id: installation_id} do
      changeset =
        ReceivedEvent.changeset(%ReceivedEvent{}, %{
          installation_id: installation_id,
          provider: "pumble",
          class: "event",
          type: "NEW_MESSAGE",
          dedup_key: "k",
          raw_body_hash: "not-a-digest",
          occurred_at: DateTime.utc_now()
        })

      assert %{raw_body_hash: [_]} = errors_on(changeset)
    end

    test "refuses secret-looking keys and oversized data", %{installation_id: installation_id} do
      attrs = %{
        installation_id: installation_id,
        provider: "pumble",
        class: "event",
        type: "NEW_MESSAGE",
        dedup_key: "k",
        raw_body_hash: ReceivedEvent.hash_body("body"),
        occurred_at: DateTime.utc_now()
      }

      assert %{data: [_]} =
               errors_on(
                 ReceivedEvent.changeset(
                   %ReceivedEvent{},
                   Map.put(attrs, :data, %{"signing_secret" => "no"})
                 )
               )

      blob = String.duplicate("x", ReceivedEvent.max_data_bytes() + 1)

      assert %{data: ["is too large"]} =
               errors_on(
                 ReceivedEvent.changeset(
                   %ReceivedEvent{},
                   Map.put(attrs, :data, %{"blob" => blob})
                 )
               )
    end

    test "refuses a retention date before receipt or after the thirty-day window", %{
      installation_id: installation_id
    } do
      received_at = ~U[2026-01-01 00:00:00.000000Z]

      attrs = %{
        installation_id: installation_id,
        provider: "pumble",
        class: "event",
        type: "NEW_MESSAGE",
        dedup_key: "k",
        raw_body_hash: ReceivedEvent.hash_body("body"),
        received_at: received_at,
        occurred_at: received_at
      }

      assert %{retain_until: [_]} =
               errors_on(
                 ReceivedEvent.changeset(
                   %ReceivedEvent{},
                   Map.put(attrs, :retain_until, received_at)
                 )
               )

      assert %{retain_until: [_]} =
               errors_on(
                 ReceivedEvent.changeset(
                   %ReceivedEvent{},
                   Map.put(attrs, :retain_until, DateTime.add(received_at, 31, :day))
                 )
               )
    end

    test "an execution may name a receipt, and a missing receipt is refused", %{
      installation_id: installation_id
    } do
      event = received_event(installation_id)
      version = ExecutionsFixtures.version(installation_id)

      run =
        ExecutionsFixtures.execution(version, %{
          received_event_id: event.id,
          execution_key: "from-receipt"
        })

      assert run.received_event_id == event.id

      assert {:error, changeset} =
               %Execution{}
               |> Execution.changeset(%{
                 installation_id: installation_id,
                 workflow_id: version.workflow_id,
                 workflow_version_id: version.id,
                 received_event_id: Ecto.UUID.generate(),
                 execution_key: "missing-receipt",
                 status: "queued"
               })
               |> Repo.insert()

      assert %{received_event_id: [_]} = errors_on(changeset)
    end
  end

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

  defp check_constraints(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT con.conname FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        WHERE rel.relname = $1 AND con.contype = 'c'
        """,
        [table]
      )

    rows |> Enum.map(fn [name] -> name end) |> Enum.sort()
  end
end

defmodule PumbleAutomation.Ingress.ReceivedEventDedupRaceTest do
  @moduledoc """
  Several callbacks inserting the same dedup key at once.

  The unique index on `(installation_id, provider, dedup_key)` only refuses a
  duplicate another transaction has actually committed, so this cannot run
  inside the SQL sandbox.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo

  @writers 6

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "exactly one writer wins the (installation, provider, dedup_key) identity" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    dedup_key = "race-#{System.unique_integer([:positive])}"

    outcomes =
      1..@writers
      |> Task.async_stream(
        fn _index ->
          %ReceivedEvent{}
          |> ReceivedEvent.changeset(%{
            installation_id: installation.id,
            provider: "pumble",
            class: "event",
            type: "NEW_MESSAGE",
            dedup_key: dedup_key,
            raw_body_hash: ReceivedEvent.hash_body("body"),
            occurred_at: DateTime.utc_now()
          })
          |> Repo.insert()
        end,
        max_concurrency: @writers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(outcomes, &match?({:ok, _event}, &1)) == 1
    assert Enum.count(outcomes, &match?({:error, _changeset}, &1)) == @writers - 1

    stored =
      Repo.all(
        from e in ReceivedEvent,
          where:
            e.installation_id == ^installation.id and e.provider == "pumble" and
              e.dedup_key == ^dedup_key
      )

    assert length(stored) == 1
  end
end
