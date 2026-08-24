defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.ManualTest do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true

  def fields(assigns) do
    ~H"""
    <div id={"#{@form_id}-manual-test"} data-form={@form.id} data-can-manage={to_string(@can_manage)}>
      <.field_hint text="A browser test trigger carries no configuration. Whether a test run may cause an external effect is chosen when you run it, not here." />
    </div>
    """
  end
end
