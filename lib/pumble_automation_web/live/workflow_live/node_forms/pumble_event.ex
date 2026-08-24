defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.PumbleEvent do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  alias PumbleAutomation.Workflows.Definition.PumbleEventConfig

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true
  attr :channel_text, :string, default: ""

  def fields(assigns) do
    assigns = assign(assigns, :events, enum_options(PumbleEventConfig.events()))

    ~H"""
    <div id={"#{@form_id}-pumble-event"}>
      <.field_hint text="Only user-visible Pumble events are selectable. Uninstall and unauthorized callbacks cannot start a workflow." />
      <.input
        field={@form[:event]}
        type="select"
        label="Event"
        options={@events}
        disabled={not @can_manage}
      />
      <.input
        id={"#{@form.id}_channel_ids"}
        name={"#{@form.name}[channel_ids]"}
        value={@channel_text}
        type="text"
        label="Channel IDs"
        disabled={not @can_manage}
      />
      <.input
        field={@form[:keyword]}
        type="text"
        label="Keyword"
        maxlength="1024"
        disabled={not @can_manage}
      />
      <.input
        field={@form[:ignore_bot_messages]}
        type="checkbox"
        label="Ignore bot messages"
        disabled={not @can_manage}
      />
      <.field_hint text={PumbleAutomation.Executions.Lineage.include_bot_warning_message()} />
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
