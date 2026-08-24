defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.HttpAction do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Workflows.Node.HttpActionConfig

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true
  attr :references, :list, default: []
  attr :target, :any, default: nil
  attr :header_rows, :list, default: []
  attr :connections, :list, default: []
  attr :secrets, :list, default: []
  attr :missing_connection?, :boolean, default: false
  attr :missing_secrets, :list, default: []

  def fields(assigns) do
    assigns =
      assigns
      |> assign(:methods, enum_options(HttpActionConfig.methods()))
      |> assign(:connection_options, connection_options(assigns.connections))
      |> assign(:blocked, Enum.sort(Connection.blocked_headers()))

    ~H"""
    <.field_hint text="The URL must begin with https://. Private, loopback, and metadata addresses are blocked. A connection supplies origin, prefix, and secret headers without exposing values." />

    <.missing_dependency
      :if={@missing_connection?}
      id={"#{@form_id}-missing-connection"}
      href="#nav-connections"
      label="This request names a connection that is not in this workspace."
    />
    <.missing_dependency
      :if={@missing_secrets != []}
      id={"#{@form_id}-missing-secret"}
      href="#nav-secrets"
      label="This request names a secret that is not in this workspace."
    />

    <.input
      field={@form[:method]}
      type="select"
      label="Method"
      options={@methods}
      disabled={not @can_manage}
    />

    <.reference_helper
      id={"#{@form_id}-url-refs"}
      field="url"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:url]}
      type="text"
      label="URL"
      maxlength="2048"
      disabled={not @can_manage}
    />

    <.input
      field={@form[:connection_id]}
      type="select"
      label="Connection"
      prompt="No connection"
      options={@connection_options}
      disabled={not @can_manage}
    />

    <.input
      field={@form[:timeout_ms]}
      type="number"
      label="Timeout (milliseconds)"
      min="1"
      max="120000"
      disabled={not @can_manage}
    />

    <.input
      field={@form[:idempotency_header]}
      type="text"
      label="Remote idempotency header"
      maxlength="128"
      placeholder="Idempotency-Key"
      disabled={not @can_manage}
      describedby={"#{@form_id}-idempotency-help"}
    />
    <p id={"#{@form_id}-idempotency-help"} class="text-sm text-muted">
      When set, each execution sends its stable effect key as this header's value. Only
      use a header the remote service documents as an idempotency key.
    </p>

    <div id={"#{@form_id}-headers"} class="space-y-2">
      <p class="text-sm font-medium text-ink">Headers</p>
      <p class="text-sm text-muted">
        Authorization may only carry a secret reference. Hop-by-hop names are blocked.
      </p>
      <div
        :for={{row, index} <- Enum.with_index(@header_rows)}
        id={"#{@form_id}-header-#{index}"}
        class="grid gap-2 sm:grid-cols-[1fr_1fr_auto]"
      >
        <.input
          id={"#{@form.id}_headers_#{index}_name"}
          name={"#{@form.name}[headers][#{index}][name]"}
          value={Map.get(row, "name", "")}
          type="text"
          label="Name"
          disabled={not @can_manage}
        />
        <.input
          id={"#{@form.id}_headers_#{index}_value"}
          name={"#{@form.name}[headers][#{index}][value]"}
          value={Map.get(row, "value", "")}
          type="text"
          label="Value"
          disabled={not @can_manage}
        />
        <.button
          :if={@can_manage}
          id={"#{@form_id}-remove-header-#{index}"}
          variant="ghost"
          type="button"
          phx-click="remove_header"
          phx-value-index={index}
          phx-target={@target}
        >
          Remove
        </.button>
      </div>
      <.button
        :if={@can_manage}
        id={"#{@form_id}-add-header"}
        variant="secondary"
        type="button"
        phx-click="add_header"
        phx-target={@target}
      >
        Add header
      </.button>
    </div>

    <.secret_picker
      id={"#{@form_id}-secrets"}
      field="body"
      secrets={@secrets}
      can_manage={@can_manage}
      target={@target}
    />
    <.reference_helper
      id={"#{@form_id}-body-refs"}
      field="body"
      references={@references}
      can_manage={@can_manage}
      target={@target}
    />
    <.input
      field={@form[:body]}
      type="textarea"
      label="Body"
      rows="4"
      maxlength="16384"
      disabled={not @can_manage}
    />

    <.policy_note id={"#{@form_id}-retry-policy"} title="Retry and idempotency">
      <p>
        GET and HEAD retry on timeout. Other methods pause as uncertain after a possible
        dispatch unless this request carries the remote idempotency header configured
        above. Unmarked writes are unsafe to repeat.
      </p>
    </.policy_note>

    <.policy_note id={"#{@form_id}-blocked-targets"} title="Blocked targets and headers">
      <p>
        Loopback, link-local, private, and metadata addresses are refused. DNS answers
        that mix public and blocked addresses are refused. Blocked header names: {Enum.join(
          @blocked,
          ", "
        )}.
      </p>
    </.policy_note>
    """
  end

  defp enum_options(mapping) do
    mapping
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{String.upcase(&1), &1})
  end

  defp connection_options(connections) do
    Enum.map(connections, fn connection ->
      label =
        if connection.enabled, do: connection.name, else: "#{connection.name} (disabled)"

      {label, connection.id}
    end)
  end
end
