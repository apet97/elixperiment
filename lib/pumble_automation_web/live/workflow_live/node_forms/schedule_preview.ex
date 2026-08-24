defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.SchedulePreview do
  @moduledoc """
  Next occurrences and DST copy for the schedule trigger form.

  The calculator is exclusive: each instant is strictly after the reference.
  Spring gaps use the first valid instant after the missing local time.
  Fall overlaps use the earlier occurrence, once.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.ScheduleCalculator

  @count 5

  @dst_policy """
  Missing local times (spring gap) fire at the first valid instant after the
  gap. Ambiguous local times (fall overlap) fire at the earlier occurrence,
  once. Instants are stored as UTC.
  """

  @doc "The DST policy sentence the schedule form shows."
  @spec dst_policy() :: String.t()
  def dst_policy, do: String.trim(@dst_policy)

  @doc "Up to five UTC instants after `reference`, or the calculator error."
  @spec occurrences(ScheduleConfig.t(), DateTime.t()) ::
          {:ok, [DateTime.t()]} | {:error, Error.t()}
  def occurrences(%ScheduleConfig{} = config, %DateTime{} = reference) do
    collect(config, reference, @count, [])
  end

  defp collect(_config, _reference, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp collect(config, reference, remaining, acc) do
    case ScheduleCalculator.next(config, reference) do
      {:ok, :terminal} ->
        {:ok, Enum.reverse(acc)}

      {:ok, %DateTime{} = next} ->
        collect(config, next, remaining - 1, [next | acc])

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end
end
