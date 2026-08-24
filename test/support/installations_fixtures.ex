defmodule PumbleAutomation.InstallationsFixtures do
  @moduledoc """
  Installed workspaces for tests that need one but are not about installing.

  Every fixture goes through `PumbleAutomation.Installations.Service.complete_oauth/3`
  rather than inserting rows, so a test that depends on an installation depends
  on the real one, and a change to what an install writes cannot leave these
  tests passing against a shape that no longer exists.

  Each fixture takes a workspace id of its own. `complete_oauth/3` holds a
  PostgreSQL advisory lock keyed on that id, and the test sandbox never commits,
  so two async tests sharing a workspace id would serialize on each other and
  can deadlock.
  """

  import Ecto.Query, only: [from: 1, from: 2]

  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Repo

  @doc """
  Installs a workspace and returns `Service.complete_oauth/3`'s result.

  Options: `:workspace`, `:user`, `:role`, `:tokens`. The role is applied after
  the install, because the first person to install is always the owner.
  `:tokens` overrides fields of the exchange response, which is how a test gives
  two workspaces two different credentials.
  """
  @spec install(keyword()) :: map()
  def install(opts \\ []) do
    workspace = Keyword.get_lazy(opts, :workspace, &unique_workspace/0)
    user = Keyword.get(opts, :user, "pumble-user-1")

    {:ok, token, _state} = OauthStates.create("install")
    {:ok, state} = OauthStates.consume(token)

    {:ok, result} =
      Service.complete_oauth(
        state,
        PumbleFake.tokens(
          Map.merge(
            %{pumble_workspace_id: workspace, pumble_user_id: user},
            opts |> Keyword.get(:tokens, %{}) |> Map.new()
          )
        )
      )

    case Keyword.get(opts, :role) do
      nil -> result
      role -> %{result | member: set_role(result.member, role)}
    end
  end

  @doc "A workspace id no other test uses."
  @spec unique_workspace() :: String.t()
  def unique_workspace, do: "pumble-workspace-#{System.unique_integer([:positive])}"

  @doc "Sets a member's role directly, for tests about what a role may do."
  @spec set_role(WorkspaceMember.t(), String.t()) :: WorkspaceMember.t()
  def set_role(%WorkspaceMember{} = member, role) do
    member
    |> WorkspaceMember.changeset(%{role: role})
    |> Repo.update!()
  end

  @doc """
  Deletes everything one `install/1` committed, for a test that ran unsandboxed.

  Most tests never need this: the sandbox rolls every write back. A test that
  must really commit — a race that one connection cannot observe from another —
  has to clean up after itself, and a leftover installation breaks every later
  test that counts them.

  Two tables do not cascade from `installations` and are removed by hand:
  `audit_events`, which outlives the tenant it describes by design, and
  `oauth_states`, which is written before an installation exists and only ever
  points back at one. Deleting every committed `oauth_states` row is safe here
  precisely because a sandboxed test commits none.
  """
  @spec erase!(String.t()) :: :ok
  def erase!(installation_id) do
    id = Ecto.UUID.dump!(installation_id)

    Repo.delete_all(from a in "audit_events", where: a.installation_id == ^id)
    Repo.delete_all(from(o in "oauth_states"))
    Repo.delete_all(from i in "installations", where: i.id == ^id)

    :ok
  end
end
