defmodule PumbleAutomation.DatabaseRaceCase do
  @moduledoc """
  Unsandboxed setup for tests that race two real PostgreSQL connections.

  The sandbox cannot express SKIP LOCKED or two lockers of the same row, so
  these tests commit. Each test uses a unique workspace and erases it on exit.
  """

  use ExUnit.CaseTemplate

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo

  using do
    quote do
      use Oban.Testing, repo: PumbleAutomation.Repo

      import Ecto.Query, only: [from: 2]
      import PumbleAutomation.TenantAssertions
      import PumbleAutomation.WorkflowsFixtures

      alias PumbleAutomation.Barrier
      alias PumbleAutomation.DatabaseRaceCase
      alias PumbleAutomation.InstallationsFixtures
      alias PumbleAutomation.Repo
      alias PumbleAutomation.Scope
    end
  end

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  @doc "Deletes Oban jobs then the committed installation tree."
  @spec cleanup!(String.t()) :: :ok
  def cleanup!(installation_id) when is_binary(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
    :ok
  end

  @doc "Advance-job args the engine workers claim with."
  @spec job_args(Execution.t()) :: map()
  def job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end
end
