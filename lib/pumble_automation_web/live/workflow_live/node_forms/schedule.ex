defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Schedule do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  alias PumbleAutomation.Workflows.Definition.ScheduleConfig

  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true
  attr :preview, :list, default: []
  attr :preview_error, :string, default: nil
  attr :dst_policy, :string, required: true
  attr :weekdays, :list, default: []

  def fields(assigns) do
    assigns =
      assigns
      |> assign(:types, enum_options(ScheduleConfig.schedule_types()))
      |> assign(:weekday_choices, @weekdays)

    ~H"""
    <div id={"#{@form_id}-schedule"}>
      <.field_hint text="The first fire is strictly after activation. Draft edits do not move the live clock." />
      <.input
        field={@form[:schedule_type]}
        type="select"
        label="Schedule type"
        options={@types}
        disabled={not @can_manage}
      />
      <.input
        field={@form[:interval]}
        type="number"
        label="Interval"
        min="1"
        max="8760"
        disabled={not @can_manage}
      />
      <.input
        field={@form[:run_at]}
        type="text"
        label="Run at (ISO-8601)"
        maxlength="64"
        disabled={not @can_manage}
      />
      <.input
        field={@form[:time_of_day]}
        type="text"
        label="Time of day (HH:MM)"
        maxlength="8"
        disabled={not @can_manage}
      />
      <.input
        field={@form[:timezone]}
        type="text"
        label="Timezone (IANA)"
        maxlength="64"
        disabled={not @can_manage}
      />

      <fieldset class="mb-3">
        <legend class="mb-1 text-sm font-medium text-ink">Weekdays</legend>
        <label
          :for={day <- @weekday_choices}
          for={"#{@form.id}_weekdays_#{day}"}
          class="mr-3 inline-flex items-center gap-2 text-sm text-ink"
        >
          <input
            type="checkbox"
            id={"#{@form.id}_weekdays_#{day}"}
            name={"#{@form.name}[weekdays][]"}
            value={day}
            checked={day in @weekdays}
            disabled={not @can_manage}
            class="size-4 rounded border border-line bg-raised text-signal"
          />
          {String.capitalize(day)}
        </label>
      </fieldset>

      <div id="schedule-preview" class="mb-3 rounded-md border border-line bg-surface px-3 py-2">
        <p class="text-sm font-medium text-ink">Next occurrences (UTC)</p>
        <p :if={@preview_error} id="schedule-preview-error" class="mt-1 text-sm text-danger">
          {@preview_error}
        </p>
        <ol :if={@preview != []} class="mt-1 list-decimal space-y-1 pl-5 text-sm text-ink">
          <li :for={instant <- @preview} class="font-mono">{DateTime.to_iso8601(instant)}</li>
        </ol>
        <p :if={@preview == [] and is_nil(@preview_error)} class="mt-1 text-sm text-muted">
          No further occurrences from the current configuration.
        </p>
      </div>

      <.policy_note id="schedule-dst-policy" title="DST policy">
        <p>{@dst_policy}</p>
      </.policy_note>
    </div>
    """
  end

  defp enum_options(mapping) do
    mapping
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{String.replace(&1, "_", " "), &1})
  end
end
