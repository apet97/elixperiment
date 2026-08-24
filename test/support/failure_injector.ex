defmodule PumbleAutomation.FailureInjector do
  @moduledoc """
  Arms named crash windows for the failure-injection suite.

  This module is compiled only from `test/support`. Production
  `FailureInjection.crash/1` is a compile-time no-op and never references it.

  Arms are keyed by `{boundary, owner_pid}` so a test cannot kill an unrelated
  async process that happens to pass the same boundary.
  """

  @boundaries ~w(
    before_claim_commit
    after_claim
    before_network_write
    after_write_timeout
    before_finalize
    after_finalize_before_job_return
    before_next_job_insert
    approval_decision
    schedule_dispatch
  )a

  @table :pumble_automation_failure_injector

  @type action :: :kill | :raise | (-> term())

  @doc "Creates the shared table. Called once from `test/test_helper.exs`."
  @spec install!() :: :ok
  def install! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _tid ->
        :ok
    end
  end

  @doc "The named crash windows the engine and workers call."
  @spec boundaries() :: [atom()]
  def boundaries, do: @boundaries

  @doc "Installs `action` at `boundary` for this process and its descendants."
  @spec arm(atom(), action(), keyword()) :: :ok
  def arm(boundary, action, opts \\ []) when boundary in @boundaries do
    install!()

    :ets.insert(
      @table,
      {{boundary, self()},
       %{
         action: action,
         remaining: Keyword.get(opts, :times, 1),
         skip: Keyword.get(opts, :skip, 0)
       }}
    )

    :ok
  end

  @doc "Clears this process's arms, or every arm when given `:all`."
  @spec disarm(atom() | :all) :: :ok
  def disarm(boundary \\ :all)

  def disarm(:all) do
    delete_owned(fn {owned_boundary, owner} ->
      owned_boundary in @boundaries and owner == self()
    end)
  end

  def disarm(boundary) when boundary in @boundaries do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, {boundary, self()})
    end

    :ok
  end

  @doc "Runs the armed action for `boundary`, or returns `:ok` when unarmed."
  @spec maybe_crash(atom()) :: :ok
  def maybe_crash(boundary) when is_atom(boundary) do
    case take(boundary) do
      nil -> :ok
      action -> fire(action)
    end
  end

  defp take(boundary) do
    Enum.find_value(callers(), fn owner ->
      case lookup({boundary, owner}) do
        nil -> nil
        state -> consume({boundary, owner}, state)
      end
    end)
  end

  defp lookup(key) do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      case :ets.lookup(@table, key) do
        [{^key, state}] -> state
        [] -> nil
      end
    end
  end

  defp consume(key, %{skip: skip} = state) when skip > 0 do
    :ets.insert(@table, {key, %{state | skip: skip - 1}})
    nil
  end

  defp consume(_key, %{remaining: :infinity, action: action}) do
    action
  end

  defp consume(key, %{remaining: 1, action: action}) do
    :ets.delete(@table, key)
    action
  end

  defp consume(key, %{remaining: remaining, action: action} = state)
       when is_integer(remaining) and remaining > 1 do
    :ets.insert(@table, {key, %{state | remaining: remaining - 1}})
    action
  end

  defp consume(_key, _state), do: nil

  defp callers do
    [self() | Enum.filter(ancestors() ++ process_callers(), &is_pid/1)]
  end

  defp ancestors do
    dictionary_pids(:"$ancestors")
  end

  defp process_callers do
    dictionary_pids(:"$callers")
  end

  defp dictionary_pids(key) do
    case Process.info(self(), :dictionary) do
      {:dictionary, dictionary} -> List.wrap(Keyword.get(dictionary, key, []))
      _other -> []
    end
  end

  defp fire(:kill), do: Process.exit(self(), :kill)
  defp fire(:raise), do: raise("failure injector")
  defp fire(fun) when is_function(fun, 0), do: fun.()

  defp delete_owned(match?) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _tid -> Enum.each(:ets.tab2list(@table), &delete_if_owned(&1, match?))
    end
  end

  defp delete_if_owned({key, _state}, match?) do
    if match?.(key), do: :ets.delete(@table, key)
    :ok
  end

  defp delete_if_owned(_other, _match?), do: :ok
end
