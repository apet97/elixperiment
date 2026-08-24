defmodule PumbleAutomation.FailureWindowsCase do
  @moduledoc """
  Committed crash-window tests. The sandbox cannot survive `Process.exit(:kill)`
  inside a transaction, so these tests use the same auto-mode path as the race
  suite and erase the tenant on exit.
  """

  use ExUnit.CaseTemplate
  import ExUnit.Assertions

  using do
    quote do
      use PumbleAutomation.DatabaseRaceCase, async: false

      alias PumbleAutomation.FailureInjector
      alias PumbleAutomation.FailureWindowsCase

      setup do
        FailureInjector.disarm()
        on_exit(fn -> FailureInjector.disarm() end)
        :ok
      end
    end
  end

  @doc "Runs `fun` in a throwaway process and asserts it is killed."
  @spec crash_through((-> term())) :: :ok
  def crash_through(fun) when is_function(fun, 0) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:started, self()})
        fun.()
      end)

    ref = Process.monitor(pid)
    assert_receive {:started, ^pid}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    {:ok, _} = PumbleAutomation.Repo.query("SELECT 1")
    :ok
  end
end
