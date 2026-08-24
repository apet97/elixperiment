defmodule PumbleAutomation.Integration.IdentityLifecycleRaceTest do
  @moduledoc """
  First-owner, last-owner, uninstall, retention, and dedup races with a
  second-tenant sentinel that must survive.
  """

  use PumbleAutomation.DatabaseRaceCase, async: false

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.ExecutionsFixtures
  alias PumbleAutomation.Ingress.Deduplication
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service, as: Ingress
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Members
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Retention

  test "concurrent OAuth state consumers produce exactly one success" do
    {:ok, token, state} = OauthStates.create("install")
    on_exit(fn -> Repo.delete_all(from o in OauthState, where: o.id == ^state.id) end)

    results = Barrier.race(Enum.map(1..4, fn _index -> fn -> OauthStates.consume(token) end end))

    assert Enum.count(results, &match?({:ok, _state}, &1)) == 1

    errors = for {:error, error} <- results, do: error
    assert length(errors) == 3
    assert Enum.all?(errors, &(&1.code == :oauth_state_unusable))
  end

  test "concurrent first installers produce exactly one owner" do
    workspace = InstallationsFixtures.unique_workspace()

    results =
      Barrier.race(
        Enum.map(1..4, fn index ->
          fn ->
            Service.complete_oauth(
              consumed_state("install"),
              PumbleFake.tokens(%{
                pumble_workspace_id: workspace,
                pumble_user_id: "pumble-user-#{index}-#{System.unique_integer([:positive])}"
              })
            )
          end
        end)
      )

    assert Enum.all?(results, &match?({:ok, _result}, &1))

    installation = Repo.one!(from i in Installation, where: i.pumble_workspace_id == ^workspace)
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    owners =
      Repo.aggregate(
        from(m in WorkspaceMember,
          where: m.installation_id == ^installation.id and m.role == "owner"
        ),
        :count
      )

    assert owners == 1

    assert Repo.aggregate(
             from(m in WorkspaceMember, where: m.installation_id == ^installation.id),
             :count
           ) == 4
  end

  test "concurrent last-owner demotions leave at least one owner" do
    %{installation: installation, member: first} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    other = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(other.installation.id) end)
    sentinel = tenant_snapshot(other.installation.id)

    second = insert_member(installation, "viewer")
    owner_scope = Scope.new(first)
    {:ok, _} = Members.update_role(owner_scope, second.id, "owner")
    second = Repo.get!(WorkspaceMember, second.id)
    first = Repo.get!(WorkspaceMember, first.id)

    results =
      Barrier.race([
        fn -> Members.update_role(Scope.new(first), second.id, "editor") end,
        fn -> Members.update_role(Scope.new(second), first.id, "editor") end
      ])

    oks = for {:ok, _member} <- results, do: true
    conflicts = for {:error, %Error{code: :last_owner}} <- results, do: true

    assert length(oks) == 1
    assert length(conflicts) == 1

    owners =
      Repo.aggregate(
        from(m in WorkspaceMember,
          where:
            m.installation_id == ^installation.id and m.role == "owner" and is_nil(m.disabled_at)
        ),
        :count
      )

    assert owners == 1
    assert_tenant_intact(other.installation.id, sentinel)
  end

  test "concurrent duplicate uninstalls produce one terminal state" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    other = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(other.installation.id) end)
    sentinel = tenant_snapshot(other.installation.id)

    payload =
      %Payload.Event{
        message_type: "APP_EVENT",
        event_type: "APP_UNINSTALLED",
        workspace_id: installation.pumble_workspace_id,
        body: %{
          "id" => "EVT-race-un-#{System.unique_integer([:positive])}",
          "app" => "APP_TEST",
          "workspace" => installation.pumble_workspace_id,
          "installedBy" => "pumble-user-1",
          "botUser" => "bot-user",
          "uninstalledAt" => 1_767_225_600_000
        }
      }

    ctx = %{raw_body: "race-uninstall", signature: "sig"}

    results =
      Barrier.race([
        fn -> Ingress.enqueue_event(payload, ctx) end,
        fn -> Ingress.enqueue_event(payload, ctx) end
      ])

    assert Enum.all?(results, &(&1 == :accepted))

    assert Repo.aggregate(
             from(event in ReceivedEvent, where: event.installation_id == ^installation.id),
             :count
           ) == 1

    assert Repo.get!(Installation, installation.id).status == "uninstalled"
    assert_tenant_intact(other.installation.id, sentinel)
  end

  test "concurrent retention sweeps leave another tenant intact" do
    %{installation: ours} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(ours.id) end)

    %{installation: other} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(other.id) end)

    sentinel_row =
      ExecutionsFixtures.execution(ExecutionsFixtures.version(other.id), %{status: "completed"})

    snapshot = tenant_snapshot(other.id)
    now = DateTime.utc_now()

    results =
      Barrier.race([
        fn -> Retention.sweep(now) end,
        fn -> Retention.sweep(now) end
      ])

    assert Enum.all?(results, &match?({:ok, _counts}, &1))
    assert Repo.get(Execution, sentinel_row.id)
    assert_tenant_intact(other.id, snapshot)
  end

  test "exactly one writer wins a concurrent duplicate insert" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

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
      Barrier.race(Enum.map(1..4, fn _index -> fn -> Deduplication.record(request) end end))

    assert Enum.count(outcomes, &match?({:ok, :new, _event}, &1)) == 1
    assert Enum.count(outcomes, &match?({:ok, :duplicate, _event}, &1)) == 3

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

  defp consumed_state(intent) do
    {:ok, token, _state} = OauthStates.create(intent)
    {:ok, consumed} = OauthStates.consume(token)
    consumed
  end

  defp insert_member(installation, role) do
    %WorkspaceMember{}
    |> WorkspaceMember.changeset(%{
      installation_id: installation.id,
      pumble_user_id: "pumble-user-#{System.unique_integer([:positive])}",
      role: role
    })
    |> Repo.insert!()
  end
end
