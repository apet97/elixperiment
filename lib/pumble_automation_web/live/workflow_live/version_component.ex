defmodule PumbleAutomationWeb.WorkflowLive.VersionComponent do
  @moduledoc """
  Immutable version history, hashes, and a short diff of source definitions.
  """
  use PumbleAutomationWeb, :html

  attr :id, :string, default: "version-history"
  attr :versions, :list, required: true
  attr :active_version_id, :string, default: nil
  attr :selected, :map, default: nil
  attr :diff, :list, default: []
  attr :can_activate, :boolean, required: true
  attr :creators, :map, default: %{}

  def version_history(assigns) do
    ~H"""
    <section id={@id} class="rounded-lg border border-line bg-raised p-5">
      <h2 class="text-base font-semibold text-ink">Versions</h2>
      <p class="mt-1 text-sm text-muted">
        Each version is immutable. Reactivating one replaces the live pointer; it does
        not rewrite history.
      </p>

      <div :if={@versions == []} id={"#{@id}-empty"} class="mt-4 text-sm text-muted">
        No versions yet. Activate a proved draft to create the first one.
      </div>

      <ol :if={@versions != []} id={"#{@id}-list"} class="mt-4 space-y-2">
        <li :for={version <- @versions} id={"version-#{version.version_number}"}>
          <button
            id={"version-select-#{version.version_number}"}
            type="button"
            phx-click="select_version"
            phx-value-number={version.version_number}
            class={[
              "w-full rounded-md border px-3 py-3 text-left transition-colors hover:border-signal",
              if(@selected && @selected.version_number == version.version_number,
                do: "border-signal ring-2 ring-signal",
                else: "border-line"
              )
            ]}
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="text-sm font-semibold text-ink">
                Version {version.version_number}
              </span>
              <.status_badge
                :if={version.id == @active_version_id}
                id={"version-live-#{version.version_number}"}
                tone="ok"
                label="Live"
              />
            </div>
            <p class="mt-1 font-mono text-xs text-muted">
              {short_hash(version.definition_hash)}
            </p>
            <p class="mt-1 text-xs text-muted">
              {Map.get(@creators, version.created_by_member_id, "Unknown")} · {time_text(
                version.activated_at || version.inserted_at
              )}
            </p>
          </button>
        </li>
      </ol>

      <div :if={@selected} id="version-detail" class="mt-5 space-y-3 border-t border-line pt-4">
        <h3 class="text-sm font-semibold text-ink">
          Version {@selected.version_number} detail
        </h3>
        <dl class="grid gap-3 sm:grid-cols-2">
          <div>
            <dt class="text-xs font-medium uppercase tracking-wide text-muted">Hash</dt>
            <dd id="version-detail-hash" class="mt-1 break-all font-mono text-xs text-ink">
              {@selected.definition_hash}
            </dd>
          </div>
          <div>
            <dt class="text-xs font-medium uppercase tracking-wide text-muted">Creator</dt>
            <dd id="version-detail-creator" class="mt-1 text-sm text-ink">
              {Map.get(@creators, @selected.created_by_member_id, "Unknown")}
            </dd>
          </div>
        </dl>

        <div id="version-diff">
          <p class="text-xs font-medium uppercase tracking-wide text-muted">Diff summary</p>
          <ul class="mt-2 list-disc space-y-1 pl-5 text-sm text-ink">
            <li :for={line <- @diff}>{line}</li>
          </ul>
        </div>

        <.button
          :if={@can_activate and @selected.id != @active_version_id}
          id={"version-reactivate-#{@selected.version_number}"}
          variant="secondary"
          type="button"
          phx-click="confirm_reactivate"
          phx-value-number={@selected.version_number}
        >
          Reactivate this version
        </.button>
      </div>
    </section>
    """
  end

  @doc "A short, deterministic summary of how two encoded source definitions differ."
  @spec diff_summary(map() | nil, map() | nil) :: [String.t()]
  def diff_summary(from, to)
  def diff_summary(nil, to) when is_map(to), do: ["No earlier version to compare."]
  def diff_summary(_from, nil), do: ["No definition is selected."]

  def diff_summary(from, to) when is_map(from) and is_map(to) do
    lines =
      []
      |> add_trigger_line(from, to)
      |> add_schedule_line(from, to)
      |> add_step_lines(from, to)

    if lines == [], do: ["No definition changes."], else: lines
  end

  defp add_trigger_line(lines, from, to) do
    old = get_in(from, ["trigger", "type"])
    new = get_in(to, ["trigger", "type"])

    if old == new do
      lines
    else
      lines ++ ["Trigger changed from #{trigger_label(old)} to #{trigger_label(new)}."]
    end
  end

  defp add_schedule_line(lines, from, to) do
    old_type = get_in(from, ["trigger", "type"])
    new_type = get_in(to, ["trigger", "type"])

    cond do
      old_type != "schedule" and new_type != "schedule" ->
        lines

      old_type != new_type ->
        lines ++
          [
            "Schedule bindings change with the trigger. The first next run is calculated from activation time, not from this draft edit."
          ]

      get_in(from, ["trigger", "config"]) == get_in(to, ["trigger", "config"]) ->
        lines

      true ->
        lines ++
          [
            "Schedule configuration changed. Draft edits do not move the live clock until this version is activated."
          ]
    end
  end

  defp add_step_lines(lines, from, to) do
    old = flatten_steps(Map.get(from, "steps", []))
    new = flatten_steps(Map.get(to, "steps", []))
    old_ids = MapSet.new(Enum.map(old, &elem(&1, 0)))
    new_ids = MapSet.new(Enum.map(new, &elem(&1, 0)))
    added = MapSet.difference(new_ids, old_ids) |> MapSet.size()
    removed = MapSet.difference(old_ids, new_ids) |> MapSet.size()

    step_lines =
      []
      |> maybe_add(
        length(old) != length(new),
        "Step count changed from #{length(old)} to #{length(new)}."
      )
      |> maybe_add(added > 0, "Added #{added} #{noun(added, "step")}.")
      |> maybe_add(removed > 0, "Removed #{removed} #{noun(removed, "step")}.")

    types_changed? =
      old
      |> Enum.filter(fn {id, type} -> Map.new(new)[id] not in [nil, type] end)
      |> Enum.any?()

    step_lines = maybe_add(step_lines, types_changed?, "At least one kept step changed type.")
    lines ++ step_lines
  end

  defp flatten_steps(steps) when is_list(steps) do
    Enum.flat_map(steps, fn step ->
      nested =
        ~w(if_true if_false approved rejected timed_out)
        |> Enum.flat_map(&flatten_steps(Map.get(step, &1, [])))

      [{Map.get(step, "id"), Map.get(step, "type")} | nested]
    end)
  end

  defp flatten_steps(_other), do: []

  defp maybe_add(lines, true, line), do: lines ++ [line]
  defp maybe_add(lines, false, _line), do: lines

  defp trigger_label("pumble_event"), do: "Pumble event"
  defp trigger_label("schedule"), do: "schedule"
  defp trigger_label("manual"), do: "manual"
  defp trigger_label("webhook"), do: "webhook"
  defp trigger_label("manual_test"), do: "test"
  defp trigger_label(other) when is_binary(other), do: other
  defp trigger_label(_other), do: "unknown"

  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)
  defp short_hash(_hash), do: "—"

  defp time_text(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  defp time_text(_other), do: "—"

  defp noun(1, word), do: word
  defp noun(_count, word), do: word <> "s"
end
