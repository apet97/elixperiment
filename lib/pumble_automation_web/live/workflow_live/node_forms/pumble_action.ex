defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.PumbleAction do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  alias PumbleAutomation.Workflows.Node.PumbleActionConfig

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true
  attr :references, :list, default: []
  attr :target, :any, default: nil
  attr :scope_notes, :list, default: []

  def fields(assigns) do
    assigns = assign(assigns, :actions, enum_options(PumbleActionConfig.actions()))

    ~H"""
    <.field_hint text="Only the fields this action uses are stored. Unused fields warn; required fields block activation." />
    <.input
      field={@form[:action]}
      type="select"
      label="Action"
      options={@actions}
      disabled={not @can_manage}
    />

    <.reference_helper
      id={"#{@form_id}-channel-refs"}
      field="channel_id"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:channel_id]}
      type="text"
      label="Channel"
      maxlength="128"
      disabled={not @can_manage}
    />

    <.reference_helper
      id={"#{@form_id}-user-refs"}
      field="user_id"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:user_id]}
      type="text"
      label="User"
      maxlength="128"
      disabled={not @can_manage}
    />

    <.reference_helper
      id={"#{@form_id}-message-refs"}
      field="message_id"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:message_id]}
      type="text"
      label="Message"
      maxlength="128"
      disabled={not @can_manage}
    />

    <.reference_helper
      id={"#{@form_id}-text-refs"}
      field="text"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:text]}
      type="textarea"
      label="Text"
      rows="4"
      maxlength="16384"
      disabled={not @can_manage}
    />

    <.reference_helper
      id={"#{@form_id}-reaction-refs"}
      field="reaction"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:reaction]}
      type="text"
      label="Reaction"
      maxlength="128"
      disabled={not @can_manage}
    />

    <.policy_note :if={@scope_notes != []} id={"#{@form_id}-scopes"} title="Required Pumble scopes">
      <p :for={note <- @scope_notes}>{note}</p>
    </.policy_note>
    """
  end

  defp enum_options(mapping) do
    mapping
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{String.replace(&1, "_", " "), &1})
  end
end
