defmodule PumbleAutomation.Barrier do
  @moduledoc """
  A ready/go latch so two processes enter a critical section together.

  Racers call `ready/1` then wait. The parent calls `release/1` after every
  racer has checked in, then awaits the tasks. There is no sleep: the handshake
  is messages, and a racer that never checks in fails the test.
  """

  import ExUnit.Assertions

  @ready_timeout 5_000
  @await_timeout 30_000

  @doc "Tells `parent` this process is waiting, then blocks until `:go`."
  @spec ready(pid(), timeout()) :: :ok
  def ready(parent, timeout \\ @ready_timeout) when is_pid(parent) do
    send(parent, {:ready, self()})

    receive do
      :go -> :ok
    after
      timeout -> flunk("barrier never released")
    end
  end

  @doc "Waits for `count` racers, then releases them in one wave."
  @spec release(pos_integer(), timeout()) :: [pid()]
  def release(count, timeout \\ @ready_timeout) when is_integer(count) and count > 0 do
    pids = collect_ready(count, timeout, [])
    Enum.each(pids, &send(&1, :go))
    pids
  end

  @doc """
  Runs `funs` after they have all reached the barrier.

  Returns the list of each function's result, in the same order as `funs`.
  """
  @spec race([(-> result)], keyword()) :: [result] when result: var
  def race(funs, opts \\ []) when is_list(funs) and funs != [] do
    timeout = Keyword.get(opts, :timeout, @await_timeout)
    ready_timeout = Keyword.get(opts, :ready_timeout, @ready_timeout)
    parent = self()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          ready(parent, ready_timeout)
          fun.()
        end)
      end)

    _pids = release(length(funs), ready_timeout)
    Enum.map(tasks, &Task.await(&1, timeout))
  end

  defp collect_ready(0, _timeout, acc), do: Enum.reverse(acc)

  defp collect_ready(remaining, timeout, acc) do
    receive do
      {:ready, pid} when is_pid(pid) ->
        collect_ready(remaining - 1, timeout, [pid | acc])
    after
      timeout ->
        flunk("racer did not reach the barrier (#{remaining} still waiting)")
    end
  end
end
