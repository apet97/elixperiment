defmodule PumbleAutomationWeb.WorkflowComponents do
  @moduledoc """
  Workflow list chrome: filters, cards, creation modal, and confirmations.
  """
  use PumbleAutomationWeb, :html

  attr :form, :any, required: true

  def filter_bar(assigns) do
    ~H"""
    <.form
      for={@form}
      id="workflow-filter-form"
      phx-change="filter"
      phx-submit="filter"
      class="flex flex-col gap-3 sm:flex-row sm:items-end"
    >
      <div class="min-w-0 flex-1">
        <.input
          field={@form[:q]}
          type="search"
          label="Search"
          placeholder="Name or alias"
          phx-debounce="300"
        />
      </div>
      <div class="sm:w-48">
        <.input
          field={@form[:status]}
          type="select"
          label="Status"
          prompt="All statuses"
          options={status_options()}
        />
      </div>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :workflow, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :can_activate, :boolean, required: true
  attr :can_delete, :boolean, required: true

  def workflow_card(assigns) do
    ~H"""
    <article
      id={@id}
      class="rounded-lg border border-line bg-raised p-5 shadow-[0_1px_0_rgba(21,32,40,0.04)] transition-shadow hover:shadow-md"
      data-status={@workflow.status}
      data-validation={@workflow.validation_state}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="truncate text-base font-semibold text-ink">{@workflow.name}</h2>
          <p :if={@workflow.slug} class="mt-0.5 font-mono text-xs text-muted">/{@workflow.slug}</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <.status_badge
            id={"workflow-status-#{@workflow.id}"}
            tone={status_tone(@workflow.status)}
            label={status_label(@workflow.status)}
          />
          <.status_badge
            id={"workflow-validation-#{@workflow.id}"}
            tone={validation_tone(@workflow.validation_state)}
            label={validation_label(@workflow.validation_state)}
          />
        </div>
      </div>

      <dl class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.meta title="Active version">{version_text(@workflow.active_version_number)}</.meta>
        <.meta title="Trigger">{@workflow.trigger_summary}</.meta>
        <.meta title="Last execution">{execution_text(@workflow)}</.meta>
        <.meta title="Next schedule">{time_text(@workflow.next_run_at)}</.meta>
        <.meta title="Updated">{updated_text(@workflow)}</.meta>
      </dl>

      <div class="mt-4 flex flex-wrap gap-2">
        <.button
          id={"workflow-review-#{@workflow.id}"}
          variant="secondary"
          navigate={~p"/workflows/#{@workflow.id}"}
        >
          Review
        </.button>
        <.button
          id={"workflow-edit-#{@workflow.id}"}
          variant="secondary"
          navigate={~p"/workflows/#{@workflow.id}/edit"}
        >
          Open editor
        </.button>
        <.button
          :if={@can_manage}
          id={"workflow-duplicate-#{@workflow.id}"}
          variant="secondary"
          phx-click="duplicate"
          phx-value-id={@workflow.id}
        >
          Duplicate
        </.button>
        <.button
          :if={@can_activate and @workflow.status == "active"}
          id={"workflow-deactivate-#{@workflow.id}"}
          variant="ghost"
          phx-click="confirm_deactivate"
          phx-value-id={@workflow.id}
        >
          Deactivate
        </.button>
        <.button
          :if={@can_delete and @workflow.status == "draft"}
          id={"workflow-delete-#{@workflow.id}"}
          variant="danger"
          phx-click="confirm_delete"
          phx-value-id={@workflow.id}
        >
          Delete draft
        </.button>
      </div>
    </article>
    """
  end

  attr :form, :any, required: true
  attr :templates, :list, required: true

  def create_modal(assigns) do
    ~H"""
    <.modal
      id="workflow-create-modal"
      title="Create a workflow"
      on_cancel={JS.patch(~p"/workflows")}
      class="max-w-lg"
    >
      <p class="text-sm text-muted">
        Start from a blank draft or a first-party template. Templates are ordinary
        editable definitions.
      </p>

      <.form for={@form} id="workflow-create-form" phx-change="validate" phx-submit="create">
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input field={@form[:slug]} type="text" label="Manual alias" placeholder="optional" />
        <.input field={@form[:description]} type="textarea" label="Description" />

        <fieldset id="workflow-template-picker" class="mb-4">
          <legend class="mb-2 text-sm font-medium text-ink">Start from</legend>
          <div class="space-y-2">
            <label
              :for={template <- @templates}
              id={"template-#{template.id}"}
              class="flex cursor-pointer gap-3 rounded-md border border-line bg-surface px-3 py-2 hover:border-signal"
            >
              <input
                type="radio"
                name={@form[:template].name}
                id={"workflow_template_#{template.id}"}
                value={template.id}
                checked={to_string(@form[:template].value) == template.id}
                class="mt-1 size-4"
              />
              <span>
                <span class="block text-sm font-semibold text-ink">{template.name}</span>
                <span class="block text-xs text-muted">{template.summary}</span>
              </span>
            </label>
          </div>
        </fieldset>

        <div class="flex justify-end gap-2">
          <.button
            id="workflow-create-cancel"
            variant="ghost"
            type="button"
            patch={~p"/workflows"}
          >
            Cancel
          </.button>
          <.button id="workflow-create-submit" variant="primary" type="submit">
            Create draft
          </.button>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :confirm, :map, required: true

  def confirm_dialog(%{confirm: %{action: :deactivate}} = assigns) do
    ~H"""
    <.confirm_shell id="workflow-confirm-deactivate" title="Deactivate this workflow?">
      <p class="text-sm text-muted">
        New runs will not start. {@confirm.workflow.occupying_count}
        {run_noun(@confirm.workflow.occupying_count)} already in progress may continue
        until they finish.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="workflow-cancel-confirm" variant="ghost" type="button" phx-click="cancel_confirm">
          Keep running
        </.button>
        <.button
          id="workflow-confirm-deactivate-submit"
          variant="danger"
          type="button"
          phx-click="deactivate"
          phx-value-id={@confirm.workflow.id}
        >
          Deactivate
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  def confirm_dialog(%{confirm: %{action: :delete}} = assigns) do
    ~H"""
    <.confirm_shell id="workflow-confirm-delete" title="Delete this draft?">
      <p class="text-sm text-muted">
        This removes the draft permanently. It cannot be undone. Only drafts that
        have never been activated can be deleted.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="workflow-cancel-confirm" variant="ghost" type="button" phx-click="cancel_confirm">
          Keep draft
        </.button>
        <.button
          id="workflow-confirm-delete-submit"
          variant="danger"
          type="button"
          phx-click="delete_draft"
          phx-value-id={@confirm.workflow.id}
        >
          Delete draft
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp confirm_shell(assigns) do
    ~H"""
    <.modal id={@id} title={@title} on_cancel="cancel_confirm">
      {render_slot(@inner_block)}
    </.modal>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp meta(assigns) do
    ~H"""
    <div>
      <dt class="text-xs font-medium uppercase tracking-wide text-muted">{@title}</dt>
      <dd class="mt-1 text-sm text-ink">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp status_options do
    [
      {"Draft", "draft"},
      {"Active", "active"},
      {"Inactive", "inactive"},
      {"Archived", "archived"}
    ]
  end

  defp status_tone("active"), do: "ok"
  defp status_tone("inactive"), do: "warn"
  defp status_tone("archived"), do: "neutral"
  defp status_tone(_status), do: "info"

  defp status_label("draft"), do: "Draft"
  defp status_label("active"), do: "Active"
  defp status_label("inactive"), do: "Inactive"
  defp status_label("archived"), do: "Archived"
  defp status_label(other) when is_binary(other), do: other

  defp validation_tone("live"), do: "ok"
  defp validation_tone("draft"), do: "info"
  defp validation_tone(_state), do: "neutral"

  defp validation_label("live"), do: "Validated"
  defp validation_label("draft"), do: "Draft definition"
  defp validation_label(_state), do: "No draft"

  defp version_text(nil), do: "—"
  defp version_text(number) when is_integer(number), do: "v#{number}"

  defp execution_text(%{last_execution_status: nil}), do: "—"

  defp execution_text(workflow) do
    "#{workflow.last_execution_status} · #{time_text(workflow.last_execution_at)}"
  end

  defp updated_text(workflow) do
    [workflow.updated_by_label, time_text(workflow.updated_at)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp time_text(nil), do: "—"
  defp time_text(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  defp time_text(_other), do: "—"

  defp run_noun(1), do: "run"
  defp run_noun(_count), do: "runs"
end
