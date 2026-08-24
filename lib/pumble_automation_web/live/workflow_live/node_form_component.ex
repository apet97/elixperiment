defmodule PumbleAutomationWeb.WorkflowLive.NodeFormComponent do
  @moduledoc """
  Typed configuration form for one trigger or step.

  Decode uses the same field engine as the AST. Persistence goes through
  editor primitives in the parent LiveView. Secret values never appear in
  assigns; only names are listed.
  """
  use PumbleAutomationWeb, :live_component

  import PumbleAutomationWeb.FormComponents

  alias PumbleAutomation.Pumble.Scopes
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Dependencies
  alias PumbleAutomation.Workflows.Editor
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.Config
  alias PumbleAutomation.Workflows.ValidationIssue
  alias PumbleAutomation.Workflows.Validator
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.Approval
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.Condition
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.Delay
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.HttpAction
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.Manual
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.ManualTest
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.Params
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.PumbleAction
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.PumbleEvent
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.References
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.Schedule
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.SchedulePreview
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.Stop
  alias PumbleAutomationWeb.WorkflowLive.NodeForms.Webhook

  @trigger_labels %{
    "pumble_event" => "Pumble event",
    "manual" => "Manual",
    "schedule" => "Schedule",
    "webhook" => "Webhook",
    "manual_test" => "Test"
  }

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:kind, assigns.kind)
      |> assign(:can_manage, assigns.can_manage)
      |> assign(:secrets, assigns.secrets)
      |> assign(:connections, assigns.connections)
      |> assign(:definition, assigns.definition)
      |> assign_new(:dirty, fn -> false end)
      |> assign_new(:form_epoch, fn -> assigns.form_epoch end)

    {:ok, hydrate(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@form_id}
      class="mt-4 border-t border-line pt-4"
      draggable="false"
      data-no-drag="true"
    >
      <.form
        for={@form}
        id={"#{@form_id}-form"}
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        class="space-y-3"
      >
        <.input
          :if={@kind == :trigger}
          id={"#{@form_id}-type"}
          name="trigger_type"
          type="select"
          label="Trigger type"
          value={Atom.to_string(@type)}
          options={trigger_type_options()}
          disabled={not @can_manage}
        />

        <.issue_list id={"#{@form_id}-issues"} issues={@issues} />

        <Delay.fields :if={@type == :delay} form={@form} can_manage={@can_manage} form_id={@form_id} />
        <Stop.fields
          :if={@type == :stop}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
          references={@references}
          target={@myself}
        />
        <Condition.fields
          :if={@type == :condition}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
          references={@references}
          target={@myself}
          predicate_rows={@predicate_rows}
        />
        <PumbleAction.fields
          :if={@type == :pumble_action}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
          references={@references}
          target={@myself}
          scope_notes={@scope_notes}
        />
        <HttpAction.fields
          :if={@type == :http_action}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
          references={@references}
          target={@myself}
          header_rows={@header_rows}
          connections={@connections}
          secrets={@secrets}
          missing_connection?={@missing_connection?}
          missing_secrets={@missing_secrets}
        />
        <Approval.fields
          :if={@type == :approval}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
          references={@references}
          target={@myself}
          scope_notes={@scope_notes}
          approver_text={@approver_text}
        />
        <PumbleEvent.fields
          :if={@type == :pumble_event}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
          channel_text={@channel_text}
        />
        <Manual.fields
          :if={@type == :manual}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
        />
        <Schedule.fields
          :if={@type == :schedule}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
          preview={@preview}
          preview_error={@preview_error}
          dst_policy={@dst_policy}
          weekdays={@weekdays}
        />
        <Webhook.fields
          :if={@type == :webhook}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
        />
        <ManualTest.fields
          :if={@type == :manual_test}
          form={@form}
          can_manage={@can_manage}
          form_id={@form_id}
        />

        <.button
          :if={@can_manage}
          id={"#{@form_id}-save"}
          variant="primary"
          type="submit"
        >
          Save configuration
        </.button>
      </.form>
    </section>
    """
  end

  @impl true
  def handle_event("validate", %{"trigger_type" => type} = params, socket) do
    if type != Atom.to_string(socket.assigns.type) do
      {:noreply, maybe_replace_trigger(socket, type)}
    else
      apply_input(socket, Map.get(params, "config", %{}), persist?: false)
    end
  end

  def handle_event("validate", %{"config" => params}, socket) do
    apply_input(socket, params, persist?: false)
  end

  def handle_event("save", %{"config" => params}, socket) do
    apply_input(socket, params, persist?: true)
  end

  def handle_event("save", params, socket) do
    apply_input(socket, Map.get(params, "config", %{}), persist?: true)
  end

  def handle_event("insert_reference", %{"field" => field, "path" => path}, socket) do
    if socket.assigns.can_manage do
      params = put_field(socket.assigns.params, field, &insert_snippet(&1, path))
      apply_input(socket, params, persist?: false)
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_header", _params, socket) do
    add_row(socket, "headers", %{"name" => "", "value" => ""})
  end

  def handle_event("remove_header", %{"index" => index}, socket) do
    remove_row(socket, "headers", index)
  end

  def handle_event("add_predicate", _params, socket) do
    add_row(socket, "predicates", %{"left" => "", "comparator" => "eq", "right" => ""})
  end

  def handle_event("remove_predicate", %{"index" => index}, socket) do
    remove_row(socket, "predicates", index)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp hydrate(socket, assigns) do
    subject = assigns.subject
    rebuild? = socket.assigns.form_epoch != assigns.form_epoch or not socket.assigns.dirty

    socket
    |> assign(:form_epoch, assigns.form_epoch)
    |> assign(:subject_id, subject.id)
    |> assign(:type, subject.type)
    |> assign(:config_module, config_module(assigns.kind, subject.type))
    |> assign(:form_id, form_id(assigns.kind, subject.id))
    |> assign(:references, references(assigns))
    |> maybe_rebuild(rebuild?, subject)
  end

  defp maybe_rebuild(socket, true, subject), do: rebuild(socket, subject)
  defp maybe_rebuild(socket, false, _subject), do: socket

  defp rebuild(socket, subject) do
    params = Params.form_params(subject.config)

    socket
    |> assign(:dirty, false)
    |> assign_state(params, issues_for(socket.assigns.definition, subject.id), nil)
  end

  defp apply_input(socket, params, opts) do
    persist? = Keyword.get(opts, :persist?, false)
    params = stringify(params)
    module = socket.assigns.config_module

    case Params.decode(module, params) do
      {:ok, config} ->
        issues = candidate_issues(socket, config)
        socket = assign_state(socket, params, issues, config)

        cond do
          not socket.assigns.can_manage ->
            {:noreply, assign(socket, :dirty, true)}

          persist? ->
            persist(socket, config)

          true ->
            {:noreply, socket |> assign(:dirty, true) |> push_config(config)}
        end

      {:error, decode_issues} ->
        issues = Enum.map(decode_issues, &decode_issue/1)

        {:noreply,
         socket
         |> assign(:dirty, true)
         |> assign_state(params, issues, nil)}
    end
  end

  defp persist(socket, config) do
    {:noreply, socket |> push_config(config) |> assign(:dirty, false)}
  end

  defp push_config(socket, config) do
    id = socket.assigns.subject_id

    message =
      case socket.assigns.kind do
        :node -> {:config_saved, :node, id, config}
        :trigger -> {:config_saved, :trigger, id, config}
      end

    send(self(), message)
    socket
  end

  defp maybe_replace_trigger(socket, type) do
    current = Atom.to_string(socket.assigns.type)

    cond do
      not socket.assigns.can_manage ->
        socket

      type == current ->
        socket

      true ->
        case Map.fetch(Trigger.types(), type) do
          {:ok, atom} ->
            trigger = Trigger.new(atom, trigger_defaults(atom), id: socket.assigns.subject_id)
            send(self(), {:trigger_replaced, trigger})
            assign(socket, :dirty, false)

          :error ->
            socket
        end
    end
  end

  defp assign_state(socket, params, issues, config) do
    module = socket.assigns.config_module
    errors = Params.form_errors(module, issues)

    form =
      to_form(params,
        as: :config,
        id: "#{socket.assigns.form_id}-fields",
        errors: errors,
        action: :validate
      )

    {preview, preview_error} = preview(socket.assigns.type, config)

    socket
    |> assign(:params, params)
    |> assign(:issues, issues)
    |> assign(:form, form)
    |> assign(:header_rows, Params.rows(params, "headers"))
    |> assign(:predicate_rows, Params.rows(params, "predicates"))
    |> assign(:approver_text, Params.joined(params, "approver_member_ids", "\n"))
    |> assign(:channel_text, Params.joined(params, "channel_ids", ", "))
    |> assign(:weekdays, weekday_list(params))
    |> assign(:preview, preview)
    |> assign(:preview_error, preview_error)
    |> assign(:dst_policy, SchedulePreview.dst_policy())
    |> assign(:scope_notes, scope_notes(socket.assigns.type, config))
    |> assign(:missing_connection?, missing_connection?(socket, config))
    |> assign(:missing_secrets, missing_secrets(socket, config, params))
  end

  defp candidate_issues(socket, config) do
    definition = socket.assigns.definition
    subject_id = socket.assigns.subject_id

    candidate =
      case apply_candidate(socket.assigns.kind, definition, subject_id, config) do
        {:ok, updated} -> updated
        {:error, _reason} -> definition
      end

    candidate
    |> Validator.validate()
    |> Enum.filter(&(&1.node_id == subject_id))
    |> Enum.map(&issue_map/1)
  end

  defp apply_candidate(:node, definition, id, config) do
    Editor.update_config(definition, id, config)
  end

  defp apply_candidate(:trigger, definition, _id, config) do
    Editor.update_trigger_config(definition, config)
  end

  defp issues_for(definition, subject_id) do
    definition
    |> Validator.validate()
    |> Enum.filter(&(&1.node_id == subject_id))
    |> Enum.map(&issue_map/1)
  end

  defp issue_map(%ValidationIssue{} = issue) do
    %{code: issue.code, path: issue.path, message: issue.message, severity: issue.severity}
  end

  defp decode_issue(%{path: path, reason: reason, message: message}) do
    %{code: reason, path: path, message: message, severity: :error}
  end

  defp preview(:schedule, %ScheduleConfig{} = config) do
    case SchedulePreview.occurrences(config, DateTime.utc_now()) do
      {:ok, instants} -> {instants, nil}
      {:error, error} -> {[], error.message}
    end
  end

  defp preview(_type, _config), do: {[], nil}

  defp scope_notes(type, %_{} = config) when type in [:pumble_action, :approval] do
    encoded = Config.encode(config)
    scopes = Map.get(Dependencies.requirements(type, encoded), "scopes", [])

    case scopes do
      [] ->
        ["No proven Pumble scope is recorded for this step yet."]

      names ->
        Enum.map(names, &scope_note(type, encoded, &1))
    end
  end

  defp scope_notes(_type, _config), do: []

  defp scope_note(type, encoded, scope) do
    "This step is expected to need #{scope} (#{scope_evidence(type, encoded, scope)})."
  end

  defp scope_evidence(type, encoded, scope) do
    type
    |> Dependencies.requirements(encoded)
    |> Map.get("operations", [])
    |> Enum.find_value("inferred", fn name ->
      evidence_tag(operation_atom(name), scope)
    end)
  end

  defp evidence_tag(nil, _scope), do: nil

  defp evidence_tag(operation, scope) do
    mapping = Scopes.mapping(operation)

    if Scopes.scope_of(mapping) == scope do
      mapping |> elem(0) |> Atom.to_string()
    end
  end

  defp operation_atom(name) when is_binary(name) do
    Enum.find(Scopes.operations(), &(Atom.to_string(&1) == name))
  end

  defp operation_atom(_name), do: nil

  defp missing_connection?(socket, %_{connection_id: id}) when is_binary(id) do
    socket.assigns.can_manage and
      Enum.all?(socket.assigns.connections, &(&1.id != id))
  end

  defp missing_connection?(_socket, _config), do: false

  defp missing_secrets(socket, config, params) do
    if socket.assigns.can_manage do
      known = MapSet.new(socket.assigns.secrets, & &1.name)
      encoded = if is_struct(config), do: Config.encode(config), else: %{}

      [params, encoded]
      |> Enum.flat_map(&References.secret_names_in/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known, &1))
    else
      []
    end
  end

  defp references(%{kind: :trigger}), do: References.available_for_trigger()

  defp references(%{kind: :node, definition: definition, subject: subject}) do
    References.available(definition, subject.id)
  end

  defp config_module(:node, type), do: Node.config_module(type)
  defp config_module(:trigger, type), do: Trigger.config_module(type)

  defp form_id(:trigger, _id), do: "trigger-form"
  defp form_id(:node, id), do: "node-form-#{id}"

  defp trigger_type_options do
    Trigger.types()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{Map.fetch!(@trigger_labels, &1), &1})
  end

  defp trigger_defaults(:pumble_event), do: %{event: :new_message, ignore_bot_messages: true}
  defp trigger_defaults(:manual), do: %{slash_command: true}

  defp trigger_defaults(:schedule) do
    %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"}
  end

  defp trigger_defaults(:webhook), do: %{require_signature: false}
  defp trigger_defaults(:manual_test), do: %{}

  defp add_row(socket, key, row) do
    if socket.assigns.can_manage do
      rows = Params.rows(socket.assigns.params, key) ++ [row]
      params = Map.put(socket.assigns.params, key, index_map(rows))
      apply_input(socket, params, persist?: false)
    else
      {:noreply, socket}
    end
  end

  defp remove_row(socket, key, index) do
    if socket.assigns.can_manage do
      case parse_index(index) do
        {:ok, position} ->
          rows =
            socket.assigns.params
            |> Params.rows(key)
            |> List.delete_at(position)

          params = Map.put(socket.assigns.params, key, index_map(rows))
          apply_input(socket, params, persist?: false)

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp index_map(rows) do
    rows
    |> Enum.with_index()
    |> Map.new(fn {row, index} -> {Integer.to_string(index), row} end)
  end

  defp weekday_list(params) do
    case Map.get(params, "weekdays") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      value when is_binary(value) and value != "" -> [value]
      _other -> []
    end
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp put_field(params, field, fun) when is_binary(field) do
    case String.split(field, ".") do
      [key] ->
        Map.put(params, key, fun.(Map.get(params, key)))

      [collection, index, key] ->
        put_row_field(params, collection, index, key, fun)

      _other ->
        params
    end
  end

  defp put_row_field(params, collection, index, key, fun) do
    case parse_index(index) do
      {:ok, position} ->
        rows =
          params
          |> Params.rows(collection)
          |> pad_row(position)
          |> List.update_at(position, &Map.put(&1, key, fun.(Map.get(&1, key))))

        Map.put(params, collection, index_map(rows))

      :error ->
        params
    end
  end

  defp pad_row(rows, position) do
    needed = position + 1 - length(rows)

    if needed > 0 do
      rows ++ Enum.map(1..needed, fn _ -> %{} end)
    else
      rows
    end
  end

  defp parse_index(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _other -> :error
    end
  end

  defp parse_index(_value), do: :error

  defp insert_snippet(current, path) do
    snippet = References.snippet(path)

    case String.trim(to_string(current || "")) do
      "" -> snippet
      value -> value <> " " <> snippet
    end
  end
end
