defmodule PumbleAutomation.Installations.MembersTest do
  @moduledoc """
  Role changes, and the session rotation that must follow one.

  A role that changed without ending the sessions it was issued to would leave a
  demoted member holding editor authority until their idle window expired, so
  every test here checks the sessions as well as the row.
  """

  use PumbleAutomation.DataCase, async: true

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Installations.Members
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope

  describe "update_role/4" do
    test "an owner may promote a member, and the member's sessions end" do
      %{owner: owner, member: member, session: session} = workspace()

      assert {:ok, updated} = Members.update_role(owner, member.id, "editor")

      assert updated.role == "editor"
      assert Repo.get!(UserSession, session.id).revoked_at
      assert audit_count() == 1
    end

    test "a demotion ends the sessions issued under the higher role" do
      %{owner: owner, member: member, session: session} = workspace(role: "editor")

      assert {:ok, updated} = Members.update_role(owner, member.id, "viewer")

      assert updated.role == "viewer"
      assert Repo.get!(UserSession, session.id).revoked_at
    end

    test "setting the role a member already has changes and revokes nothing" do
      %{owner: owner, member: member, session: session} = workspace(role: "viewer")

      assert {:ok, updated} = Members.update_role(owner, member.id, "viewer")

      assert updated.role == "viewer"
      refute Repo.get!(UserSession, session.id).revoked_at
      assert audit_count() == 0
    end

    test "an editor may not change a role" do
      %{member: member, session: session} = workspace()
      editor = %Scope{scope_for(member) | role: "editor"}

      assert {:error, error} = Members.update_role(editor, member.id, "owner")
      assert error.class == :permission
      assert error.code == :capability_denied
      assert Repo.get!(WorkspaceMember, member.id).role == "viewer"
      refute Repo.get!(UserSession, session.id).revoked_at
    end

    test "an owner of another workspace gets the not-found answer, not a refusal" do
      %{owner: owner} = workspace()
      stranger = InstallationsFixtures.install(user: "pumble-user-9")

      assert {:error, error} = Members.update_role(owner, stranger.member.id, "viewer")

      missing = Policy.not_found()
      assert error.class == missing.class
      assert error.code == missing.code
      assert error.message == missing.message
      assert Repo.get!(WorkspaceMember, stranger.member.id).role == "owner"
    end

    test "an invalid role is rejected" do
      %{owner: owner, member: member} = workspace()

      assert {:error, error} = Members.update_role(owner, member.id, "superuser")
      assert error.class == :validation
      assert Repo.get!(WorkspaceMember, member.id).role == "viewer"
    end

    test "demoting the last enabled owner is refused" do
      %{owner: owner} = workspace()
      owner_member = Repo.get!(WorkspaceMember, owner.member_id)

      assert {:error, error} = Members.update_role(owner, owner_member.id, "editor")
      assert error.class == :conflict
      assert error.code == :last_owner
      assert error.message == "At least one owner must remain."
      assert Repo.get!(WorkspaceMember, owner_member.id).role == "owner"
    end

    test "an owner may be demoted when another owner remains" do
      %{owner: owner, member: member} = workspace()

      assert {:ok, _} = Members.update_role(owner, member.id, "owner")

      owner_member = Repo.get!(WorkspaceMember, owner.member_id)
      assert {:ok, updated} = Members.update_role(owner, owner_member.id, "editor")
      assert updated.role == "editor"
    end
  end

  # An installation with its owner and a second member holding one session.
  defp workspace(opts \\ []) do
    installed = InstallationsFixtures.install()

    member =
      Repo.insert!(
        WorkspaceMember.changeset(%WorkspaceMember{}, %{
          installation_id: installed.installation.id,
          pumble_user_id: "pumble-user-#{System.unique_integer([:positive])}",
          role: Keyword.get(opts, :role, "viewer")
        })
      )

    {:ok, issued} = Sessions.issue(Repo, member)

    %{owner: scope_for(installed.member), member: member, session: issued.session}
  end

  defp scope_for(member), do: Scope.new(member)

  defp audit_count do
    Repo.aggregate(from(e in AuditEvent, where: e.action == "admin.member_role_changed"), :count)
  end
end
