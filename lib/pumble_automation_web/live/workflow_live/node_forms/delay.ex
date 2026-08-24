defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Delay do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  alias PumbleAutomation.Workflows.Node.DelayConfig

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true

  def fields(assigns) do
    assigns = assign(assigns, :max, DelayConfig.max_seconds())

    ~H"""
    <div id={"#{@form_id}-delay"}>
      <.field_hint text={"Wait length in seconds. Allowed range is 1 to #{@max} (365 days)."} />
      <.input
        field={@form[:duration_seconds]}
        type="number"
        label="Duration (seconds)"
        min="1"
        max={@max}
        disabled={not @can_manage}
      />
    </div>
    """
  end
end
