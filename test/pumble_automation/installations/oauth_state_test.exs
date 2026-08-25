defmodule PumbleAutomation.Installations.OauthStateTest do
  @moduledoc """
  The OAuth state service: creation, one-time consumption, expiry, and the
  closed set of return destinations.

  ## Concurrency boundary

  These sandboxed tests prove one-time behavior on one connection. The
  multi-connection race is covered by `IdentityLifecycleRaceTest`, where writes
  commit and PostgreSQL can exercise the atomic consume statement concurrently.
  """

  use PumbleAutomation.DataCase, async: true

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.ReturnPaths

  describe "create/2" do
    test "returns a token the caller can present and stores only its digest" do
      {:ok, token, state} = OauthStates.create("install")

      assert byte_size(token) >= 43, "expected at least 256 bits, url-safe encoded"
      assert state.state_digest == OauthState.digest(token)
      assert byte_size(state.state_digest) == 32
      refute state.state_digest == token
    end

    test "the token is url-safe, so it survives a query string unchanged" do
      {:ok, token, _state} = OauthStates.create("install")

      assert token == URI.encode_www_form(token)
      assert {:ok, _bytes} = Base.url_decode64(token, padding: false)
    end

    test "no column anywhere holds the raw token" do
      {:ok, token, state} = OauthStates.create("install")

      persisted = Repo.get!(OauthState, state.id)

      refute persisted
             |> Map.from_struct()
             |> Map.values()
             |> Enum.any?(fn value -> value == token end)
    end

    test "two states never collide" do
      tokens = for _ <- 1..50, do: elem(OauthStates.create("install"), 1)

      assert length(Enum.uniq(tokens)) == 50
    end

    test "expires ten minutes out" do
      now = DateTime.utc_now()
      {:ok, _token, state} = OauthStates.create("install", now: now)

      assert DateTime.diff(state.expires_at, now, :second) == 600
      assert OauthStates.ttl_seconds() == 600
    end

    test "records the intent, the installation hint, and the request metadata" do
      installation = installation_fixture()

      {:ok, _token, state} =
        OauthStates.create("signin",
          installation_id: installation.id,
          request_metadata: %{"source" => "browser"}
        )

      assert state.intent == "signin"
      assert state.installation_id == installation.id
      assert state.request_metadata == %{"source" => "browser"}
      assert is_nil(state.consumed_at)
    end

    test "accepts every documented intent and refuses anything else" do
      for intent <- OauthState.intents() do
        assert {:ok, _token, state} = OauthStates.create(intent)
        assert state.intent == intent
      end

      assert {:error, error} = OauthStates.create("escalate")
      assert error.code == :unknown_oauth_intent
      assert error.class == :validation
    end

    test "defaults the return destination rather than leaving it blank" do
      {:ok, _token, state} = OauthStates.create("install")

      assert state.return_path_key == ReturnPaths.default_key()
    end
  end

  describe "create/2 and open redirects" do
    test "refuses an absolute URL as a return destination" do
      before_count = Repo.aggregate(OauthState, :count)

      for hostile <- [
            "https://evil.test/steal",
            "//evil.test",
            "http://evil.test",
            "javascript:alert(1)",
            "/../../etc/passwd",
            "\\\\evil.test"
          ] do
        assert {:error, error} = OauthStates.create("install", return_path_key: hostile)
        assert error.code == :unknown_return_path, "accepted #{inspect(hostile)}"
      end

      assert Repo.aggregate(OauthState, :count) == before_count
    end

    test "refuses an unknown key, so a bad key never becomes a stored row" do
      before_count = Repo.aggregate(OauthState, :count)

      assert {:error, error} = OauthStates.create("install", return_path_key: "admin_console")
      assert error.code == :unknown_return_path
      assert Repo.aggregate(OauthState, :count) == before_count
    end

    test "every destination in the table is a local path" do
      for key <- ReturnPaths.keys() do
        {:ok, path} = ReturnPaths.fetch(key)

        assert ReturnPaths.local_path?(path), "#{key} resolves to a non-local path"
        assert String.starts_with?(path, "/")
        refute String.starts_with?(path, "//")
      end
    end

    test "the failure destination is local too" do
      assert ReturnPaths.local_path?(ReturnPaths.failure_path())
    end
  end

  describe "consume/2" do
    test "returns the row once and refuses the same token afterwards" do
      {:ok, token, created} = OauthStates.create("install")

      assert {:ok, consumed} = OauthStates.consume(token)
      assert consumed.id == created.id
      assert consumed.intent == "install"
      refute is_nil(consumed.consumed_at)

      assert {:error, error} = OauthStates.consume(token)
      assert error.code == :oauth_state_unusable
    end

    test "marks the row consumed in the database, not only in the returned struct" do
      {:ok, token, state} = OauthStates.create("install")

      {:ok, _consumed} = OauthStates.consume(token)

      refute is_nil(Repo.get!(OauthState, state.id).consumed_at)
    end

    test "exactly one of many repeated consumers wins" do
      {:ok, token, _state} = OauthStates.create("install")

      results = Enum.map(1..25, fn _index -> OauthStates.consume(token) end)

      assert Enum.count(results, &match?({:ok, _state}, &1)) == 1
      assert Enum.count(results, &match?({:error, _error}, &1)) == 24
    end

    test "an expired state is refused and is not consumed" do
      past = DateTime.add(DateTime.utc_now(), -3_600, :second)
      {:ok, token, state} = OauthStates.create("install", now: past)

      assert {:error, error} = OauthStates.consume(token)
      assert error.code == :oauth_state_unusable

      assert is_nil(Repo.get!(OauthState, state.id).consumed_at),
             "an expired state must not be marked consumed"
    end

    test "a state one second from expiry still works" do
      now = DateTime.utc_now()
      {:ok, token, _state} = OauthStates.create("install", now: now)

      just_before = DateTime.add(now, OauthStates.ttl_seconds() - 1, :second)

      assert {:ok, _state} = OauthStates.consume(token, now: just_before)
    end

    test "an unknown token is refused with the same answer as an expired one" do
      unknown = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert {:error, unknown_error} = OauthStates.consume(unknown)

      {:ok, expired_token, _state} =
        OauthStates.create("install", now: DateTime.add(DateTime.utc_now(), -3_600, :second))

      assert {:error, expired_error} = OauthStates.consume(expired_token)

      assert unknown_error.code == expired_error.code
      assert unknown_error.message == expired_error.message
    end

    test "refuses a token that is not a non-empty binary" do
      for bad <- [nil, "", 42, %{}, [], :token] do
        assert {:error, error} = OauthStates.consume(bad)
        assert error.code == :oauth_state_unusable
      end
    end

    test "the intent comes off the row and cannot be supplied by the callback" do
      {:ok, token, _state} = OauthStates.create("signin")

      assert {:ok, consumed} = OauthStates.consume(token)
      assert consumed.intent == "signin"

      # There is no arity that accepts an expected intent: the only way to learn
      # what a flow may do is to read the row that was written before the
      # redirect.
      refute function_exported?(OauthStates, :consume, 3)
    end

    test "consuming one state leaves every other state alone" do
      {:ok, first_token, first} = OauthStates.create("install")
      {:ok, _second_token, second} = OauthStates.create("signin")

      {:ok, _consumed} = OauthStates.consume(first_token)

      refute is_nil(Repo.get!(OauthState, first.id).consumed_at)
      assert is_nil(Repo.get!(OauthState, second.id).consumed_at)
    end
  end

  describe "delete_expired/1" do
    test "deletes states past the cutoff and keeps live ones" do
      now = DateTime.utc_now()

      {:ok, _token, expired} =
        OauthStates.create("install", now: DateTime.add(now, -3_600, :second))

      {:ok, _token, live} = OauthStates.create("install", now: now)

      assert {:ok, 1} = OauthStates.delete_expired()

      refute Repo.get(OauthState, expired.id)
      assert Repo.get(OauthState, live.id)
    end

    test "deletes consumed states once they are past the cutoff" do
      past = DateTime.add(DateTime.utc_now(), -3_600, :second)
      {:ok, token, state} = OauthStates.create("install", now: past)

      _ = OauthStates.consume(token, now: past)

      assert {:ok, 1} = OauthStates.delete_expired()
      refute Repo.get(OauthState, state.id)
    end

    test "an explicit cutoff keeps a grace window" do
      now = DateTime.utc_now()

      {:ok, _token, recent} =
        OauthStates.create("install", now: DateTime.add(now, -700, :second))

      cutoff = DateTime.add(now, -3_600, :second)

      assert {:ok, 0} = OauthStates.delete_expired(before: cutoff)
      assert Repo.get(OauthState, recent.id)
    end

    test "reports zero when there is nothing to delete" do
      assert {:ok, 0} = OauthStates.delete_expired()
    end
  end

  defp installation_fixture do
    Repo.insert!(
      Installation.changeset(%Installation{}, %{
        pumble_workspace_id: "workspace-#{System.unique_integer([:positive])}",
        status: "active"
      })
    )
  end
end
