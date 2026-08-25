defmodule PumbleAutomation.Executions.Context do
  @moduledoc """
  The JSON-like tree a runtime path may read.

  An execution row holds two maps: `:trigger_snapshot` (what started the
  run) and `:context` (accumulated step output plus a small amount of
  execution metadata). This module projects those maps into the five roots
  The expression roots are `trigger`, `steps`, `execution`, `workspace`,
  `actor` — and nothing else.

  ## Allowlist

  Credentials, tenant structs, and process state are not roots. Secrets
  are resolved by the owning action, never placed here. Under `execution`,
  `workspace`, and `actor` only documented keys survive:

    * `execution.id`, `execution.run_mode`
    * `workspace.id`
    * `actor.id`

  `steps.<node_id>` keeps only `output`. Extra keys that rode along on a
  stored map are dropped.

  ## JSON values only

  Structs, PIDs, functions, and other non-JSON terms are stripped while
  the tree is built, so a later resolver cannot discover them by walking.
  """

  alias PumbleAutomation.Executions.Execution

  @execution_keys ~w(id run_mode)
  @workspace_keys ~w(id)
  @actor_keys ~w(id)

  @doc """
  Builds the resolution tree from a claim snapshot or an execution row.

  Unknown shapes produce an empty documented tree rather than raising.
  """
  @spec tree(term()) :: map()
  def tree(%Execution{} = execution) do
    tree(%{context: execution.context, trigger_snapshot: execution.trigger_snapshot})
  end

  def tree(%{context: context, trigger_snapshot: trigger})
      when is_map(context) and is_map(trigger) do
    %{
      "trigger" => json_map(trigger),
      "steps" => steps(Map.get(context, "steps", %{})),
      "execution" => take(Map.get(context, "execution", %{}), @execution_keys),
      "workspace" => take(Map.get(context, "workspace", %{}), @workspace_keys),
      "actor" => take(Map.get(context, "actor", %{}), @actor_keys)
    }
  end

  def tree(_other), do: tree(%{context: %{}, trigger_snapshot: %{}})

  defp steps(value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, %{}, fn
      {id, step}, acc when is_binary(id) ->
        Map.put(acc, id, %{"output" => output(step)})

      {_id, _step}, acc ->
        acc
    end)
  end

  defp steps(_value), do: %{}

  defp output(%{"output" => value}), do: kept_or(json_value(value), %{})
  defp output(_step), do: %{}

  defp take(value, keys) when is_map(value) and not is_struct(value) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(value, key) do
        {:ok, inner} -> put_kept(acc, key, json_value(inner))
        :error -> acc
      end
    end)
  end

  defp take(_value, _keys), do: %{}

  defp json_map(value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, %{}, fn
      {key, inner}, acc when is_binary(key) -> put_kept(acc, key, json_value(inner))
      {_key, _inner}, acc -> acc
    end)
  end

  defp json_map(_value), do: %{}

  defp put_kept(acc, _key, :drop), do: acc
  defp put_kept(acc, key, kept), do: Map.put(acc, key, kept)

  defp kept_or(:drop, fallback), do: fallback
  defp kept_or(kept, _fallback), do: kept

  defp json_value(value) when is_binary(value), do: value
  defp json_value(value) when is_integer(value), do: value
  defp json_value(value) when is_float(value), do: value
  defp json_value(value) when is_boolean(value), do: value
  defp json_value(nil), do: nil
  defp json_value(value) when is_list(value), do: json_list(value)
  defp json_value(value) when is_map(value) and not is_struct(value), do: json_map(value)
  defp json_value(_value), do: :drop

  defp json_list(values), do: Enum.map(values, &kept_or(json_value(&1), nil))
end
