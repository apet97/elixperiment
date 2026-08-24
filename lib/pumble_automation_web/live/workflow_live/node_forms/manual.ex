defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Manual do
  @moduledoc false
  use PumbleAutomationWeb, :html

  alias PumbleAutomation.Workflows.ManualAlias

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true

  def fields(assigns) do
    ~H"""
    <div id={"#{@form_id}-manual"}>
      <p id={"#{@form_id}-manual-alias-help"} class="mb-3 text-sm text-muted">
        {ManualAlias.message()} It must stay unique in this workspace.
      </p>
      <.input
        field={@form[:manual_alias]}
        type="text"
        label="Alias"
        maxlength={ManualAlias.max_length()}
        pattern={ManualAlias.html_pattern()}
        describedby={"#{@form_id}-manual-alias-help"}
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
