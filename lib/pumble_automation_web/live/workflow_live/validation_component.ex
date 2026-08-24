defmodule PumbleAutomationWeb.WorkflowLive.ValidationComponent do
  @moduledoc """
  Grouped validation findings and the compact cards used to focus a step.
  """
  use PumbleAutomationWeb, :html

  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.ValidationIssue

  attr :id, :string, default: "workflow-validation"
  attr :issues, :list, required: true
  attr :validated?, :boolean, required: true
  attr :can_validate, :boolean, default: true
  attr :focused_id, :string, default: nil

  def validation_panel(assigns) do
    assigns = assign(assigns, :groups, grouped(assigns.issues))

    ~H"""
    <section id={@id} class="rounded-lg border border-line bg-raised p-5">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold text-ink">Validation</h2>
          <p class="mt-1 text-sm text-muted">
            Findings come from the compiler boundary. Warnings never prove a draft is ready.
          </p>
        </div>
        <.button
          :if={@can_validate}
          id={"#{@id}-run"}
          variant="secondary"
          type="button"
          phx-click="validate"
        >
          Validate draft
        </.button>
      </div>

      <div :if={@validated?} class="mt-4 space-y-4">
        <.banner id={"#{@id}-status"} tone={status_tone(@issues)} title={status_title(@issues)}>
          {status_copy(@issues)}
        </.banner>

        <div :if={@issues == []} id={"#{@id}-empty"} class="text-sm text-muted">
          No blocking issues. Activation still checks scopes, secrets, and connections.
        </div>

        <div :for={group <- @groups} id={"#{@id}-group-#{group.key}"} class="space-y-2">
          <h3 class="text-sm font-semibold text-ink">{group.label}</h3>
          <button
            :for={{issue, index} <- group.issues}
            id={"validation-issue-#{index}"}
            type="button"
            phx-click="focus_issue"
            phx-value-key={group.key}
            data-code={Atom.to_string(issue.code)}
            data-path={issue.path}
            data-severity={Atom.to_string(issue.severity)}
            data-node-id={issue.node_id}
            class={[
              "block w-full rounded-md border px-3 py-2 text-left text-sm transition-colors",
              issue.severity == :error && "border-danger/40 hover:border-danger",
              issue.severity != :error && "border-line hover:border-warn",
              @focused_id == group.key && "ring-2 ring-signal"
            ]}
            aria-current={@focused_id == group.key && "true"}
          >
            <span class="font-mono text-xs uppercase tracking-wide text-muted">
              {issue.code}
            </span>
            <span class="mt-0.5 block text-ink">{issue.message}</span>
            <span class="mt-0.5 block font-mono text-xs text-muted">{issue.path}</span>
          </button>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, default: "validation-cards"
  attr :definition, :map, required: true
  attr :focused_id, :string, default: nil

  def validation_cards(assigns) do
    assigns =
      assign(assigns,
        nodes: Definition.nodes(assigns.definition),
        trigger: assigns.definition.trigger
      )

    ~H"""
    <div id={@id} class="space-y-3">
      <article
        id="focus-card-trigger"
        data-focused={to_string(@focused_id == "trigger")}
        class={[
          "rounded-lg border bg-raised p-4 transition-shadow",
          @focused_id == "trigger" && "border-signal ring-2 ring-signal shadow-md",
          @focused_id != "trigger" && "border-line"
        ]}
      >
        <p class="text-xs font-medium uppercase tracking-wide text-muted">Trigger</p>
        <h3 class="mt-1 text-sm font-semibold text-ink">{trigger_title(@trigger)}</h3>
      </article>

      <article
        :for={node <- @nodes}
        id={"focus-card-#{node.id}"}
        data-node-id={node.id}
        data-focused={to_string(@focused_id == node.id)}
        class={[
          "rounded-lg border bg-raised p-4 transition-shadow",
          @focused_id == node.id && "border-signal ring-2 ring-signal shadow-md",
          @focused_id != node.id && "border-line"
        ]}
      >
        <p class="font-mono text-xs text-muted">{String.slice(node.id, 0, 8)}</p>
        <h3 class="mt-1 text-sm font-semibold text-ink">{node_title(node)}</h3>
      </article>
    </div>
    """
  end

  @doc "Groups issues by trigger, node, or workflow, preserving validator order."
  @spec grouped([ValidationIssue.t()]) :: [map()]
  def grouped(issues) when is_list(issues) do
    issues
    |> Enum.with_index()
    |> Enum.group_by(fn {issue, _index} -> group_key(issue) end)
    |> Enum.sort_by(fn {_key, pairs} -> pairs |> hd() |> elem(1) end)
    |> Enum.map(fn {key, pairs} ->
      %{key: key, label: group_label(key, pairs), issues: pairs}
    end)
  end

  defp group_key(%ValidationIssue{node_id: id}) when is_binary(id) and id != "", do: id

  defp group_key(%ValidationIssue{path: path}) when is_binary(path) do
    if String.starts_with?(path, "/trigger"), do: "trigger", else: "workflow"
  end

  defp group_key(_issue), do: "workflow"

  defp group_label("trigger", _pairs), do: "Trigger"
  defp group_label("workflow", _pairs), do: "Workflow"

  defp group_label(node_id, pairs) do
    case Enum.find(pairs, fn {issue, _} -> issue.node_id == node_id end) do
      {%ValidationIssue{node_id: id}, _} -> "Step #{String.slice(id, 0, 8)}"
      _missing -> "Step"
    end
  end

  defp status_tone(issues) do
    cond do
      ValidationIssue.errors?(issues) -> "danger"
      issues != [] -> "warn"
      true -> "info"
    end
  end

  defp status_title(issues) do
    cond do
      ValidationIssue.errors?(issues) -> "Blocking issues"
      issues != [] -> "Warnings only"
      true -> "No blocking issues"
    end
  end

  defp status_copy(issues) do
    cond do
      ValidationIssue.errors?(issues) ->
        "Activation stays blocked until these errors are fixed."

      issues != [] ->
        "Warnings are not a proof of success. The workflow can still be activated."

      true ->
        "Nothing here blocked compilation. Scopes and dependencies are checked at activation."
    end
  end

  defp trigger_title(%Trigger{type: :pumble_event}), do: "Pumble event"
  defp trigger_title(%Trigger{type: :schedule}), do: "Schedule"
  defp trigger_title(%Trigger{type: :manual}), do: "Manual"
  defp trigger_title(%Trigger{type: :webhook}), do: "Inbound webhook"
  defp trigger_title(%Trigger{type: :manual_test}), do: "Test"
  defp trigger_title(_trigger), do: "Trigger"

  defp node_title(%Node{type: :pumble_action}), do: "Pumble message"
  defp node_title(%Node{type: :delay}), do: "Delay"
  defp node_title(%Node{type: :condition}), do: "Condition"
  defp node_title(%Node{type: :approval}), do: "Approval"
  defp node_title(%Node{type: :http_action}), do: "HTTP request"
  defp node_title(%Node{type: :stop}), do: "Stop"
  defp node_title(_node), do: "Step"
end
