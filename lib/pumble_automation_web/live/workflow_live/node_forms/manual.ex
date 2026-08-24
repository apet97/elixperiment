defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Manual do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true

  def fields(assigns) do
    ~H"""
    <div id={"#{@form_id}-manual"}>
      <.field_hint text="The alias is what a person types or picks. It must stay unique in this workspace." />
      <.input
        field={@form[:manual_alias]}
        type="text"
        label="Alias"
        maxlength="64"
        disabled={not @can_manage}
      />
      <.input
        field={@form[:slash_command]}
        type="checkbox"
        label="Slash command"
        disabled={not @can_manage}
      />
      <.input
        field={@form[:global_shortcut]}
        type="checkbox"
        label="Global shortcut"
        disabled={not @can_manage}
      />
      <.input
        field={@form[:message_shortcut]}
        type="checkbox"
        label="Message shortcut"
        disabled={not @can_manage}
      />
    </div>
    """
  end
end
