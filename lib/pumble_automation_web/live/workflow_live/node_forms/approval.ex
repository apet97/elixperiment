defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Approval do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  alias PumbleAutomation.Workflows.Node.ApprovalConfig

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true
  attr :references, :list, default: []
  attr :target, :any, default: nil
  attr :scope_notes, :list, default: []
  attr :approver_text, :string, default: ""

  def fields(assigns) do
    assigns = assign(assigns, :max, ApprovalConfig.max_seconds())

    ~H"""
    <.field_hint text={"Named workspace members approve, reject, or let the wait elapse. Timeout range is 1 to #{@max} seconds (365 days)."} />

    <.reference_helper
      id={"#{@form_id}-prompt-refs"}
      field="prompt"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:prompt]}
      type="textarea"
      label="Prompt"
      rows="3"
      maxlength="4096"
      disabled={not @can_manage}
    />

    <.input
      id={"#{@form.id}_approver_member_ids"}
      name={"#{@form.name}[approver_member_ids]"}
      value={@approver_text}
      type="textarea"
      label="Approver member IDs"
      rows="3"
      disabled={not @can_manage}
    />

    <.input
      field={@form[:timeout_seconds]}
      type="number"
      label="Timeout (seconds)"
      min="1"
      max={@max}
      disabled={not @can_manage}
    />

    <.policy_note id={"#{@form_id}-approval-policy"} title="Who may approve">
      <p>
        Approvers are workspace member identifiers recorded on this step. Pumble roles
        and groups are not selectors. An empty list cannot activate. The wait follows
        the compiled approved, rejected, and timed-out branches.
      </p>
    </.policy_note>

    <.policy_note :if={@scope_notes != []} id={"#{@form_id}-scopes"} title="Required Pumble scopes">
      <p :for={note <- @scope_notes}>{note}</p>
    </.policy_note>
    """
  end
end
