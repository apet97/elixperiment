defmodule PumbleAutomationWeb.WorkflowLive.Show do
  @moduledoc """
  Validation, dry-run, activation, and version controls for one workflow.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.WorkflowLive.ValidationComponent
  import PumbleAutomationWeb.WorkflowLive.VersionComponent
  import PumbleAutomationWeb.CopyComponents

  alias PumbleAutomation.Connections
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.DryRun
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Ingress.ManualTrigger
  alias PumbleAutomation.Ingress.RateLimiter
  alias PumbleAutomation.Installations.Members
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Dependencies
  alias PumbleAutomation.Workflows.StarterTemplates
  alias PumbleAutomation.Workflows.ValidationIssue
  alias PumbleAutomation.Workflows.Validator
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomationWeb.WorkflowLive.VersionComponent

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:nav_current, :workflows)
     |> assign(:page_ready, false)
     |> assign(:workflow, nil)
     |> assign(:definition, StarterTemplates.blank())
     |> assign(:issues, [])
     |> assign(:validated?, false)
     |> assign(:focused_id, nil)
     |> assign(:dry_run_form, dry_run_form())
     |> assign(:dry_run_result, nil)
     |> assign(:versions, [])
     |> assign(:selected_version, nil)
     |> assign(:version_diff, [])
     |> assign(:creators, %{})
     |> assign(:confirm, nil)
     |> assign(:webhook_reveal, nil)
     |> assign(:active_webhook?, false)
     |> assign(:active_webhook_signature?, false)
     |> assign(:can_manage, Policy.can?(scope, :manage_workflows))
     |> assign(:can_activate, Policy.can?(scope, :activate_workflows))
     |> assign(:can_test, Policy.can?(scope, :test_workflows))}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    socket = load_workflow(socket, id)

    socket =
      case Map.get(params, "focus") do
        key when is_binary(key) and key != "" -> assign(socket, :focused_id, key)
        _missing -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_installation={@current_installation}
      current_member={@current_member}
      nav_current={@nav_current}
    >
      <.loading_state :if={not @page_ready} id="workflow-show-loading" label="Loading workflow" />
      <div :if={@page_ready} id="workflow-show">
        <.header>
          {@workflow.name}
          <:subtitle>
            Prove the saved draft, preview it, and activate a version without bypassing the compiler.
          </:subtitle>
          <:actions>
            <.status_badge
              id="workflow-show-status"
              tone={status_tone(@workflow.status)}
              label={status_label(@workflow.status)}
            />
          </:actions>
        </.header>

        <div class="mb-4 flex flex-wrap gap-3">
          <.link
            navigate={~p"/workflows"}
            id="show-back"
            class="text-sm font-medium text-signal hover:text-signal-strong"
          >
            Back to workflows
          </.link>
          <.link
            navigate={~p"/workflows/#{@workflow.id}/edit"}
            id="show-edit"
            class="text-sm font-medium text-signal hover:text-signal-strong"
          >
            Open editor
          </.link>
        </div>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]">
          <div class="space-y-6">
            <.validation_cards definition={@definition} focused_id={@focused_id} />
            <.validation_panel
              issues={@issues}
              validated?={@validated?}
              can_validate={true}
              focused_id={@focused_id}
            />
          </div>

          <div class="space-y-6">
            <.dry_run_section form={@dry_run_form} result={@dry_run_result} definition={@definition} />
            <.live_test_section workflow={@workflow} can_test={@can_test} />
            <.activation_section
              workflow={@workflow}
              can_activate={@can_activate}
            />
            <.webhook_credentials_section :if={@webhook_reveal} reveal={@webhook_reveal} />
            <.webhook_credentials_status
              :if={@active_webhook? and is_nil(@webhook_reveal)}
              require_signature={@active_webhook_signature?}
            />
            <.version_history
              versions={@versions}
              active_version_id={@workflow.active_version_id}
              selected={@selected_version}
              diff={@version_diff}
              can_activate={@can_activate}
              creators={@creators}
            />
          </div>
        </div>
      </div>

      <.confirm_dialog :if={@confirm} confirm={@confirm} />
    </Layouts.app>
    """
  end

  attr :reveal, :map, required: true

  defp webhook_credentials_section(assigns) do
    ~H"""
    <section id="webhook-credentials-reveal" class="rounded-lg border border-warn bg-raised p-5">
      <h2 class="text-base font-semibold text-ink">Copy webhook credentials now</h2>
      <p class="mt-1 text-sm text-muted">
        These values are shown once. Store them only in the caller's private secret store.
      </p>
      <p
        id="activated-webhook-reveal-status"
        role="status"
        aria-live="polite"
        aria-atomic="true"
        class="sr-only"
      >
        New webhook credentials are ready to copy.
      </p>
      <div class="mt-4 space-y-3">
        <.copy_field id="activated-webhook-url" label="Endpoint URL" value={@reveal.url} />
        <.copy_field
          id="activated-webhook-token"
          label="Bearer token"
          value={@reveal.token}
          type="password"
          autocomplete="off"
        />
        <.copy_field
          :if={@reveal.signing_secret}
          id="activated-webhook-signing-secret"
          label="HMAC signing secret"
          value={@reveal.signing_secret}
          type="password"
          autocomplete="off"
        >
          <:help>
            Send <code>{@reveal.signature_header}</code>
            as <code>sha256=&lt;lowercase hex&gt;</code>
            over the exact request-body bytes.
          </:help>
        </.copy_field>
      </div>
      <.button
        id="dismiss-activated-webhook-credentials"
        variant="ghost"
        type="button"
        phx-click="dismiss_webhook_credentials"
        class="mt-3"
      >
        I have copied them
      </.button>
    </section>
    """
  end

  attr :require_signature, :boolean, required: true

  defp webhook_credentials_status(assigns) do
    ~H"""
    <section
      id="webhook-credentials-required"
      role="status"
      aria-labelledby="webhook-credentials-required-title"
      class="rounded-lg border border-line bg-raised p-5"
    >
      <h2 id="webhook-credentials-required-title" class="text-base font-semibold text-ink">
        Webhook credentials are hidden
      </h2>
      <p id="webhook-credentials-required-message" class="mt-1 text-sm text-muted">
        Credentials for this active endpoint already exist and are not shown again.
        <span :if={@require_signature}>
          Caller setup uses the endpoint URL, bearer token, and HMAC signing secret.
        </span>
        <span :if={!@require_signature}>
          Caller setup uses the endpoint URL and bearer token. This endpoint does not require
          an HMAC signing secret.
        </span>
        If a stored set is available, keep using it. If not, ask an owner to rotate the
        credentials in Settings and copy a new set. Rotation is only for lost or compromised
        credentials.
      </p>
      <.link
        navigate={~p"/settings"}
        id="webhook-credentials-settings-link"
        class="mt-3 inline-flex text-sm font-medium text-signal transition hover:text-signal-strong"
      >
        Open webhook settings
      </.link>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :result, :any, required: true
  attr :definition, :map, required: true

  defp dry_run_section(assigns) do
    assigns = assign(assigns, :has_approval, has_approval?(assigns.definition))

    ~H"""
    <section id="dry-run" class="rounded-lg border border-line bg-raised p-5">
      <h2 class="text-base font-semibold text-ink">Dry-run</h2>
      <p class="mt-1 text-sm text-muted">
        Walks the compiled graph in memory. No credentials, network, jobs, or rows.
        This is not a live test.
      </p>

      <.form
        for={@form}
        id="dry-run-form"
        phx-change="dry_run_validate"
        phx-submit="dry_run"
        class="mt-4 space-y-3"
      >
        <.input
          field={@form[:sample]}
          type="textarea"
          label="Sample trigger data"
          id="dry-run-sample"
        />
        <.input
          :if={@has_approval}
          field={@form[:approval_edge]}
          type="select"
          label="Approval preview edge"
          id="dry-run-approval-edge"
          options={[
            {"Approved", "approved"},
            {"Rejected", "rejected"},
            {"Timed out", "timed_out"}
          ]}
        />
        <.button id="dry-run-submit" variant="secondary" type="submit">
          Preview dry-run
        </.button>
      </.form>

      <div :if={@result} id="dry-run-trace" class="mt-4 space-y-3" data-status={@result.status}>
        <.status_badge
          id="dry-run-status"
          tone={if(@result.status == "completed", do: "info", else: "warn")}
          label={@result.status}
        />
        <p class="text-xs text-muted">
          A completed preview is not a proof the live workflow will succeed.
        </p>
        <ol id="dry-run-steps" class="space-y-2">
          <li
            :for={{step, index} <- Enum.with_index(@result.trace, 1)}
            id={"dry-run-step-#{index}"}
            data-node-id={step["node_id"]}
            data-kind={step["kind"]}
            class="rounded-md border border-line bg-surface px-3 py-2 text-sm"
          >
            <p class="font-semibold text-ink">
              {index}. {step["type"]} · {step["kind"]}
            </p>
            <p :if={step["edge"]} class="text-xs text-muted">Edge {step["edge"]}</p>
            <p :if={step["would_send"]} class="mt-1 font-mono text-xs text-muted">
              {would_send_text(step["would_send"])}
            </p>
          </li>
        </ol>
      </div>
    </section>
    """
  end

  attr :workflow, :map, required: true
  attr :can_test, :boolean, required: true

  defp live_test_section(assigns) do
    ~H"""
    <section id="live-test" class="rounded-lg border border-line bg-raised p-5">
      <h2 class="text-base font-semibold text-ink">Live test</h2>
      <p class="mt-1 text-sm text-muted">
        Starts a real execution of the <span class="font-semibold">active</span>
        version. Side effects can occur. This is distinct from dry-run.
      </p>
      <p :if={@workflow.status != "active"} id="live-test-inactive" class="mt-3 text-sm text-muted">
        Activate a version before running a live test.
      </p>
      <.button
        :if={@can_test and @workflow.status == "active"}
        id="live-test-prompt"
        variant="primary"
        type="button"
        phx-click="confirm_live_test"
      >
        Run live test
      </.button>
      <p :if={!@can_test} id="live-test-denied" class="mt-3 text-sm text-muted">
        An editor or owner can run a live test.
      </p>
    </section>
    """
  end

  attr :workflow, :map, required: true
  attr :can_activate, :boolean, required: true

  defp activation_section(assigns) do
    ~H"""
    <section id="activation" class="rounded-lg border border-line bg-raised p-5">
      <h2 class="text-base font-semibold text-ink">Activation</h2>
      <p class="mt-1 text-sm text-muted">
        Uses the activation service with this draft revision. Failure leaves the
        previous live version intact.
      </p>
      <p id="activation-revision" class="mt-2 font-mono text-xs text-muted">
        Draft revision {@workflow.draft_revision}
      </p>
      <div class="mt-3 flex flex-wrap gap-2">
        <.button
          :if={@can_activate}
          id="activate-prompt"
          variant="primary"
          type="button"
          phx-click="confirm_activate"
        >
          Activate draft
        </.button>
        <.button
          :if={@can_activate and @workflow.status == "active"}
          id="deactivate-prompt"
          variant="ghost"
          type="button"
          phx-click="confirm_deactivate"
        >
          Deactivate
        </.button>
      </div>
      <p :if={!@can_activate} id="activation-denied" class="mt-3 text-sm text-muted">
        An editor or owner can activate or deactivate this workflow.
      </p>
    </section>
    """
  end

  attr :confirm, :map, required: true

  defp confirm_dialog(%{confirm: %{kind: :activate}} = assigns) do
    preview = assigns.confirm.preview

    assigns = assign(assigns, :preview, preview)

    ~H"""
    <.confirm_shell id="activate-confirm" title="Activate this draft?">
      <p class="text-sm text-muted">
        New inbound work will run this version. In-flight executions keep the version
        they already started.
      </p>
      <.preview_facts preview={@preview} />
      <div class="mt-4 flex justify-end gap-2">
        <.button id="activate-cancel" variant="ghost" type="button" phx-click="cancel_confirm">
          Cancel
        </.button>
        <.button id="activate-submit" variant="primary" type="button" phx-click="activate">
          Activate
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  defp confirm_dialog(%{confirm: %{kind: :live_test}} = assigns) do
    ~H"""
    <.confirm_shell id="live-test-confirm" title="Run a live test?">
      <p class="text-sm text-muted">
        This starts a real execution of the active version. It is not a dry-run and
        can cause side effects.
      </p>
      <.preview_facts preview={@confirm.preview} />
      <div class="mt-4 flex justify-end gap-2">
        <.button id="live-test-cancel" variant="ghost" type="button" phx-click="cancel_confirm">
          Cancel
        </.button>
        <.button id="live-test-submit" variant="primary" type="button" phx-click="live_test">
          Start live test
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  defp confirm_dialog(%{confirm: %{kind: :deactivate}} = assigns) do
    ~H"""
    <.confirm_shell id="deactivate-confirm" title="Deactivate this workflow?">
      <p class="text-sm text-muted">
        New runs will not start. In-flight executions are not cancelled.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="deactivate-cancel" variant="ghost" type="button" phx-click="cancel_confirm">
          Keep running
        </.button>
        <.button id="deactivate-submit" variant="danger" type="button" phx-click="deactivate">
          Deactivate
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  defp confirm_dialog(%{confirm: %{kind: :reactivate}} = assigns) do
    ~H"""
    <.confirm_shell
      id="reactivate-confirm"
      title={"Reactivate version #{@confirm.version.version_number}?"}
    >
      <p class="text-sm text-muted">
        The stored program is not rewritten. Current scopes, secrets, and connections
        are checked before the live pointer moves.
      </p>
      <.preview_facts preview={@confirm.preview} />
      <div class="mt-4 flex justify-end gap-2">
        <.button id="reactivate-cancel" variant="ghost" type="button" phx-click="cancel_confirm">
          Cancel
        </.button>
        <.button
          id="reactivate-submit"
          variant="primary"
          type="button"
          phx-click="reactivate"
          phx-value-number={@confirm.version.version_number}
        >
          Reactivate
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
    <.modal id={@id} title={@title} on_cancel="cancel_confirm" class="max-w-lg">
      {render_slot(@inner_block)}
    </.modal>
    """
  end

  attr :preview, :map, required: true

  defp preview_facts(assigns) do
    ~H"""
    <dl class="mt-4 space-y-3 text-sm">
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-muted">Required scopes</dt>
        <dd id="activate-scopes" class="mt-1 text-ink">{list_text(@preview.scopes)}</dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-muted">Connections</dt>
        <dd id="activate-connections" class="mt-1 text-ink">{list_text(@preview.connections)}</dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-muted">Trigger and schedule</dt>
        <dd id="activate-changes" class="mt-1 text-ink">{@preview.change}</dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-muted">Warnings</dt>
        <dd id="activate-warnings" class="mt-1">
          <p :if={@preview.warnings == []} class="text-muted">No warnings.</p>
          <ul :if={@preview.warnings != []} class="list-disc space-y-1 pl-5 text-ink">
            <li :for={warning <- @preview.warnings}>{warning.message}</li>
          </ul>
          <p :if={@preview.warnings != []} class="mt-2 text-xs text-muted">
            Warnings are not a proof of success.
          </p>
        </dd>
      </div>
    </dl>
    """
  end

  @impl true
  def handle_event("validate", _params, socket) do
    case RateLimiter.check_expensive_ui(socket.assigns.scope, :validate) do
      :ok -> {:noreply, socket |> reload_definition() |> run_validation()}
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("focus_issue", %{"key" => key}, socket) do
    {:noreply, assign(socket, :focused_id, key)}
  end

  def handle_event("dry_run_validate", %{"dry_run" => params}, socket) do
    {:noreply, assign(socket, :dry_run_form, dry_run_form(params))}
  end

  def handle_event("dry_run", %{"dry_run" => params}, socket) do
    socket = assign(socket, :dry_run_form, dry_run_form(params))

    with :ok <- RateLimiter.check_expensive_ui(socket.assigns.scope, :dry_run),
         {:ok, sample} <- parse_sample(params["sample"]),
         {:ok, compiled} <- compile_draft(socket.assigns.definition),
         {:ok, result} <-
           DryRun.run(compiled, %{
             sample: sample,
             approval_edge: params["approval_edge"] || "approved",
             workspace: %{id: socket.assigns.scope.installation_id},
             actor: %{id: socket.assigns.scope.member_id}
           }) do
      {:noreply, assign(socket, :dry_run_result, result)}
    else
      {:error, issues} when is_list(issues) ->
        {:noreply,
         socket
         |> assign(:issues, issues)
         |> assign(:validated?, true)
         |> put_flash(:error, "Dry-run needs a draft the compiler accepts.")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("confirm_live_test", _params, socket) do
    with :ok <- require_cap(socket, :test_workflows),
         :ok <- require_active(socket),
         {:ok, preview} <- preview_active(socket) do
      {:noreply, assign(socket, :confirm, %{kind: :live_test, preview: preview})}
    else
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("live_test", _params, socket) do
    with :ok <- require_confirmed(socket, :live_test),
         :ok <- RateLimiter.check_expensive_ui(socket.assigns.scope, :live_test),
         :ok <- require_cap(socket, :test_workflows),
         :ok <- require_active(socket) do
      case ManualTrigger.run_browser(socket.assigns.scope, %{
             workflow_version_id: socket.assigns.workflow.active_version_id,
             run_mode: "live"
           }) do
        {:ok, %Execution{} = execution} ->
          {:noreply,
           socket
           |> assign(:confirm, nil)
           |> put_flash(:info, "Started live test #{String.slice(execution.id, 0, 8)}.")}

        {:error, %Error{} = error} ->
          {:noreply, put_flash(socket, :error, error.message)}
      end
    else
      {:error, :unconfirmed} ->
        {:noreply, socket}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("confirm_activate", _params, socket) do
    case require_cap(socket, :activate_workflows) do
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}

      :ok ->
        case preview_draft(socket) do
          {:ok, preview} ->
            {:noreply, assign(socket, :confirm, %{kind: :activate, preview: preview})}

          {:error, %Error{} = error} ->
            {:noreply, put_flash(socket, :error, error.message)}

          {:error, issues} ->
            {:noreply,
             socket
             |> assign(:issues, issues)
             |> assign(:validated?, true)
             |> put_flash(:error, "This workflow cannot be activated.")}
        end
    end
  end

  def handle_event("activate", _params, socket) do
    with :ok <- require_confirmed(socket, :activate),
         :ok <- RateLimiter.check_expensive_ui(socket.assigns.scope, :activate),
         :ok <- require_cap(socket, :activate_workflows) do
      finish_activation(
        socket,
        Workflows.activate_workflow(
          socket.assigns.scope,
          socket.assigns.workflow.id,
          socket.assigns.workflow.draft_revision
        )
      )
    else
      {:error, :unconfirmed} ->
        {:noreply, socket}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("confirm_deactivate", _params, socket) do
    case require_cap(socket, :activate_workflows) do
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}

      :ok ->
        {:noreply, assign(socket, :confirm, %{kind: :deactivate})}
    end
  end

  def handle_event("deactivate", _params, socket) do
    with :ok <- require_confirmed(socket, :deactivate),
         :ok <- require_cap(socket, :activate_workflows) do
      case Workflows.deactivate_workflow(socket.assigns.scope, socket.assigns.workflow.id) do
        {:ok, _workflow} ->
          {:noreply,
           socket
           |> assign(:confirm, nil)
           |> assign(:webhook_reveal, nil)
           |> put_flash(:info, "Workflow deactivated. In-flight executions were not cancelled.")
           |> load_workflow(socket.assigns.workflow.id)}

        {:error, %Error{} = error} ->
          {:noreply, put_flash(socket, :error, error.message)}
      end
    else
      {:error, :unconfirmed} ->
        {:noreply, socket}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("select_version", %{"number" => number}, socket) do
    case parse_version_number(number) do
      {:ok, version_number} ->
        {:noreply, select_version(socket, version_number)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_reactivate", %{"number" => number}, socket) do
    with :ok <- require_cap(socket, :activate_workflows),
         {:ok, version_number} <- parse_version_number(number),
         {:ok, version} <-
           Workflows.get_version(socket.assigns.scope, socket.assigns.workflow.id, version_number),
         {:ok, preview} <- preview_version(socket, version) do
      {:noreply,
       assign(socket, :confirm, %{kind: :reactivate, version: version, preview: preview})}
    else
      :error ->
        {:noreply, socket}

      {:error, issues} when is_list(issues) ->
        {:noreply,
         socket
         |> assign(:issues, issues)
         |> assign(:validated?, true)
         |> put_flash(:error, "That version cannot be reactivated.")}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("reactivate", %{"number" => number}, socket) do
    with {:ok, version_number} <- parse_version_number(number),
         :ok <- require_confirmed_version(socket, :reactivate, version_number),
         :ok <- RateLimiter.check_expensive_ui(socket.assigns.scope, :activate),
         :ok <- require_cap(socket, :activate_workflows) do
      finish_activation(
        socket,
        Workflows.reactivate_workflow(
          socket.assigns.scope,
          socket.assigns.workflow.id,
          version_number
        )
      )
    else
      :error ->
        {:noreply, socket}

      {:error, :unconfirmed} ->
        {:noreply, socket}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("dismiss_webhook_credentials", _params, socket) do
    {:noreply, assign(socket, :webhook_reveal, nil)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp finish_activation(socket, {:ok, result}) do
    warning_note =
      if result.warnings == [] do
        "Activated version #{result.version.version_number}."
      else
        "Activated version #{result.version.version_number}. Warnings are listed and are not a proof of success."
      end

    {:noreply,
     socket
     |> assign(:confirm, nil)
     |> assign(:webhook_reveal, result.webhook_credentials)
     |> assign(:issues, result.warnings)
     |> assign(:validated?, true)
     |> put_flash(:info, warning_note)
     |> load_workflow(result.workflow.id)}
  end

  defp finish_activation(socket, {:error, %Error{} = error}) do
    issues = activation_issues(error)

    socket = load_workflow(socket, socket.assigns.workflow.id)

    socket =
      if issues == [] do
        socket
      else
        socket
        |> assign(:issues, issues)
        |> assign(:validated?, true)
      end

    {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
  end

  defp load_workflow(socket, id) do
    case Workflows.get_workflow(socket.assigns.scope, id) do
      {:ok, workflow} ->
        case workflow_definition(workflow) do
          {:ok, definition} ->
            socket
            |> assign(:page_title, workflow.name)
            |> assign(:page_ready, true)
            |> assign(:workflow, workflow)
            |> assign(:definition, definition)
            |> assign(:dry_run_result, nil)
            |> assign(:confirm, nil)
            |> assign_versions(workflow)
            |> assign_active_webhook()
            |> run_validation()

          {:error, %Error{} = error} ->
            reject_load(socket, error.message)
        end

      {:error, %Error{} = error} ->
        reject_load(socket, error.message)
    end
  end

  defp reload_definition(socket) do
    case Workflows.get_workflow(socket.assigns.scope, socket.assigns.workflow.id) do
      {:ok, workflow} ->
        case workflow_definition(workflow) do
          {:ok, definition} ->
            socket
            |> assign(:workflow, workflow)
            |> assign(:definition, definition)

          {:error, %Error{} = error} ->
            put_flash(socket, :error, error.message)
        end

      {:error, %Error{} = error} ->
        put_flash(socket, :error, error.message)
    end
  end

  defp workflow_definition(%Workflow{} = workflow) do
    case Workflow.draft(workflow) do
      {:ok, definition} -> {:ok, definition}
      {:error, %Error{code: :draft_not_found}} -> {:ok, StarterTemplates.blank()}
      {:error, %Error{}} = error -> error
    end
  end

  defp run_validation(socket) do
    issues = Validator.validate(socket.assigns.definition)

    socket
    |> assign(:issues, issues)
    |> assign(:validated?, true)
  end

  defp assign_versions(socket, workflow) do
    case Workflows.list_versions(socket.assigns.scope, workflow.id) do
      {:ok, versions} ->
        socket
        |> assign(:versions, versions)
        |> assign(:creators, creator_names(socket.assigns.scope, versions))
        |> restore_selected(versions)

      {:error, %Error{} = error} ->
        put_flash(socket, :error, error.message)
    end
  end

  defp assign_active_webhook(socket) do
    {webhook?, require_signature?} = active_webhook_details(active_source(socket))
    active_webhook? = socket.assigns.workflow.status == "active" and webhook?

    socket
    |> assign(:active_webhook?, active_webhook?)
    |> assign(:active_webhook_signature?, active_webhook? and require_signature?)
  end

  defp active_webhook_details({:ok, source}) when is_map(source) do
    case Definition.decode(source) do
      {:ok, %Definition{trigger: %{type: :webhook, config: config}}} ->
        {true, Map.get(config, :require_signature, false)}

      _other ->
        {false, false}
    end
  end

  defp active_webhook_details(_source), do: {false, false}

  defp restore_selected(socket, versions) do
    case socket.assigns.selected_version do
      %{version_number: number} ->
        if Enum.any?(versions, &(&1.version_number == number)) do
          select_version(socket, number)
        else
          socket |> assign(:selected_version, nil) |> assign(:version_diff, [])
        end

      _missing ->
        socket
    end
  end

  defp select_version(socket, version_number) do
    case Workflows.get_version(socket.assigns.scope, socket.assigns.workflow.id, version_number) do
      {:ok, version} ->
        compare = comparison_source(socket)
        diff = VersionComponent.diff_summary(compare, version.source_definition)

        socket
        |> assign(:selected_version, version)
        |> assign(:version_diff, diff)

      {:error, %Error{} = error} ->
        put_flash(socket, :error, error.message)
    end
  end

  defp comparison_source(socket) do
    case fetch_source(socket, active_version_number(socket)) do
      {:ok, source} when not is_nil(source) -> source
      _other -> Definition.encode(socket.assigns.definition)
    end
  end

  defp preview_draft(socket) do
    issues = Validator.validate(socket.assigns.definition)

    if ValidationIssue.errors?(issues) do
      {:error, issues}
    else
      with {:ok, compiled} <- Compiler.compile(socket.assigns.definition) do
        build_preview(socket, compiled, issues, :draft)
      end
    end
  end

  defp preview_active(socket) do
    case active_version_number(socket) do
      nil ->
        {:error,
         Error.new(:conflict, :not_active,
           message: "Activate a version before running a live test."
         )}

      number ->
        with {:ok, version} <-
               Workflows.get_version(socket.assigns.scope, socket.assigns.workflow.id, number),
             {:ok, compiled} <- compile_stored(version) do
          build_preview(socket, compiled, [], :active)
        end
    end
  end

  defp preview_version(socket, version) do
    case compile_stored(version) do
      {:ok, compiled} -> build_preview(socket, compiled, [], :version)
      {:error, _} = error -> error
    end
  end

  defp compile_stored(version) do
    case version.source_definition do
      source when is_map(source) ->
        case Definition.decode(source) do
          {:ok, definition} -> Compiler.compile(definition)
          {:error, %Error{}} = error -> error
        end

      _missing ->
        {:error,
         Error.new(:validation, :invalid_definition,
           message: "The stored definition is not valid."
         )}
    end
  end

  defp build_preview(socket, compiled, prior_issues, kind) do
    dependencies = Dependencies.calculate(compiled)
    installation = socket.assigns.current_installation
    scope_issues = Dependencies.check(dependencies, installation.bot_scopes || [])

    resolve_issues =
      case Dependencies.resolve(dependencies, socket.assigns.scope.installation_id) do
        {:ok, _resolved} -> []
        {:error, issues} -> issues
      end

    issues = ValidationIssue.sort(prior_issues ++ scope_issues ++ resolve_issues)

    if ValidationIssue.errors?(issues) do
      {:error, issues}
    else
      case draft_change_copy(socket, kind) do
        {:ok, change} ->
          {:ok,
           %{
             scopes: dependencies.required_scopes,
             connections: connection_names(socket, dependencies.connection_ids),
             warnings: Enum.filter(issues, &(&1.severity == :warning)),
             change: change
           }}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp draft_change_copy(socket, :draft) do
    encoded = Definition.encode(socket.assigns.definition)

    case active_source(socket) do
      {:ok, nil} ->
        {:ok,
         "This is the first live version. Trigger: #{trigger_label(get_in(encoded, ["trigger", "type"]))}."}

      {:ok, source} ->
        {:ok,
         VersionComponent.diff_summary(source, encoded)
         |> Enum.join(" ")
         |> Kernel.<>(" Bindings and schedules are replaced atomically.")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp draft_change_copy(socket, kind), do: {:ok, change_copy(socket, kind)}

  defp change_copy(_socket, :active) do
    "Live test uses the active version as it is compiled now. Draft edits are not included."
  end

  defp change_copy(_socket, :version) do
    "Reactivation replaces trigger bindings and schedules for this stored program."
  end

  defp active_source(socket) do
    fetch_source(socket, active_version_number(socket))
  end

  defp fetch_source(_socket, nil), do: {:ok, nil}

  defp fetch_source(socket, number) do
    case Workflows.get_version(socket.assigns.scope, socket.assigns.workflow.id, number) do
      {:ok, version} -> {:ok, version.source_definition}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp active_version_number(socket) do
    case Enum.find(socket.assigns.versions, &(&1.id == socket.assigns.workflow.active_version_id)) do
      %{version_number: number} -> number
      nil -> nil
    end
  end

  defp connection_names(socket, ids) do
    names =
      case Connections.list_connections(socket.assigns.scope) do
        {:ok, connections} -> Map.new(connections, &{&1.id, &1.name})
        {:error, %Error{}} -> %{}
      end

    Enum.map(ids, fn id -> Map.get(names, id, "Connection") end)
  end

  defp compile_draft(definition) do
    case Compiler.compile(definition) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, issues} -> {:error, issues}
    end
  end

  defp parse_sample(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, sample} when is_map(sample) and not is_struct(sample) ->
        {:ok, Error.sanitize(sample)}

      {:ok, _other} ->
        {:error,
         Error.new(:validation, :invalid_sample,
           message: "Sample trigger data must be an object."
         )}

      {:error, _reason} ->
        {:error,
         Error.new(:validation, :invalid_sample,
           message: "Sample trigger data must be valid JSON."
         )}
    end
  end

  defp parse_sample(_raw) do
    {:error,
     Error.new(:validation, :invalid_sample, message: "Sample trigger data must be an object.")}
  end

  defp dry_run_form(params \\ %{}) do
    defaults = %{"sample" => ~s({\n  "data": {}\n}), "approval_edge" => "approved"}
    to_form(Map.merge(defaults, stringify_keys(params)), as: :dry_run)
  end

  defp stringify_keys(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp creator_names(scope, versions) do
    ids =
      versions
      |> Enum.map(& &1.created_by_member_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Members.labels(scope, ids)
  end

  defp activation_issues(%Error{code: :activation_blocked, details: %{issues: issues}})
       when is_list(issues) do
    Enum.filter(issues, &match?(%ValidationIssue{}, &1))
  end

  defp activation_issues(_error), do: []

  defp require_confirmed(socket, kind) do
    case socket.assigns.confirm do
      %{kind: ^kind} -> :ok
      _other -> {:error, :unconfirmed}
    end
  end

  defp require_confirmed_version(socket, kind, version_number) do
    case socket.assigns.confirm do
      %{kind: ^kind, version: %{version_number: ^version_number}} -> :ok
      _other -> {:error, :unconfirmed}
    end
  end

  defp require_cap(socket, capability), do: Policy.authorize(socket.assigns.scope, capability)

  defp require_active(socket) do
    if socket.assigns.workflow.status == "active" and
         is_binary(socket.assigns.workflow.active_version_id) do
      :ok
    else
      {:error,
       Error.new(:conflict, :not_active,
         message: "Activate a version before running a live test."
       )}
    end
  end

  defp parse_version_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 1 -> {:ok, number}
      _other -> :error
    end
  end

  defp parse_version_number(value) when is_integer(value) and value >= 1, do: {:ok, value}
  defp parse_version_number(_value), do: :error

  defp has_approval?(%Definition{} = definition) do
    Enum.any?(Definition.nodes(definition), &(&1.type == :approval))
  end

  defp would_send_text(map) when is_map(map), do: Jason.encode!(map)
  defp would_send_text(_other), do: ""

  defp list_text([]), do: "None"
  defp list_text(items), do: Enum.join(items, ", ")

  defp trigger_label("pumble_event"), do: "Pumble event"
  defp trigger_label("schedule"), do: "schedule"
  defp trigger_label("manual"), do: "manual"
  defp trigger_label("webhook"), do: "webhook"
  defp trigger_label("manual_test"), do: "test"
  defp trigger_label(other) when is_binary(other), do: other
  defp trigger_label(_other), do: "unknown"

  defp status_tone("active"), do: "ok"
  defp status_tone("inactive"), do: "warn"
  defp status_tone("archived"), do: "neutral"
  defp status_tone(_status), do: "info"

  defp status_label("draft"), do: "Draft"
  defp status_label("active"), do: "Active"
  defp status_label("inactive"), do: "Inactive"
  defp status_label("archived"), do: "Archived"
  defp status_label(other) when is_binary(other), do: other

  defp reject_load(socket, message) do
    socket
    |> assign(:page_ready, false)
    |> put_flash(:error, message)
    |> push_navigate(to: ~p"/workflows")
  end
end
