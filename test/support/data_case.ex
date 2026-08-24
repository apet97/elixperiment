defmodule PumbleAutomation.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use PumbleAutomation.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias PumbleAutomation.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PumbleAutomation.DataCase
    end
  end

  setup tags do
    PumbleAutomation.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(PumbleAutomation.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  EXPLAIN with sequential scans disabled so a tiny fixture still uses indexes.

  PostgreSQL will seq-scan a handful of rows even when the right index exists.
  Named indexes are asserted from `pg_indexes`. Nested anti-joins on tiny
  related tables may still seq-scan; this helper only asks whether some
  index access method appears in the plan.
  """
  def explain_index_plan(query, opts \\ []) do
    PumbleAutomation.Repo.query!("SET LOCAL enable_seqscan = off")
    PumbleAutomation.Repo.explain(:all, query, opts)
  end

  @doc "True when the plan uses an index access method for some relation."
  def index_backed?(plan) when is_binary(plan) do
    String.contains?(plan, "Index Scan") or
      String.contains?(plan, "Index Only Scan") or
      String.contains?(plan, "Bitmap Index Scan") or
      String.contains?(plan, "Bitmap Heap Scan")
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
