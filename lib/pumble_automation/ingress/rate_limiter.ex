defmodule PumbleAutomation.Ingress.RateLimiter do
  @moduledoc """
  Per-node minute buckets for internet-facing and expensive actions.

  Storage is an ETS table owned by this process. The deployment is a small
  Phoenix cluster without Redis. Each node therefore enforces
  the full configured rate; the cluster-wide rate is at most N times the
  limit. That is conservative per node and does not require a shared cache.

  Internet-facing `check/2` fails closed when the table is missing: a limiter
  outage becomes 429 rather than an amplifier. Restarting this process empties
  the table; counts do not survive a node restart.

  ## Dimensions

  Callers pass an opaque key. Documented uses:

    * `{:callback_failure, ip_digest}` — failed Pumble signatures
    * `{:webhook_auth_failure, ip_digest}` — failed generic webhook credentials
    * `{:webhook_endpoint, endpoint_id}` / `{:webhook_ip, endpoint_id, ip_digest}`
    * `{:manual_run, installation_id}`
    * `{:expensive_ui, installation_id, member_id, action}`

  IP digests are SHA-256 of the already-resolved `conn.remote_ip`. Forwarding
  headers are not read here; `PumbleAutomationWeb.Plugs.TrustedProxies` is the
  only place those headers may rewrite the peer, and only for configured
  proxies.

  ## Retry

  A refusal is `PumbleAutomation.Error` class `:rate_limited` with
  `retry_after_seconds: 60` in details. HTTP callers send `429` + `Retry-After`.
  """

  use GenServer

  alias PumbleAutomation.Error
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Scope

  @table :pumble_automation_rate_limiter
  @window_seconds 60
  @sweep_ms 60_000

  @type on_error :: :deny | :allow

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @doc "Ensures the table exists. Returns `:error` when this process is down."
  @spec ensure() :: :ok | :error
  def ensure do
    case :ets.whereis(@table) do
      :undefined -> :error
      _tid -> :ok
    end
  end

  @doc "Empties the table. Tests only."
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        true = :ets.delete_all_objects(@table)
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Increments `key` in the current minute and refuses when the count exceeds
  `limit`.

  Options: `:limit` (required), `:on_error` (`:deny` default), `:source`,
  `:installation_id`.
  """
  @spec check(term(), keyword()) :: :ok | {:error, Error.t()}
  def check(key, opts \\ []) when is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)
    on_error = Keyword.get(opts, :on_error, :deny)
    source = Keyword.get(opts, :source, :rate_limited)
    installation_id = Keyword.get(opts, :installation_id)

    case bump({key, window()}) do
      {:ok, count} when count > limit ->
        Limits.record_hit(source, installation_id)
        {:error, rate_error(opts)}

      {:ok, _count} ->
        :ok

      :error ->
        closed_result(on_error, source, installation_id, opts)
    end
  end

  @doc "Whether `key` is already at or over `limit` without incrementing."
  @spec limited?(term(), keyword()) :: boolean()
  def limited?(key, opts \\ []) when is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)
    on_error = Keyword.get(opts, :on_error, :deny)

    case peek({key, window()}) do
      {:ok, count} -> count >= limit
      :error -> on_error == :deny
    end
  end

  @doc "Increments `key` without refusing. Used after a callback failure."
  @spec hit(term(), keyword()) :: :ok
  def hit(key, opts \\ []) when is_list(opts) do
    _ = bump({key, window()})
    :ok
  end

  @doc "Rate-limits an on-demand editor action for one member."
  @spec check_expensive_ui(Scope.t(), atom()) :: :ok | {:error, Error.t()}
  def check_expensive_ui(%Scope{} = scope, action) when is_atom(action) do
    check({:expensive_ui, scope.installation_id, scope.member_id, action},
      limit: Limits.get(:expensive_ui_per_minute),
      source: :expensive_ui,
      installation_id: scope.installation_id
    )
  end

  @doc "Rate-limits a manual run for one installation."
  @spec check_manual_run(Ecto.UUID.t()) :: :ok | {:error, Error.t()}
  def check_manual_run(installation_id) when is_binary(installation_id) do
    check({:manual_run, installation_id},
      limit: Limits.get(:manual_runs_per_minute),
      source: :manual_run,
      installation_id: installation_id
    )
  end

  @doc "SHA-256 of a resolved peer address. Never hashes a forwarding header."
  @spec ip_digest(term()) :: binary()
  def ip_digest(ip), do: :crypto.hash(:sha256, :erlang.term_to_binary(ip))

  defp bump(stored) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      _tid ->
        {:ok, :ets.update_counter(@table, stored, {2, 1}, {stored, 0})}
    end
  rescue
    ArgumentError -> :error
  end

  defp peek(stored) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      _tid ->
        case :ets.lookup(@table, stored) do
          [{^stored, count}] -> {:ok, count}
          [] -> {:ok, 0}
        end
    end
  rescue
    ArgumentError -> :error
  end

  defp closed_result(:allow, _source, _installation_id, _opts), do: :ok

  defp closed_result(:deny, source, installation_id, opts) do
    Limits.record_hit(source, installation_id)
    {:error, rate_error(opts)}
  end

  defp rate_error(opts) do
    Error.new(:rate_limited, Keyword.get(opts, :code, :rate_limited),
      message: Keyword.get(opts, :message, "The rate limit was reached."),
      details: %{retry_after_seconds: @window_seconds}
    )
  end

  defp window, do: div(System.system_time(:second), @window_seconds)

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_ms)
  end

  defp sweep do
    cutoff = window() - 1

    :ets.foldl(
      fn
        {{_key, bucket} = stored, _count}, acc when is_integer(bucket) and bucket < cutoff ->
          :ets.delete(@table, stored)
          acc

        _row, acc ->
          acc
      end,
      :ok,
      @table
    )
  rescue
    ArgumentError -> :ok
  end
end
