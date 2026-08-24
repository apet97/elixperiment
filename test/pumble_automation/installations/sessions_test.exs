defmodule PumbleAutomation.Installations.SessionsTest do
  @moduledoc """
  Issuing, rotating, and revoking browser sessions.

  The fixation tests are the point of the file: a token that survived a rotation
  would be a session an attacker planted and the application then upgraded.
  """

  use PumbleAutomation.DataCase, async: true

  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.InstallationsFixtures

  describe "issue/3" do
    test "returns the token once and stores only its digest" do
      %{member: member} = InstallationsFixtures.install()

      {:ok, %{session: session, token: token}} = Sessions.issue(Repo, member)

      assert byte_size(token) >= 43
      assert Repo.get!(UserSession, session.id).token_digest == UserSession.digest(token)
      refute token in Map.values(Map.from_struct(Repo.get!(UserSession, session.id)))
    end

    test "two sessions never share a token" do
      %{member: member} = InstallationsFixtures.install()

      {:ok, first} = Sessions.issue(Repo, member)
      {:ok, second} = Sessions.issue(Repo, member)

      refute first.token == second.token
    end

    test "sets both expiries, the idle one no later than the absolute one" do
      %{member: member} = InstallationsFixtures.install()

      {:ok, %{session: session}} = Sessions.issue(Repo, member)

      assert DateTime.compare(session.idle_expires_at, session.absolute_expires_at) != :gt
    end
  end

  describe "rotate/3" do
    test "issues a new token and makes the old one unusable in the same breath" do
      %{member: member} = InstallationsFixtures.install()
      {:ok, %{session: old, token: old_token}} = Sessions.issue(Repo, member)

      {:ok, %{session: new, token: new_token}} = Sessions.rotate(Repo, old)

      refute new.id == old.id
      refute new_token == old_token
      assert Repo.get!(UserSession, old.id).revoked_at
      assert Sessions.fetch(old_token, DateTime.utc_now()) == :error
      assert {:ok, resolved} = Sessions.fetch(new_token, DateTime.utc_now())
      assert resolved.member.id == member.id
    end

    test "the new session belongs to the same member" do
      %{member: member} = InstallationsFixtures.install()
      {:ok, %{session: old}} = Sessions.issue(Repo, member)

      {:ok, %{session: new}} = Sessions.rotate(Repo, old)

      assert new.workspace_member_id == member.id
    end
  end

  describe "revoking" do
    test "revoke/3 ends one session and leaves the member's others alone" do
      %{member: member} = InstallationsFixtures.install()
      {:ok, first} = Sessions.issue(Repo, member)
      {:ok, second} = Sessions.issue(Repo, member)

      assert Sessions.revoke(Repo, first.session, DateTime.utc_now()) == 1

      assert Repo.get!(UserSession, first.session.id).revoked_at
      refute Repo.get!(UserSession, second.session.id).revoked_at
    end

    test "revoking an already revoked session changes nothing" do
      %{member: member} = InstallationsFixtures.install()
      {:ok, issued} = Sessions.issue(Repo, member)
      now = DateTime.utc_now()

      assert Sessions.revoke(Repo, issued.session, now) == 1
      assert Sessions.revoke(Repo, issued.session, DateTime.utc_now()) == 0
      assert Repo.get!(UserSession, issued.session.id).revoked_at == now
    end

    test "revoke_all_for_installation/3 stops at the tenant boundary" do
      %{member: member} = InstallationsFixtures.install()
      stranger = InstallationsFixtures.install(user: "pumble-user-2")
      {:ok, mine} = Sessions.issue(Repo, member)

      Sessions.revoke_all_for_installation(Repo, member.installation_id, DateTime.utc_now())

      assert Repo.get!(UserSession, mine.session.id).revoked_at
      refute Repo.get!(UserSession, stranger.session.id).revoked_at
    end
  end
end
