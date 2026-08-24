defmodule PumbleAutomationWeb.WorkflowLive.Edit do
  @moduledoc """
  Nested outline editor for a tenant-scoped workflow draft.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.EditorComponents
  import PumbleAutomationWeb.WorkflowLive.ValidationComponent

  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Connections
  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.RateLimiter
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Editor
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.StarterTemplates
  alias PumbleAutomation.Workflows.Validator
  alias PumbleAutomation.Workflows.Workflow

  @autosave_ms 400

  @branch_keys %{
    "if_true" => :if_true,
    "if_false" => :if_false,
    "approved" => :approved,
    "rejected" => :rejected,
    "timed_out" => :timed_out
  }

  @node_types [
    %{id: "pumble_action", name: "Pumble message"},
    %{id: "delay", name: "Delay"},
    %{id: "condition", name: "Condition"},
    %{id: "approval", name: "Approval"},
    %{id: "http_action", name: "HTTP request"},
    %{id: "stop", name: "Stop"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:nav_current, :workflows)
     |> assign(:page_ready, false)
     |> assign(:workflow, nil)
     |> assign(:definition, StarterTemplates.blank())
     |> assign(:draft_revision, 0)
     |> assign(:save_state, :saved)
     |> assign(:autosave_generation, 0)
     |> assign(:pending_add, nil)
     |> assign(:confirm, nil)
     |> assign(:node_types, @node_types)
     |> assign(:secrets, [])
     |> assign(:connections, [])
     |> assign(:form_epoch, 0)
     |> assign(:issues, [])
     |> assign(:validated?, false)
     |> assign(:focused_id, nil)
     |> assign(:can_manage, Policy.can?(scope, :manage_workflows))}
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
      <.loading_state :if={not @page_ready} id="workflow-editor-loading" label="Loading workflow" />
      <div :if={@page_ready} id="workflow-editor">
        <.header>
          {@workflow.name}
          <:subtitle>Build the trigger and nested steps without editing JSON.</:subtitle>
          <:actions>
            <.save_status save_state={@save_state} can_manage={@can_manage} />
          </:actions>
        </.header>

        <.conflict_banner :if={@save_state == :conflict} />

        <div class="mb-4 flex flex-wrap gap-3">
          <.link
            navigate={~p"/workflows"}
            id="editor-back"
            class="text-sm font-medium text-signal hover:text-signal-strong"
          >
            Back to workflows
          </.link>
          <.link
            navigate={~p"/workflows/#{@workflow.id}"}
            id="editor-review"
            class="text-sm font-medium text-signal hover:text-signal-strong"
          >
            Review and activate
          </.link>
        </div>

        <div class="mb-6">
          <.validation_panel
            issues={@issues}
            validated?={@validated?}
            can_validate={true}
            focused_id={@focused_id}
          />
        </div>

        <div
          id="workflow-outline"
          phx-hook="OutlineReorder"
          data-can-manage={to_string(@can_manage)}
          class="space-y-4"
        >
          <.trigger_card
            trigger={@definition.trigger}
            definition={@definition}
            can_manage={@can_manage}
            secrets={@secrets}
            connections={@connections}
            form_epoch={@form_epoch}
            focused_id={@focused_id}
          />

          <.sequence
            id="root-sequence"
            nodes={@definition.steps}
            prefix=""
            branch_path="root"
            can_manage={@can_manage}
            definition={@definition}
            secrets={@secrets}
            connections={@connections}
            form_epoch={@form_epoch}
            focused_id={@focused_id}
          />

          <div :if={@can_manage}>
            <.button
              id="root-add-step"
              variant="secondary"
              type="button"
              phx-click="add_prompt"
              phx-value-op="append"
              phx-value-branch_path="root"
            >
              Add step
            </.button>
          </div>
        </div>
      </div>

      <.type_picker :if={@pending_add} node_types={@node_types} />
      <.delete_dialog :if={@confirm} confirm={@confirm} />
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("add_prompt", params, socket) do
    with :ok <- require_manage(socket),
         {:ok, pending} <- pending_add_from(params) do
      {:noreply, assign(socket, :pending_add, pending)}
    else
      {:error, :malformed} -> ignore_malformed(socket)
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply, assign(socket, :pending_add, nil)}
  end

  def handle_event("add_node", %{"type" => type}, socket) do
    with :ok <- require_manage(socket),
         {:ok, pending} <- fetch_pending(socket),
         {:ok, node} <- build_node(type),
         {:ok, definition} <- insert_pending(socket.assigns.definition, pending, node) do
      {:noreply,
       socket
       |> assign(:pending_add, nil)
       |> put_definition(definition)}
    else
      {:error, :malformed} ->
        ignore_malformed(socket)

      {:error, %Error{} = error} ->
        {:noreply, socket |> assign(:pending_add, nil) |> put_flash(:error, error.message)}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    with :ok <- require_manage(socket),
         {:ok, node_id} <- parse_uuid(id),
         {:ok, metadata} <- Editor.deletion_metadata(socket.assigns.definition, node_id) do
      {:noreply, assign(socket, :confirm, Map.put(metadata, :id, node_id))}
    else
      {:error, :malformed} -> ignore_malformed(socket)
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with :ok <- require_manage(socket),
         {:ok, node_id} <- parse_uuid(id),
         :ok <- require_confirmed_delete(socket, node_id),
         {:ok, definition, _metadata} <- Editor.delete(socket.assigns.definition, node_id) do
      {:noreply, socket |> assign(:confirm, nil) |> put_definition(definition)}
    else
      {:error, :malformed} -> ignore_malformed(socket)
      {:error, :unconfirmed} -> {:noreply, socket}
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("move_up", %{"id" => id}, socket), do: move_event(socket, id, -1)
  def handle_event("move_down", %{"id" => id}, socket), do: move_event(socket, id, 1)

  def handle_event("reorder", params, socket) do
    case require_manage(socket) do
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}

      :ok ->
        apply_edit_result(socket, reorder_from_ids(socket.assigns.definition, params))
    end
  end

  def handle_event("save", _params, socket) do
    persist(socket)
  end

  def handle_event("validate", _params, socket) do
    case RateLimiter.check_expensive_ui(socket.assigns.scope, :validate) do
      :ok -> {:noreply, run_validation(socket)}
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("focus_issue", %{"key" => key}, socket) do
    {:noreply, assign(socket, :focused_id, key)}
  end

  def handle_event("reload", _params, socket) do
    {:noreply, load_workflow(socket, socket.assigns.workflow.id)}
  end

  def handle_event("reapply", _params, socket) do
    with :ok <- require_manage(socket),
         {:ok, workflow} <-
           Workflows.get_workflow(socket.assigns.scope, socket.assigns.workflow.id) do
      persist(assign(socket, :draft_revision, workflow.draft_revision))
    else
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event(_event, _params, socket), do: ignore_malformed(socket)

  @impl true
  def handle_info({:config_saved, :node, node_id, config}, socket) do
    case require_manage(socket) do
      :ok ->
        apply_edit_result(
          socket,
          Editor.update_config(socket.assigns.definition, node_id, config)
        )

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_info({:config_saved, :trigger, _id, config}, socket) do
    case require_manage(socket) do
      :ok ->
        apply_edit_result(socket, Editor.update_trigger_config(socket.assigns.definition, config))

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_info({:trigger_replaced, trigger}, socket) do
    case require_manage(socket) do
      :ok ->
        apply_edit_result(socket, Editor.replace_trigger(socket.assigns.definition, trigger))

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_info({:autosave, generation}, socket) do
    if generation == socket.assigns.autosave_generation and socket.assigns.save_state == :unsaved do
      persist(socket)
    else
      {:noreply, socket}
    end
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
            |> assign(:draft_revision, workflow.draft_revision)
            |> assign(:save_state, :saved)
            |> assign(:pending_add, nil)
            |> assign(:confirm, nil)
            |> assign(:form_epoch, socket.assigns.form_epoch + 1)
            |> assign_credentials()

          {:error, %Error{} = error} ->
            reject_load(socket, error.message)
        end

      {:error, %Error{} = error} ->
        reject_load(socket, error.message)
    end
  end

  defp workflow_definition(%Workflow{} = workflow) do
    case Workflow.draft(workflow) do
      {:ok, definition} -> {:ok, definition}
      {:error, %Error{code: :draft_not_found}} -> {:ok, StarterTemplates.blank()}
      {:error, %Error{}} = error -> error
    end
  end

  defp reject_load(socket, message) do
    socket
    |> assign(:page_ready, false)
    |> put_flash(:error, message)
    |> push_navigate(to: ~p"/workflows")
  end

  defp persist(socket) do
    case require_manage(socket) do
      :ok -> write_draft(socket)
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  defp write_draft(socket) do
    socket = assign(socket, :save_state, :saving)

    case Workflows.update_draft(
           socket.assigns.scope,
           socket.assigns.workflow.id,
           socket.assigns.definition,
           socket.assigns.draft_revision
         ) do
      {:ok, workflow} ->
        {:noreply,
         socket
         |> assign(:workflow, workflow)
         |> assign(:draft_revision, workflow.draft_revision)
         |> assign(:save_state, :saved)
         |> run_validation()}

      {:error, %Error{code: :draft_revision_conflict}} ->
        {:noreply, assign(socket, :save_state, :conflict)}

      {:error, %Error{} = error} ->
        {:noreply, socket |> assign(:save_state, :unsaved) |> put_flash(:error, error.message)}
    end
  end

  defp put_definition(%{assigns: %{save_state: :conflict}} = socket, definition) do
    assign(socket, :definition, definition)
  end

  defp put_definition(socket, definition) do
    generation = socket.assigns.autosave_generation + 1

    _ =
      if connected?(socket) do
        Process.send_after(self(), {:autosave, generation}, @autosave_ms)
      else
        nil
      end

    socket
    |> assign(:definition, definition)
    |> assign(:autosave_generation, generation)
    |> assign(:save_state, :unsaved)
  end

  defp move_event(socket, id, delta) do
    case require_manage(socket) do
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}

      :ok ->
        case parse_uuid(id) do
          {:error, :malformed} ->
            ignore_malformed(socket)

          {:ok, node_id} ->
            apply_edit_result(socket, move_in_sequence(socket.assigns.definition, node_id, delta))
        end
    end
  end

  defp apply_edit_result(socket, :unchanged), do: {:noreply, socket}

  defp apply_edit_result(socket, {:ok, definition}) do
    {:noreply, put_definition(socket, definition)}
  end

  defp apply_edit_result(socket, {:error, :malformed}), do: ignore_malformed(socket)

  defp apply_edit_result(socket, {:error, %Error{} = error}) do
    {:noreply, put_flash(socket, :error, error.message)}
  end

  defp move_in_sequence(definition, node_id, delta) do
    with {:ok, address} <- Editor.address_of(definition, node_id),
         {:ok, steps} <- steps_at(definition, address),
         index when is_integer(index) <- Enum.find_index(steps, &(&1.id == node_id)) do
      target = index + delta

      if target < 0 or target >= length(steps) do
        :unchanged
      else
        Editor.reorder(definition, address, index, target)
      end
    else
      :error -> {:error, :malformed}
      nil -> {:error, :malformed}
      {:error, %Error{}} = error -> error
    end
  end

  defp reorder_from_ids(definition, params) do
    with {:ok, source_id} <- parse_uuid(Map.get(params, "source_id")),
         {:ok, target_id} <- parse_uuid(Map.get(params, "target_id")),
         {:ok, claimed} <- parse_branch_path(Map.get(params, "branch_path")),
         {:ok, source_address} <- Editor.address_of(definition, source_id),
         {:ok, target_address} <- Editor.address_of(definition, target_id),
         true <- source_address == target_address and source_address == claimed,
         {:ok, steps} <- steps_at(definition, source_address),
         from when is_integer(from) <- Enum.find_index(steps, &(&1.id == source_id)),
         to when is_integer(to) <- Enum.find_index(steps, &(&1.id == target_id)) do
      if from == to do
        :unchanged
      else
        Editor.reorder(definition, source_address, from, to)
      end
    else
      false -> {:error, :malformed}
      :error -> {:error, :malformed}
      nil -> {:error, :malformed}
      {:error, :malformed} -> {:error, :malformed}
      {:error, %Error{}} = error -> error
    end
  end

  defp insert_pending(definition, %{op: :before, id: id}, node),
    do: Editor.add_before(definition, id, node)

  defp insert_pending(definition, %{op: :after, id: id}, node),
    do: Editor.add_after(definition, id, node)

  defp insert_pending(definition, %{op: :append, address: address}, node),
    do: Editor.append(definition, address, node)

  defp pending_add_from(%{"op" => "before", "id" => id}) do
    case parse_uuid(id) do
      {:ok, node_id} -> {:ok, %{op: :before, id: node_id}}
      {:error, :malformed} -> {:error, :malformed}
    end
  end

  defp pending_add_from(%{"op" => "after", "id" => id}) do
    case parse_uuid(id) do
      {:ok, node_id} -> {:ok, %{op: :after, id: node_id}}
      {:error, :malformed} -> {:error, :malformed}
    end
  end

  defp pending_add_from(%{"op" => "append", "branch_path" => path}) do
    case parse_branch_path(path) do
      {:ok, address} -> {:ok, %{op: :append, address: address}}
      {:error, :malformed} -> {:error, :malformed}
    end
  end

  defp pending_add_from(%{"op" => "append", "parent_id" => parent_id, "branch_key" => key}) do
    with {:ok, node_id} <- parse_uuid(parent_id),
         {:ok, branch} <- parse_branch_key(key) do
      {:ok, %{op: :append, address: {node_id, branch}}}
    end
  end

  defp pending_add_from(_params), do: {:error, :malformed}

  defp fetch_pending(%{assigns: %{pending_add: pending}}) when is_map(pending), do: {:ok, pending}
  defp fetch_pending(_socket), do: {:error, :malformed}

  defp build_node(type) when is_binary(type) do
    case Map.fetch(Node.types(), type) do
      {:ok, atom} -> {:ok, new_node(atom)}
      :error -> {:error, :malformed}
    end
  end

  defp build_node(_type), do: {:error, :malformed}

  defp new_node(:pumble_action) do
    Node.new(:pumble_action, %{action: :send_message, channel_id: "channel-id", text: "Message"})
  end

  defp new_node(:delay), do: Node.new(:delay, %{duration_seconds: 60})

  defp new_node(:condition) do
    Node.new(:condition, %{combinator: :all, predicates: []})
  end

  defp new_node(:approval) do
    Node.new(:approval, %{prompt: "Approve this step?", timeout_seconds: 3600})
  end

  defp new_node(:http_action) do
    Node.new(:http_action, %{method: :get, url: "https://example.test"})
  end

  defp new_node(:stop), do: Node.new(:stop, %{reason: "Stopped"})

  defp steps_at(%Definition{} = definition, :root), do: {:ok, definition.steps}

  defp steps_at(%Definition{} = definition, {node_id, branch_key}) do
    case Definition.fetch_node(definition, node_id) do
      {:ok, node} ->
        case Node.branch(node, branch_key) do
          nil -> :error
          steps -> {:ok, steps}
        end

      :error ->
        :error
    end
  end

  defp parse_branch_path("root"), do: {:ok, :root}

  defp parse_branch_path(path) when is_binary(path) do
    case String.split(path, ":", parts: 2) do
      [parent, key] ->
        with {:ok, id} <- parse_uuid(parent),
             {:ok, branch} <- parse_branch_key(key) do
          {:ok, {id, branch}}
        end

      _other ->
        {:error, :malformed}
    end
  end

  defp parse_branch_path(_path), do: {:error, :malformed}

  defp parse_branch_key(key) when is_binary(key) do
    case Map.fetch(@branch_keys, key) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :malformed}
    end
  end

  defp parse_branch_key(_key), do: {:error, :malformed}

  defp parse_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :malformed}
    end
  end

  defp parse_uuid(_value), do: {:error, :malformed}

  defp run_validation(socket) do
    issues = Validator.validate(socket.assigns.definition)

    socket
    |> assign(:issues, issues)
    |> assign(:validated?, true)
  end

  defp require_manage(socket), do: Policy.authorize(socket.assigns.scope, :manage_workflows)

  defp require_confirmed_delete(socket, node_id) do
    case socket.assigns.confirm do
      %{id: ^node_id} -> :ok
      _other -> {:error, :unconfirmed}
    end
  end

  defp assign_credentials(socket) do
    if socket.assigns.can_manage do
      socket
      |> assign(:secrets, secret_metadata(socket.assigns.scope))
      |> assign(:connections, connection_metadata(socket.assigns.scope))
    else
      socket
      |> assign(:secrets, [])
      |> assign(:connections, [])
    end
  end

  defp secret_metadata(scope) do
    case Connections.list_secrets(scope) do
      {:ok, secrets} ->
        Enum.map(secrets, fn secret ->
          %{id: secret.id, name: secret.name, kind: secret.kind}
        end)

      {:error, %Error{}} ->
        []
    end
  end

  defp connection_metadata(scope) do
    case Connections.list_connections(scope) do
      {:ok, connections} ->
        Enum.map(connections, fn connection ->
          %{id: connection.id, name: connection.name, enabled: connection.enabled}
        end)

      {:error, %Error{}} ->
        []
    end
  end

  defp ignore_malformed(socket) do
    _ = audit_malformed(socket)
    {:noreply, socket}
  end

  defp audit_malformed(%{assigns: %{workflow: %Workflow{} = workflow, scope: scope}}) do
    _ =
      Writer.append_denied(%{
        installation_id: scope.installation_id,
        actor_type: "user",
        actor_id: scope.member_id,
        action: "workflow.editor_event_rejected",
        resource_type: "workflow",
        resource_id: workflow.id,
        metadata: %{reason: "malformed_event", result: "ignored", source: "liveview"}
      })

    :ok
  end

  defp audit_malformed(_socket), do: :ok
end
