defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Stop do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true
  attr :references, :list, default: []
  attr :target, :any, default: nil

  def fields(assigns) do
    ~H"""
    <.field_hint text="Optional reason recorded on the execution timeline. Templates are allowed." />
    <.reference_helper
      id={"#{@form_id}-reason-refs"}
      field="reason"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:reason]}
      type="textarea"
      label="Reason"
      rows="3"
      maxlength="1024"
      disabled={not @can_manage}
    />
    """
  end
end
