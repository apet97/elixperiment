defmodule PumbleAutomationWeb.ExecutionComponents do
  @moduledoc """
  Execution list chrome, sanitized timeline cards, and operator confirmations.
  """
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.CopyComponents

  alias PumbleAutomation.Executions.Execution

  attr :form, :any, required: true
  attr :workflows, :list, required: true

  def filter_bar(assigns) do
    ~H"""
    <.form
      for={@form}
      id="execution-filter-form"
      phx-change="filter"
      phx-submit="filter"
      class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
    >
      <.input
        field={@form[:workflow_id]}
        type="select"
        label="Workflow"
        prompt="All workflows"
        options={Enum.map(@workflows, &{&1.name, &1.id})}
      />
      <.input
        field={@form[:status]}
        type="select"
        label="Status"
        prompt="All statuses"
        options={status_options()}
      />
      <.input field={@form[:from]} type="datetime-local" label="From" />
      <.input field={@form[:until]} type="datetime-local" label="Until" />
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :execution, :map, required: true

  def execution_card(assigns) do
    ~H"""
    <article
      id={@id}
      class="rounded-lg border border-line bg-raised p-5 shadow-[0_1px_0_rgba(21,32,40,0.04)] transition-shadow hover:shadow-md"
      data-status={@execution.status}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="truncate text-base font-semibold text-ink">{@execution.workflow_name}</h2>
          <p class="mt-0.5 font-mono text-xs text-muted">{@execution.id}</p>
        </div>
        <.status_badge
          id={"execution-status-#{@execution.id}"}
          tone={status_tone(@execution.status)}
          label={status_label(@execution.status)}
        />
      </div>

      <dl class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.meta title="Version">
          <.link
            navigate={~p"/workflows/#{@execution.workflow_id}"}
            id={"execution-version-#{@execution.id}"}
            class="text-sm font-medium text-signal hover:text-signal-strong"
          >
            Version {@execution.version_number}
          </.link>
        </.meta>
        <.meta title="Trigger">{@execution.trigger_summary}</.meta>
        <.meta title="Node">{node_text(@execution)}</.meta>
        <.meta title="Started">{time_text(@execution.inserted_at)}</.meta>
      </dl>

      <div class="mt-4">
        <.button
          id={"execution-open-#{@execution.id}"}
          variant="secondary"
          navigate={~p"/executions/#{@execution.id}"}
        >
          Open timeline
        </.button>
      </div>
    </article>
    """
  end

  attr :execution, :map, required: true
  attr :trigger, :list, required: true
  attr :terminal_reason, :any, required: true

  def execution_header(assigns) do
    ~H"""
    <section id="execution-summary" class="rounded-lg border border-line bg-raised p-5">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="truncate text-base font-semibold text-ink">{@execution.workflow_name}</h2>
          <p class="mt-1 text-sm text-muted">
            Immutable version {@execution.version_number}. This is not the mutable draft.
          </p>
        </div>
        <.status_badge
          id="execution-show-status"
          tone={status_tone(@execution.status)}
          label={status_label(@execution.status)}
        />
      </div>

      <div class="mt-4 flex flex-wrap gap-3">
        <.link
          navigate={~p"/executions"}
          id="execution-back"
          class="text-sm font-medium text-signal hover:text-signal-strong"
        >
          Back to executions
        </.link>
        <.link
          navigate={~p"/workflows/#{@execution.workflow_id}"}
          id="execution-version-link"
          class="text-sm font-medium text-signal hover:text-signal-strong"
        >
          Version {@execution.version_number}
        </.link>
      </div>

      <div id="execution-copy-fields" class="mt-4 grid gap-3 sm:grid-cols-2">
        <.copy_field id="execution-id" label="Execution ID" value={@execution.id} />
        <.copy_field id="execution-key" label="Execution key" value={@execution.execution_key} />
        <.copy_field
          :if={@execution.correlation_id}
          id="correlation-id"
          label="Correlation ID"
          value={@execution.correlation_id}
        />
      </div>

      <div :if={@trigger != []} id="execution-trigger" class="mt-5 border-t border-line pt-4">
        <h3 class="text-sm font-semibold text-ink">Trigger</h3>
        <.pair_list id="execution-trigger-fields" pairs={@trigger} />
      </div>

      <p :if={@terminal_reason} id="execution-terminal-reason" class="mt-4 text-sm text-ink">
        {@terminal_reason}
      </p>
    </section>
    """
  end

  attr :steps, :list, required: true

  def timeline(assigns) do
    ~H"""
    <section id="execution-timeline" class="space-y-3">
      <h2 class="text-base font-semibold text-ink">Timeline</h2>
      <p class="text-sm text-muted">
        Sanitized step history. Secret values and raw message text are not shown.
      </p>

      <div :if={@steps == []} id="execution-timeline-empty" class="text-sm text-muted">
        No steps have been recorded yet.
      </div>

      <article
        :for={step <- @steps}
        id={"step-#{step.node_id}"}
        data-node-type={step.node_type}
        data-status={step.status}
        class="rounded-lg border border-line bg-raised p-4"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 class="text-sm font-semibold text-ink">{step.node_type}</h3>
            <p class="font-mono text-xs text-muted">{step.node_id}</p>
          </div>
          <.status_badge
            id={"step-status-#{step.node_id}"}
            tone={status_tone(step.status)}
            label={status_label(step.status)}
          />
        </div>

        <dl class="mt-3 grid gap-3 sm:grid-cols-2">
          <.meta title="Attempts">{step.attempt_count}</.meta>
          <.meta :if={step.selected_edge} title="Branch">{step.selected_edge}</.meta>
          <.meta :if={step.remote_reference} title="Provider ID">{step.remote_reference}</.meta>
          <.meta :if={step.resume_at} title="Wait until">{step.resume_at}</.meta>
          <.meta :if={step.expires_at} title="Approval deadline">{step.expires_at}</.meta>
          <.meta :if={step.uncertainty_reason} title="Uncertainty">{step.uncertainty_reason}</.meta>
        </dl>

        <.pair_list
          :if={step.output_pairs != []}
          id={"step-output-#{step.node_id}"}
          pairs={step.output_pairs}
        />

        <ol :if={step.attempts != []} id={"step-attempts-#{step.node_id}"} class="mt-3 space-y-2">
          <li
            :for={attempt <- step.attempts}
            id={"attempt-#{step.node_id}-#{attempt.attempt_number}"}
            data-status={attempt.status}
            class="rounded-md border border-line bg-surface px-3 py-2 text-sm"
          >
            <p class="font-medium text-ink">
              Attempt {attempt.attempt_number} · {status_label(attempt.status)}
            </p>
            <p :if={attempt.error_class} class="text-xs text-muted">
              {[attempt.error_class, attempt.error_code] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
            </p>
            <p :if={attempt.remote_request_id} class="font-mono text-xs text-muted">
              {attempt.remote_request_id}
            </p>
            <p :if={attempt.retry_at} class="text-xs text-muted">
              Retry at {time_text(attempt.retry_at)}
            </p>
            <dl
              :if={attempt.diagnostics != %{} or not is_nil(attempt.duration_ms)}
              id={"attempt-diagnostics-#{step.node_id}-#{attempt.attempt_number}"}
              class="mt-3 grid gap-2 border-t border-line pt-3 sm:grid-cols-2"
            >
              <.meta :if={attempt.diagnostics["effect_key"]} title="Effect key">
                <span class="break-all font-mono text-xs">
                  {attempt.diagnostics["effect_key"]}
                </span>
              </.meta>
              <.meta :if={request_summary(attempt.diagnostics)} title="Request summary">
                {request_summary(attempt.diagnostics)}
              </.meta>
              <.meta :if={attempt.diagnostics["dispatch_state"]} title="Dispatch evidence">
                {dispatch_state(attempt.diagnostics["dispatch_state"])}
              </.meta>
              <.meta
                :if={Map.has_key?(attempt.diagnostics, "bytes_may_have_left")}
                title="Bytes may have left"
              >
                {yes_no(attempt.diagnostics["bytes_may_have_left"])}
              </.meta>
              <.meta :if={not is_nil(attempt.duration_ms)} title="Duration">
                {attempt.duration_ms} ms
              </.meta>
              <.meta :if={attempt.diagnostics["guidance"]} title="Operator guidance">
                {attempt.diagnostics["guidance"]}
              </.meta>
            </dl>
          </li>
        </ol>

        <div
          :if={step.approval}
          id={"step-approval-#{step.node_id}"}
          data-status={step.approval.status}
          class="mt-3 rounded-md border border-line bg-surface px-3 py-2 text-sm"
        >
          <p class="font-medium text-ink">Approval · {status_label(step.approval.status)}</p>
          <p :if={step.approval.expires_at} class="text-xs text-muted">
            Expires {time_text(step.approval.expires_at)}
          </p>
          <p :if={step.approval.decided_at} class="text-xs text-muted">
            Decided {time_text(step.approval.decided_at)}
          </p>
          <p :if={step.approval.pumble_message_id} class="font-mono text-xs text-muted">
            {step.approval.pumble_message_id}
          </p>
        </div>
      </article>
    </section>
    """
  end

  attr :can_cancel, :boolean, required: true
  attr :can_resolve, :boolean, required: true
  attr :cancellable?, :boolean, required: true
  attr :resolvable?, :boolean, required: true

  def operator_controls(assigns) do
    ~H"""
    <section id="execution-controls" class="rounded-lg border border-line bg-raised p-5">
      <h2 class="text-base font-semibold text-ink">Operator controls</h2>
      <p class="mt-1 text-sm text-muted">
        Actions go through the execution engine. This page never edits rows directly.
      </p>

      <div class="mt-4 flex flex-wrap gap-2">
        <.button
          :if={@can_cancel and @cancellable?}
          id="cancel-prompt"
          variant="danger"
          type="button"
          phx-click="confirm_cancel"
        >
          Cancel execution
        </.button>
        <.button
          :if={@can_resolve and @resolvable?}
          id="resolve-succeeded-prompt"
          variant="secondary"
          type="button"
          phx-click="confirm_resolve"
          phx-value-choice="succeeded"
        >
          Mark succeeded
        </.button>
        <.button
          :if={@can_resolve and @resolvable?}
          id="resolve-failed-prompt"
          variant="secondary"
          type="button"
          phx-click="confirm_resolve"
          phx-value-choice="failed"
        >
          Mark failed
        </.button>
        <.button
          :if={@can_resolve and @resolvable?}
          id="resolve-retry-prompt"
          variant="primary"
          type="button"
          phx-click="confirm_resolve"
          phx-value-choice="retry"
        >
          Retry with duplicate risk
        </.button>
      </div>

      <p
        :if={!@can_cancel and !@can_resolve}
        id="execution-controls-readonly"
        class="mt-3 text-sm text-muted"
      >
        Viewers can inspect sanitized history. An editor can cancel; only an owner can resolve uncertainty.
      </p>
    </section>
    """
  end

  attr :confirm, :map, required: true
  attr :retry_form, :any, default: nil

  def confirm_dialog(%{confirm: %{kind: :cancel}} = assigns) do
    ~H"""
    <.confirm_shell id="cancel-confirm" title="Cancel this execution?">
      <p class="text-sm text-muted">
        Waiting, queued, and paused runs stop immediately. A request already in
        flight is not revoked; the engine will not start the next step.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="cancel-dismiss" variant="ghost" type="button" phx-click="cancel_confirm">
          Keep running
        </.button>
        <.button id="cancel-submit" variant="danger" type="button" phx-click="cancel">
          Cancel execution
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  def confirm_dialog(%{confirm: %{kind: :resolve, choice: "retry"}} = assigns) do
    ~H"""
    <.confirm_shell id="uncertain-retry-confirm" title="Retry this uncertain write?">
      <p id="uncertain-retry-risk" class="text-sm text-muted">
        The remote write may already have succeeded. Retrying can deliver the same
        effect twice. Retrying an uncertain write requires acknowledging the duplicate risk.
      </p>
      <.form
        for={@retry_form}
        id="uncertain-retry-form"
        phx-submit="resolve"
        class="mt-4 space-y-3"
      >
        <input type="hidden" name="choice" value="retry" />
        <.input
          field={@retry_form[:acknowledge_duplicate_risk]}
          type="checkbox"
          label="I acknowledge the duplicate risk"
          id="uncertain-retry-acknowledge"
        />
        <div class="flex justify-end gap-2">
          <.button
            id="uncertain-retry-dismiss"
            variant="ghost"
            type="button"
            phx-click="cancel_confirm"
          >
            Do not retry
          </.button>
          <.button id="uncertain-retry-submit" variant="primary" type="submit">
            Retry now
          </.button>
        </div>
      </.form>
    </.confirm_shell>
    """
  end

  def confirm_dialog(%{confirm: %{kind: :resolve, choice: choice}} = assigns) do
    assigns = assign(assigns, :choice, choice)

    ~H"""
    <.confirm_shell
      id={"uncertain-#{@choice}-confirm"}
      title={resolve_title(@choice)}
    >
      <p class="text-sm text-muted">{resolve_copy(@choice)}</p>
      <div class="mt-4 flex justify-end gap-2">
        <.button
          id={"uncertain-#{@choice}-dismiss"}
          variant="ghost"
          type="button"
          phx-click="cancel_confirm"
        >
          Keep paused
        </.button>
        <.button
          id={"uncertain-#{@choice}-submit"}
          variant="primary"
          type="button"
          phx-click="resolve"
          phx-value-choice={@choice}
        >
          Confirm
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

  attr :id, :string, required: true
  attr :pairs, :list, required: true

  defp pair_list(assigns) do
    ~H"""
    <dl id={@id} class="mt-3 grid gap-3 sm:grid-cols-2">
      <div :for={{label, value} <- @pairs}>
        <dt class="text-xs font-medium uppercase tracking-wide text-muted">{label}</dt>
        <dd class="mt-1 break-all font-mono text-xs text-ink">{value}</dd>
      </div>
    </dl>
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
    Enum.map(Execution.statuses(), &{status_label(&1), &1})
  end

  defp status_tone("completed"), do: "ok"
  defp status_tone("running"), do: "info"
  defp status_tone("queued"), do: "neutral"
  defp status_tone("waiting_delay"), do: "warn"
  defp status_tone("waiting_approval"), do: "warn"
  defp status_tone("paused_uncertain"), do: "warn"
  defp status_tone("failed"), do: "danger"
  defp status_tone("cancelled"), do: "danger"
  defp status_tone(_status), do: "neutral"

  defp status_label("queued"), do: "Queued"
  defp status_label("running"), do: "Running"
  defp status_label("waiting_delay"), do: "Waiting (delay)"
  defp status_label("waiting_approval"), do: "Waiting (approval)"
  defp status_label("paused_uncertain"), do: "Paused (uncertain)"
  defp status_label("completed"), do: "Completed"
  defp status_label("failed"), do: "Failed"
  defp status_label("cancelled"), do: "Cancelled"
  defp status_label("succeeded"), do: "Succeeded"
  defp status_label("started"), do: "Started"
  defp status_label("uncertain"), do: "Uncertain"
  defp status_label("pending"), do: "Pending"
  defp status_label("approved"), do: "Approved"
  defp status_label("rejected"), do: "Rejected"
  defp status_label("timed_out"), do: "Timed out"
  defp status_label(other) when is_binary(other), do: other

  defp node_text(%{current_node_type: type, current_node_id: id})
       when is_binary(type) and is_binary(id),
       do: "#{type}"

  defp node_text(%{current_node_id: id}) when is_binary(id), do: id
  defp node_text(_row), do: "—"

  defp time_text(nil), do: "—"
  defp time_text(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  defp time_text(value) when is_binary(value), do: value
  defp time_text(_other), do: "—"

  defp request_summary(diagnostics) when is_map(diagnostics) do
    diagnostics["request_summary"] || diagnostics["operation"]
  end

  defp request_summary(_diagnostics), do: nil

  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"
  defp yes_no(_value), do: "Unknown"

  defp dispatch_state("confirmed"), do: "Confirmed"
  defp dispatch_state("not_sent"), do: "Not sent"
  defp dispatch_state("possibly_sent"), do: "Possibly sent"
  defp dispatch_state(_state), do: "Unknown"

  defp resolve_title("succeeded"), do: "Mark this effect succeeded?"
  defp resolve_title("failed"), do: "Mark this effect failed?"
  defp resolve_title(_choice), do: "Resolve this pause?"

  defp resolve_copy("succeeded"),
    do:
      "The engine will treat the write as done and continue or complete from the compiled graph."

  defp resolve_copy("failed"),
    do: "The execution will fail. This does not retry the remote write."

  defp resolve_copy(_choice), do: "This resolution is audited and owner-only."
end
