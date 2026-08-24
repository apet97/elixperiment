defmodule PumbleAutomation.Ingress.DeduplicationTest do
  @moduledoc """
  Provider-aware receipt keys: documented ids win, fallbacks are bounded,
  and webhooks without an idempotency header stay distinct.
  """

  use PumbleAutomation.DataCase, async: false

  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.Deduplication
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.InstallationsFixtures

  @received_at ~U[2026-01-01 00:00:00.000000Z]

  setup do
    %{installation: %{id: installation_id}} = InstallationsFixtures.install()
    %{installation_id: installation_id}
  end

  describe "documented event ids" do
    test "the same request id yields one key even when the body changes", %{
      installation_id: installation_id
    } do
      first = event_request(installation_id, %{provider_id: "RID-1", raw_body: "body-a"})
      second = event_request(installation_id, %{provider_id: "RID-1", raw_body: "body-b"})

      assert {:ok, %Deduplication{strategy: :provider_id, dedup_key: key}} =
               Deduplication.key(first)

      assert {:ok, %Deduplication{dedup_key: ^key}} = Deduplication.key(second)
      assert String.starts_with?(key, "pid:")
      assert String.length(key) <= 128
    end

    test "a same-id different-body insert records an integrity anomaly", %{
      installation_id: installation_id
    } do
      attach_telemetry()

      first = event_request(installation_id, %{provider_id: "RID-1", raw_body: "body-a"})
      second = event_request(installation_id, %{provider_id: "RID-1", raw_body: "body-b"})

      assert {:ok, :new, stored} = Deduplication.record(first)
      assert {:ok, :duplicate, again} = Deduplication.record(second)
      assert stored.id == again.id
      assert stored.raw_body_hash == ReceivedEvent.hash_body("body-a")
      assert again.raw_body_hash == stored.raw_body_hash
      assert stored.provider_id == "RID-1"

      assert_receive {:telemetry, [:pumble_automation, :ingress, :dedup, :integrity_anomaly],
                      %{count: 1}, metadata}

      assert metadata.class == "event"
      assert metadata.strategy == :provider_id
      assert metadata.type == "NEW_MESSAGE"
      refute Map.has_key?(metadata, :raw_body)
      refute Map.has_key?(metadata, :provider_id)
    end

    test "a same-id same-body retry is a silent duplicate", %{installation_id: installation_id} do
      attach_telemetry()
      request = event_request(installation_id, %{provider_id: "RID-2", raw_body: "same"})

      assert {:ok, :new, stored} = Deduplication.record(request)
      assert {:ok, :duplicate, again} = Deduplication.record(request)
      assert stored.id == again.id

      refute_received {:telemetry, [:pumble_automation, :ingress, :dedup, :integrity_anomaly], _,
                       _}
    end

    test "stores a valid provider-id prefix when the byte cap crosses a codepoint", %{
      installation_id: installation_id
    } do
      prefix = String.duplicate("r", 255)
      request = event_request(installation_id, %{provider_id: prefix <> "😀"})

      assert {:ok, :new, stored} = Deduplication.record(request)
      assert stored.provider_id == prefix
      assert String.valid?(stored.provider_id)
    end
  end

  describe "fallback window" do
    test "byte-identical events without an id share a key inside the bucket and split on the boundary",
         %{installation_id: installation_id} do
      window = Deduplication.fallback_window_seconds()
      unix = 1_800_000_000
      inside = DateTime.from_unix!(unix)
      last = DateTime.from_unix!(unix + window - 1)
      next = DateTime.from_unix!(unix + window)

      base = %{provider_id: nil, raw_body: "same-bytes", signature: "sig-1"}

      assert {:ok, first} =
               Deduplication.key(
                 event_request(installation_id, Map.put(base, :received_at, inside))
               )

      assert {:ok, still} =
               Deduplication.key(
                 event_request(installation_id, Map.put(base, :received_at, last))
               )

      assert {:ok, after_window} =
               Deduplication.key(
                 event_request(installation_id, Map.put(base, :received_at, next))
               )

      assert first.strategy == :fallback
      assert first.dedup_key == still.dedup_key
      assert first.dedup_key != after_window.dedup_key
      assert first.window_started_at == DateTime.from_unix!(unix)
      assert after_window.window_started_at == DateTime.from_unix!(unix + window)
      assert String.starts_with?(first.dedup_key, "fb:")
    end

    test "fallback choice is visible on telemetry", %{installation_id: installation_id} do
      attach_telemetry()

      assert {:ok, _} =
               Deduplication.key(
                 event_request(installation_id, %{
                   provider_id: nil,
                   raw_body: "bytes",
                   received_at: @received_at
                 })
               )

      assert_receive {:telemetry, [:pumble_automation, :ingress, :dedup, :key], %{count: 1},
                      metadata}

      assert metadata.fallback? == true
      assert metadata.strategy == :fallback
      assert metadata.window_seconds == Deduplication.fallback_window_seconds()
      assert metadata.class == "event"
    end
  end

  describe "webhooks" do
    test "a caller idempotency key is hashed, not stored", %{installation_id: installation_id} do
      header = "Idem-#{String.duplicate("secret", 40)}"

      assert {:ok, derived} =
               Deduplication.key(
                 webhook_request(installation_id, %{
                   idempotency_key: header,
                   raw_body: "payload"
                 })
               )

      assert derived.strategy == :idempotency_key
      assert String.starts_with?(derived.dedup_key, "ik:")
      refute derived.dedup_key =~ "secret"
      refute derived.dedup_key =~ header
      assert derived.provider_id == nil
    end

    test "an unbounded idempotency key still fits the indexed column", %{
      installation_id: installation_id
    } do
      header = String.duplicate("k", Deduplication.max_input_bytes() + 500)

      assert {:ok, derived} =
               Deduplication.key(webhook_request(installation_id, %{idempotency_key: header}))

      assert String.length(derived.dedup_key) <= 128
    end

    test "the same idempotency key on one endpoint collapses", %{installation_id: installation_id} do
      request =
        webhook_request(installation_id, %{idempotency_key: "once", raw_body: "payload"})

      assert {:ok, :new, stored} = Deduplication.record(request)
      assert {:ok, :duplicate, again} = Deduplication.record(request)
      assert stored.id == again.id
    end

    test "without an idempotency key each authenticated request is a distinct delivery", %{
      installation_id: installation_id
    } do
      body = "same-payload"
      first = webhook_request(installation_id, %{raw_body: body})
      second = webhook_request(installation_id, %{raw_body: body})

      assert {:ok, a} = Deduplication.key(first)
      assert {:ok, b} = Deduplication.key(second)
      assert a.strategy == :distinct
      assert b.strategy == :distinct
      assert a.dedup_key != b.dedup_key

      assert {:ok, :new, stored_a} = Deduplication.record(first)
      assert {:ok, :new, stored_b} = Deduplication.record(second)
      assert stored_a.id != stored_b.id
      assert stored_a.raw_body_hash == stored_b.raw_body_hash
    end
  end

  describe "the other accepted classes" do
    test "interactions use trigger id plus action identity and ignore source_id", %{
      installation_id: installation_id
    } do
      base = %{
        installation_id: installation_id,
        class: "interaction",
        type: "button",
        provider_id: "trigger-1",
        action_identity: "on-approve",
        raw_body: "click"
      }

      assert {:ok, first} = Deduplication.key(Map.put(base, :source_id, "message-1"))
      assert {:ok, second} = Deduplication.key(Map.put(base, :source_id, "message-2"))
      assert first.strategy == :interaction_identity
      assert first.dedup_key == second.dedup_key

      assert {:ok, other_action} =
               Deduplication.key(Map.put(base, :action_identity, "on-reject"))

      assert other_action.dedup_key != first.dedup_key
    end

    test "lifecycle keys include the provider event id and terminal type", %{
      installation_id: installation_id
    } do
      base = %{
        installation_id: installation_id,
        class: "lifecycle",
        type: "APP_UNINSTALLED",
        provider_id: "life-1",
        workspace_id: "ws-1",
        terminal_state: "APP_UNINSTALLED",
        raw_body: "gone"
      }

      assert {:ok, first} = Deduplication.key(base)
      assert {:ok, again} = Deduplication.key(base)
      assert first.strategy == :lifecycle
      assert first.dedup_key == again.dedup_key

      assert {:ok, other_terminal} =
               Deduplication.key(Map.put(base, :type, "APP_UNAUTHORIZED"))

      assert other_terminal.dedup_key != first.dedup_key
    end

    test "schedules key on schedule id plus the scheduled instant", %{
      installation_id: installation_id
    } do
      at = ~U[2026-03-01 09:00:00.000000Z]

      request = %{
        installation_id: installation_id,
        class: "schedule",
        type: "cron",
        schedule_id: "sched-1",
        scheduled_for: at,
        raw_body: "tick"
      }

      assert {:ok, first} = Deduplication.key(request)
      assert {:ok, again} = Deduplication.key(request)
      assert first.strategy == :schedule
      assert first.dedup_key == again.dedup_key

      later = %{request | scheduled_for: DateTime.add(at, 60, :second)}
      assert {:ok, other} = Deduplication.key(later)
      assert other.dedup_key != first.dedup_key
    end

    test "a schedule without identity is refused", %{installation_id: installation_id} do
      assert {:error, %Error{class: :validation, code: :missing_schedule_identity}} =
               Deduplication.key(%{
                 installation_id: installation_id,
                 class: "schedule",
                 type: "cron",
                 raw_body: "tick"
               })
    end

    test "manual runs collapse on a supplied request id and otherwise stay distinct", %{
      installation_id: installation_id
    } do
      supplied = %{
        installation_id: installation_id,
        class: "manual",
        type: "browser_run",
        request_id: "req-1",
        raw_body: "{}"
      }

      assert {:ok, first} = Deduplication.key(supplied)
      assert {:ok, again} = Deduplication.key(supplied)
      assert first.strategy == :manual
      assert first.dedup_key == again.dedup_key

      generated = %{supplied | request_id: nil}
      assert {:ok, a} = Deduplication.key(generated)
      assert {:ok, b} = Deduplication.key(generated)
      assert a.strategy == :distinct
      assert a.dedup_key != b.dedup_key
    end
  end

  describe "docs" do
    test "fallback uncertainty is written down without an exactly-once claim" do
      docs =
        File.read!(Path.expand("../../../docs/architecture/delivery_semantics.md", __DIR__))

      assert docs =~ "at-least-once"
      assert docs =~ "does not claim exactly-once"
      assert docs =~ "900 seconds"
      assert docs =~ "integrity_anomaly"
      assert docs =~ "PR-01"
    end
  end

  defp event_request(installation_id, attrs) do
    Map.merge(
      %{
        installation_id: installation_id,
        class: "event",
        type: "NEW_MESSAGE",
        provider_id: "RID-1",
        raw_body: "body",
        signature: "sig",
        received_at: @received_at
      },
      attrs
    )
  end

  defp webhook_request(installation_id, attrs) do
    Map.merge(
      %{
        installation_id: installation_id,
        class: "webhook",
        type: "inbound",
        endpoint_id: "endpoint-1",
        raw_body: "payload",
        received_at: @received_at
      },
      attrs
    )
  end

  defp attach_telemetry do
    handler = "dedup-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [
          Deduplication.telemetry_event() ++ [:key],
          Deduplication.telemetry_event() ++ [:integrity_anomaly]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end

defmodule PumbleAutomation.Ingress.DeduplicationRaceTest do
  @moduledoc """
  Several callbacks inserting the same derived key at once.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Ingress.Deduplication
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo

  @writers 6

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "exactly one writer wins a concurrent duplicate insert" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    request = %{
      installation_id: installation.id,
      class: "event",
      type: "NEW_MESSAGE",
      provider_id: "race-#{System.unique_integer([:positive])}",
      raw_body: "same-bytes",
      signature: "sig",
      received_at: ~U[2026-01-01 00:00:00.000000Z]
    }

    outcomes =
      1..@writers
      |> Task.async_stream(
        fn _index -> Deduplication.record(request) end,
        max_concurrency: @writers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(outcomes, &match?({:ok, :new, _event}, &1)) == 1
    assert Enum.count(outcomes, &match?({:ok, :duplicate, _event}, &1)) == @writers - 1

    assert {:ok, %Deduplication{dedup_key: dedup_key}} = Deduplication.key(request)

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
