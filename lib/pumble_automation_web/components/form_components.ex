defmodule PumbleAutomationWeb.FormComponents do
  @moduledoc """
  Shared chrome for node configuration forms: issues, pickers, and helpers.
  """
  use PumbleAutomationWeb, :html

  attr :id, :string, required: true
  attr :issues, :list, default: []

  def issue_list(assigns) do
    ~H"""
    <div :if={@issues != []} id={@id} class="space-y-1" role={issue_live_role(@issues)}>
      <p
        :for={issue <- @issues}
        id={"#{@id}-#{issue_dom_id(issue)}"}
        data-code={to_string(issue.code)}
        data-path={issue.path}
        class={[
          "text-sm",
          issue.severity == :error && "text-danger",
          issue.severity != :error && "text-muted"
        ]}
      >
        <span class="font-mono text-xs uppercase tracking-wide">{issue.code}</span>
        {issue.message}
      </p>
    </div>
    """
  end

  attr :text, :string, required: true

  def field_hint(assigns) do
    ~H"""
    <p class="mb-3 text-sm text-muted">{@text}</p>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def policy_note(assigns) do
    ~H"""
    <aside
      id={@id}
      class="mt-3 rounded-md border border-line bg-surface px-3 py-2 text-sm text-muted"
    >
      <p class="font-medium text-ink">{@title}</p>
      <div class="mt-1 space-y-1">{render_slot(@inner_block)}</div>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :field, :string, required: true
  attr :references, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :target, :any, default: nil

  def reference_helper(assigns) do
    ~H"""
    <div id={@id} class="mb-3">
      <p class="mb-1 text-xs font-medium uppercase tracking-wide text-muted">
        Insert a reference
      </p>
      <div class="flex flex-wrap gap-1">
        <button
          :for={item <- @references}
          id={"#{@id}-#{path_dom_id(item.path)}"}
          type="button"
          disabled={not @can_manage}
          phx-click="insert_reference"
          phx-value-field={@field}
          phx-value-path={item.path}
          phx-target={@target}
          class="rounded-full border border-line bg-raised px-2 py-0.5 font-mono text-xs text-ink transition-colors hover:border-signal disabled:cursor-not-allowed disabled:opacity-50"
        >
          {item.path}
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field, :string, required: true
  attr :secrets, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :target, :any, default: nil

  def secret_picker(assigns) do
    ~H"""
    <div id={@id} class="mb-3">
      <p class="mb-1 text-xs font-medium uppercase tracking-wide text-muted">
        Insert a secret by name
      </p>
      <p :if={@secrets == []} class="text-sm text-muted">
        No secrets in this workspace yet.
        <a
          href="#nav-secrets"
          id={"#{@id}-manage"}
          class="font-medium text-signal hover:text-signal-strong"
        >
          Manage secrets
        </a>
      </p>
      <div :if={@secrets != []} class="flex flex-wrap gap-1">
        <button
          :for={secret <- @secrets}
          id={"#{@id}-#{secret.name}"}
          type="button"
          disabled={not @can_manage}
          phx-click="insert_reference"
          phx-value-field={@field}
          phx-value-path={"secret.#{secret.name}"}
          phx-target={@target}
          class="rounded-full border border-line bg-raised px-2 py-0.5 font-mono text-xs text-ink transition-colors hover:border-signal disabled:cursor-not-allowed disabled:opacity-50"
        >
          {secret.name}
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :label, :string, required: true

  def missing_dependency(assigns) do
    ~H"""
    <p id={@id} class="mb-2 text-sm text-danger">
      {@label}
      <a href={@href} class="font-medium text-signal hover:text-signal-strong">Open the management page</a>
    </p>
    """
  end

  defp issue_live_role(issues) do
    if Enum.any?(issues, &(&1.severity == :error)), do: "alert", else: "status"
  end

  defp issue_dom_id(issue) do
    path = issue.path |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.trim("-")
    "#{issue.code}-#{path}"
  end

  defp path_dom_id(path) do
    path |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.trim("-")
  end
end
