defmodule PumbleAutomationWeb.EditorComponents do
  @moduledoc """
  Nested outline chrome for the workflow editor: trigger, steps, branches, and dialogs.
  """
  use PumbleAutomationWeb, :html

  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomationWeb.WorkflowLive.NodeFormComponent

  attr :trigger, :map, required: true
  attr :definition, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :secrets, :list, required: true
  attr :connections, :list, required: true
  attr :form_epoch, :integer, required: true
  attr :focused_id, :string, default: nil

  def trigger_card(assigns) do
    ~H"""
    <article
      id="workflow-trigger"
      data-focused={to_string(@focused_id == "trigger")}
      class={[
        "rounded-lg border bg-raised p-4 shadow-[0_1px_0_rgba(21,32,40,0.04)]",
        @focused_id == "trigger" && "border-signal ring-2 ring-signal",
        @focused_id != "trigger" && "border-line"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-xs font-medium uppercase tracking-wide text-muted">Trigger</p>
          <h2 class="mt-1 text-base font-semibold text-ink">{trigger_title(@trigger)}</h2>
          <p class="mt-1 text-sm text-muted">{trigger_detail(@trigger)}</p>
        </div>
        <.status_badge id="trigger-type" tone="info" label={trigger_type_label(@trigger.type)} />
      </div>

      <.live_component
        module={NodeFormComponent}
        id="trigger-config"
        kind={:trigger}
        subject={@trigger}
        definition={@definition}
        can_manage={@can_manage}
        secrets={@secrets}
        connections={@connections}
        form_epoch={@form_epoch}
      />
    </article>
    """
  end

  attr :id, :string, required: true
  attr :nodes, :list, required: true
  attr :prefix, :string, required: true
  attr :branch_path, :string, required: true
  attr :can_manage, :boolean, required: true
  attr :definition, :map, required: true
  attr :secrets, :list, required: true
  attr :connections, :list, required: true
  attr :form_epoch, :integer, required: true
  attr :focused_id, :string, default: nil

  def sequence(assigns) do
    assigns = assign(assigns, :indexed, Enum.with_index(assigns.nodes, 1))

    ~H"""
    <ol id={@id} class="space-y-3">
      <li :if={@nodes == []} id={"#{@id}-empty"} class="text-sm text-muted">
        No steps in this sequence yet.
      </li>
      <.step_card
        :for={{node, index} <- @indexed}
        node={node}
        number={step_number(@prefix, index)}
        index={index}
        length={length(@nodes)}
        branch_path={@branch_path}
        can_manage={@can_manage}
        definition={@definition}
        secrets={@secrets}
        connections={@connections}
        form_epoch={@form_epoch}
        focused_id={@focused_id}
      />
    </ol>
    """
  end

  attr :node, :map, required: true
  attr :number, :string, required: true
  attr :index, :integer, required: true
  attr :length, :integer, required: true
  attr :branch_path, :string, required: true
  attr :can_manage, :boolean, required: true
  attr :definition, :map, required: true
  attr :secrets, :list, required: true
  attr :connections, :list, required: true
  attr :form_epoch, :integer, required: true
  attr :focused_id, :string, default: nil

  def step_card(assigns) do
    assigns = assign(assigns, :branch_keys, Node.branch_keys(assigns.node.type))

    ~H"""
    <li>
      <article
        id={"step-#{@node.id}"}
        data-node-id={@node.id}
        data-branch-path={@branch_path}
        data-focused={to_string(@focused_id == @node.id)}
        draggable={@can_manage}
        aria-grabbed="false"
        class={[
          "rounded-lg border bg-raised p-4 shadow-[0_1px_0_rgba(21,32,40,0.04)]",
          "transition-shadow hover:shadow-md",
          @focused_id == @node.id && "border-signal ring-2 ring-signal",
          @focused_id != @node.id && "border-line",
          @can_manage && "cursor-grab active:cursor-grabbing"
        ]}
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <p id={"step-number-#{@node.id}"} class="font-mono text-xs text-muted">
              {@number}
            </p>
            <h3 class="mt-1 text-sm font-semibold text-ink">{node_title(@node)}</h3>
            <p class="mt-0.5 text-xs text-muted">{node_detail(@node)}</p>
          </div>
          <div :if={@can_manage} class="flex flex-wrap gap-2">
            <.button
              id={"step-add-before-#{@node.id}"}
              variant="ghost"
              type="button"
              phx-click="add_prompt"
              phx-value-op="before"
              phx-value-id={@node.id}
            >
              Add before
            </.button>
            <.button
              id={"step-add-after-#{@node.id}"}
              variant="ghost"
              type="button"
              phx-click="add_prompt"
              phx-value-op="after"
              phx-value-id={@node.id}
            >
              Add after
            </.button>
            <.button
              id={"step-move-up-#{@node.id}"}
              variant="secondary"
              type="button"
              phx-click="move_up"
              phx-value-id={@node.id}
              disabled={@index == 1}
              aria-label="Move step up"
            >
              <.icon name="hero-arrow-up-mini" class="size-4" />
              <span>Up</span>
            </.button>
            <.button
              id={"step-move-down-#{@node.id}"}
              variant="secondary"
              type="button"
              phx-click="move_down"
              phx-value-id={@node.id}
              disabled={@index == @length}
              aria-label="Move step down"
            >
              <.icon name="hero-arrow-down-mini" class="size-4" />
              <span>Down</span>
            </.button>
            <.button
              id={"step-delete-#{@node.id}"}
              variant="danger"
              type="button"
              phx-click="confirm_delete"
              phx-value-id={@node.id}
            >
              Delete
            </.button>
          </div>
        </div>

        <.live_component
          module={NodeFormComponent}
          id={"node-config-#{@node.id}"}
          kind={:node}
          subject={@node}
          definition={@definition}
          can_manage={@can_manage}
          secrets={@secrets}
          connections={@connections}
          form_epoch={@form_epoch}
        />
      </article>

      <div
        :for={key <- @branch_keys}
        id={"branch-#{@node.id}-#{key}"}
        class="mt-3 ml-3 border-l-2 border-signal/40 pl-4 sm:ml-5"
      >
        <p class="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
          {branch_label(key)}
        </p>
        <.sequence
          id={"sequence-#{@node.id}-#{key}"}
          nodes={Map.get(@node.branches, key, [])}
          prefix={@number}
          branch_path={"#{@node.id}:#{key}"}
          can_manage={@can_manage}
          definition={@definition}
          secrets={@secrets}
          connections={@connections}
          form_epoch={@form_epoch}
          focused_id={@focused_id}
        />
        <div :if={@can_manage} class="mt-2">
          <.button
            id={"branch-add-#{@node.id}-#{key}"}
            variant="ghost"
            type="button"
            phx-click="add_prompt"
            phx-value-op="append"
            phx-value-parent_id={@node.id}
            phx-value-branch_key={key}
          >
            Add to {branch_label(key)}
          </.button>
        </div>
      </div>
    </li>
    """
  end

  attr :save_state, :atom, required: true
  attr :can_manage, :boolean, required: true

  def save_status(assigns) do
    ~H"""
    <div
      id="editor-save-state"
      data-state={Atom.to_string(@save_state)}
      aria-live="polite"
      class="flex flex-wrap items-center gap-3"
    >
      <.status_badge
        id="editor-save-badge"
        tone={save_tone(@save_state)}
        label={save_label(@save_state)}
      />
      <.button
        :if={@can_manage and @save_state != :conflict}
        id="editor-save"
        variant="primary"
        type="button"
        phx-click="save"
        disabled={@save_state in [:saved, :saving]}
      >
        Save draft
      </.button>
    </div>
    """
  end

  def conflict_banner(assigns) do
    ~H"""
    <.banner id="editor-conflict" tone="warn" title="This draft changed in another session">
      <p>
        Your outline is still on this page and was not overwritten. Reload the saved draft,
        or keep this session's steps and save them over the other changes.
      </p>
      <div class="mt-3 flex flex-wrap gap-2">
        <.button id="editor-reload" variant="secondary" type="button" phx-click="reload">
          Reload saved draft
        </.button>
        <.button id="editor-reapply" variant="primary" type="button" phx-click="reapply">
          Keep these steps and save
        </.button>
      </div>
    </.banner>
    """
  end

  attr :node_types, :list, required: true

  def type_picker(assigns) do
    ~H"""
    <.modal id="editor-type-picker" title="Add a step" on_cancel="cancel_add" class="max-w-lg">
      <p class="text-sm text-muted">Choose a step type. Configuration fields come next.</p>
      <div class="mt-4 grid gap-2 sm:grid-cols-2">
        <.button
          :for={type <- @node_types}
          id={"add-type-#{type.id}"}
          variant="secondary"
          type="button"
          phx-click="add_node"
          phx-value-type={type.id}
        >
          {type.name}
        </.button>
      </div>
      <div class="mt-4 flex justify-end">
        <.button id="editor-cancel-add" variant="ghost" type="button" phx-click="cancel_add">
          Cancel
        </.button>
      </div>
    </.modal>
    """
  end

  attr :confirm, :map, required: true

  def delete_dialog(assigns) do
    ~H"""
    <.modal
      id="editor-confirm-delete"
      title="Delete this step?"
      on_cancel="cancel_confirm"
      class="max-w-lg"
    >
      <p class="text-sm text-muted">
        This removes {@confirm.deleted_count}
        {step_noun(@confirm.deleted_count)}
        <%= if @confirm.owned_branches? do %>
          and nested branches
        <% end %>. It cannot be undone from this editor.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="editor-cancel-delete" variant="ghost" type="button" phx-click="cancel_confirm">
          Keep step
        </.button>
        <.button
          id="editor-confirm-delete-submit"
          variant="danger"
          type="button"
          phx-click="delete"
          phx-value-id={@confirm.id}
        >
          Delete
        </.button>
      </div>
    </.modal>
    """
  end

  defp step_number("", index), do: Integer.to_string(index)
  defp step_number(prefix, index), do: "#{prefix}.#{index}"

  defp step_noun(1), do: "step"
  defp step_noun(_count), do: "steps"

  defp save_tone(:saved), do: "ok"
  defp save_tone(:saving), do: "info"
  defp save_tone(:conflict), do: "warn"
  defp save_tone(_state), do: "neutral"

  defp save_label(:saved), do: "Saved"
  defp save_label(:saving), do: "Saving"
  defp save_label(:conflict), do: "Conflict"
  defp save_label(_state), do: "Unsaved"

  defp trigger_type_label(:pumble_event), do: "Pumble event"
  defp trigger_type_label(:manual), do: "Manual"
  defp trigger_type_label(:schedule), do: "Schedule"
  defp trigger_type_label(:webhook), do: "Webhook"
  defp trigger_type_label(:manual_test), do: "Test"
  defp trigger_type_label(_type), do: "Trigger"

  defp trigger_title(%Trigger{type: :pumble_event, config: config}) do
    event = config.event |> to_string() |> String.replace("_", " ")
    "When #{event}"
  end

  defp trigger_title(%Trigger{type: :schedule}), do: "On a schedule"
  defp trigger_title(%Trigger{type: :manual}), do: "Started by a person"
  defp trigger_title(%Trigger{type: :webhook}), do: "Inbound webhook"
  defp trigger_title(%Trigger{}), do: "Workflow trigger"

  defp trigger_detail(%Trigger{id: id}), do: "ID #{short_id(id)}"

  defp node_title(%Node{type: :pumble_action}), do: "Pumble message"
  defp node_title(%Node{type: :delay}), do: "Delay"
  defp node_title(%Node{type: :condition}), do: "Condition"
  defp node_title(%Node{type: :approval}), do: "Approval"
  defp node_title(%Node{type: :http_action}), do: "HTTP request"
  defp node_title(%Node{type: :stop}), do: "Stop"
  defp node_title(%Node{}), do: "Step"

  defp node_detail(%Node{id: id}), do: "ID #{short_id(id)}"

  defp branch_label(:if_true), do: "If true"
  defp branch_label(:if_false), do: "If false"
  defp branch_label(:approved), do: "Approved"
  defp branch_label(:rejected), do: "Rejected"
  defp branch_label(:timed_out), do: "Timed out"
  defp branch_label(other), do: other |> to_string() |> String.replace("_", " ")

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: "—"
end
