defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Webhook do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true

  def fields(assigns) do
    ~H"""
    <div id={"#{@form_id}-webhook"}>
      <.field_hint text="Activation issues a version-bound URL and bearer token. Credentials are shown once to owners and are never stored on this definition." />
      <.input
        field={@form[:require_signature]}
        type="checkbox"
        label="Require raw-body HMAC signature"
        disabled={not @can_manage}
        describedby={"#{@form_id}-hmac-help"}
      />
      <p id={"#{@form_id}-hmac-help"} class="mb-3 text-sm text-muted">
        When enabled, callers send x-webhook-signature as sha256=&lt;lowercase hex&gt; over the
        exact request-body bytes. This is separate from Pumble callback signing.
      </p>
    </div>
    """
  end
end
