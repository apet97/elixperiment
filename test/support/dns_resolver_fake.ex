defmodule PumbleAutomation.DnsResolverFake do
  @moduledoc """
  Controllable A/AAAA answers for HTTP security tests.

  Lookups never leave the process and never use the OS resolver. A host may
  return a fixed set, a sequence of sets (rebinding), or an error. Tests inject
  `fun/1` into URL policy and the HTTP node.
  """

  use Agent

  @type address :: :inet.ip_address()
  @type answer :: {:ok, [address()]} | {:error, atom()} | {:sequence, [[address()]]}

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, {__MODULE__, System.unique_integer([:positive])}),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) when is_list(opts) do
    answers = opts |> Keyword.get(:answers, %{}) |> normalize()
    Agent.start_link(fn -> %{answers: answers, lookups: []} end)
  end

  @doc "A resolver of the `UrlPolicy` injectable shape."
  @spec fun(pid()) :: (String.t() -> {:ok, [address()]} | {:error, atom()})
  def fun(agent) when is_pid(agent) do
    fn hostname -> lookup(agent, hostname) end
  end

  @doc "Resolves `hostname` and records that the lookup happened."
  @spec lookup(pid(), String.t()) :: {:ok, [address()]} | {:error, atom()}
  def lookup(agent, hostname) when is_pid(agent) and is_binary(hostname) do
    host = String.downcase(hostname)

    Agent.get_and_update(agent, fn state ->
      take_answer(%{state | lookups: state.lookups ++ [host]}, host)
    end)
  end

  defp take_answer(state, host) do
    stored = Map.get(state.answers, host, Map.get(state.answers, :default, {:error, :nxdomain}))

    case stored do
      {:ok, addresses} ->
        {{:ok, addresses}, state}

      {:error, reason} ->
        {{:error, reason}, state}

      {:sequence, [next | rest]} ->
        answers = Map.put(state.answers, host, remaining_sequence(rest, next))
        {{:ok, next}, %{state | answers: answers}}

      {:sequence, []} ->
        {{:error, :nxdomain}, state}
    end
  end

  defp remaining_sequence([], last), do: {:ok, last}
  defp remaining_sequence(rest, _last), do: {:sequence, rest}

  @doc "Replaces the answer for `hostname` with a fixed address set."
  @spec put(pid(), String.t(), [address()]) :: :ok
  def put(agent, hostname, addresses)
      when is_pid(agent) and is_binary(hostname) and is_list(addresses) do
    Agent.update(agent, fn state ->
      %{state | answers: Map.put(state.answers, String.downcase(hostname), {:ok, addresses})}
    end)
  end

  @doc "The next lookups for `hostname` return each set in order."
  @spec sequence(pid(), String.t(), [[address()]]) :: :ok
  def sequence(agent, hostname, sets)
      when is_pid(agent) and is_binary(hostname) and is_list(sets) do
    Agent.update(agent, fn state ->
      %{state | answers: Map.put(state.answers, String.downcase(hostname), {:sequence, sets})}
    end)
  end

  @doc "Hostnames resolved so far, in order, lowercased."
  @spec lookups(pid()) :: [String.t()]
  def lookups(agent), do: Agent.get(agent, & &1.lookups)

  @doc "How many times `hostname` has been resolved."
  @spec lookup_count(pid(), String.t()) :: non_neg_integer()
  def lookup_count(agent, hostname) when is_binary(hostname) do
    host = String.downcase(hostname)
    Agent.get(agent, fn state -> Enum.count(state.lookups, &(&1 == host)) end)
  end

  defp normalize(answers) when is_map(answers) do
    Map.new(answers, fn {host, answer} -> {normalize_host(host), normalize_answer(answer)} end)
  end

  defp normalize_host(:default), do: :default
  defp normalize_host(host) when is_binary(host), do: String.downcase(host)

  defp normalize_answer({:ok, addresses}) when is_list(addresses), do: {:ok, addresses}
  defp normalize_answer({:error, reason}), do: {:error, reason}
  defp normalize_answer({:sequence, sets}) when is_list(sets), do: {:sequence, sets}
  defp normalize_answer(addresses) when is_list(addresses), do: {:ok, addresses}
end
