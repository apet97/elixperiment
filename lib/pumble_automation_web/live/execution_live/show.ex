defmodule PumbleAutomationWeb.ExecutionLive.Show do
  @moduledoc """
  Sanitized execution timeline with cancel and owner uncertainty controls.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.ExecutionComponents

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.History
  alias PumbleAutomation.Installations.Policy

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:nav_current, :executions)
     |> assign(:page_ready, false)
     |> assign(:detail, nil)
     |> assign(:confirm, nil)
     |> assign(:retry_form, retry_form())
     |> assign(:can_cancel, Policy.can?(scope, :cancel_execution))
     |> assign(:can_resolve, Policy.can?(scope, :resolve_uncertainty))}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, load_detail(socket, id)}
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
      <.loading_state :if={not @page_ready} id="execution-show-loading" label="Loading execution" />
      <div :if={@page_ready} id="execution-show" data-status={@detail.execution.status}>
        <.header>
          Execution
          <:subtitle>
            Diagnose a single run of version {@detail.execution.version_number}.
          </:subtitle>
        </.header>

        <div class="space-y-6">
          <.execution_header
            execution={@detail.execution}
            trigger={@detail.trigger}
            terminal_reason={@detail.terminal_reason}
          />
          <.timeline steps={@detail.steps} />
          <.operator_controls
            can_cancel={@can_cancel}
            can_resolve={@can_resolve}
            cancellable?={@detail.execution.cancellable?}
            resolvable?={@detail.execution.resolvable?}
          />
        </div>
      </div>

      <.confirm_dialog :if={@confirm} confirm={@confirm} retry_form={@retry_form} />
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("confirm_cancel", _params, socket) do
    with :ok <- require_cap(socket, :cancel_execution),
         true <- socket.assigns.detail.execution.cancellable? do
      {:noreply, assign(socket, :confirm, %{kind: :cancel})}
    else
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}

      false ->
        {:noreply, refresh(socket, "The execution cannot make that transition.")}
    end
  end

  def handle_event("confirm_resolve", %{"choice" => choice}, socket) do
    with :ok <- require_cap(socket, :resolve_uncertainty),
         true <- socket.assigns.detail.execution.resolvable?,
         {:ok, known} <- known_choice(choice) do
      {:noreply,
       socket
       |> assign(:confirm, %{kind: :resolve, choice: known})
       |> assign(:retry_form, retry_form())}
    else
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}

      false ->
        {:noreply, refresh(socket, "The execution cannot make that transition.")}
    end
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("cancel", _params, socket) do
    id = socket.assigns.detail.execution.id

    with :ok <- require_confirmed(socket, :cancel),
         :ok <- require_cap(socket, :cancel_execution),
         {:ok, _execution} <- Engine.cancel(socket.assigns.scope, id) do
      {:noreply,
       socket
       |> assign(:confirm, nil)
       |> put_flash(:info, "Execution cancelled.")
       |> load_detail(id)}
    else
      {:error, :unconfirmed} ->
        {:noreply, socket}

      {:error, %Error{class: class} = error} when class in [:conflict, :not_found] ->
        {:noreply, refresh(socket, error.message)}

      {:error, %Error{} = error} ->
        {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
    end
  end

  def handle_event("resolve", params, socket) do
    id = socket.assigns.detail.execution.id

    with {:ok, choice} <- known_choice(Map.get(params, "choice")),
         :ok <- require_confirmed_choice(socket, :resolve, choice),
         :ok <- require_cap(socket, :resolve_uncertainty),
         {:ok, _execution} <-
           Engine.resolve_uncertain(
             socket.assigns.scope,
             id,
             choice,
             resolve_attrs(choice, params)
           ) do
      {:noreply,
       socket
       |> assign(:confirm, nil)
       |> put_flash(:info, resolve_flash(choice))
       |> load_detail(id)}
    else
      {:error, :unconfirmed} ->
        {:noreply, socket}

      {:error, %Error{class: :validation} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}

      {:error, %Error{} = error} ->
        {:noreply, refresh(socket, error.message)}
    end
  end

  defp load_detail(socket, id) do
    case History.get_detail(socket.assigns.scope, id) do
      {:ok, detail} ->
        socket
        |> assign(:page_title, "Execution")
        |> assign(:page_ready, true)
        |> assign(:detail, detail)
        |> assign(:confirm, nil)

      {:error, %Error{} = error} ->
        reject_load(socket, error.message)
    end
  end

  defp refresh(socket, message) do
    id = socket.assigns.detail.execution.id

    socket
    |> assign(:confirm, nil)
    |> put_flash(:error, message)
    |> load_detail(id)
  end

  defp reject_load(socket, message) do
    socket
    |> assign(:page_ready, false)
    |> put_flash(:error, message)
    |> push_navigate(to: ~p"/executions")
  end

  defp require_confirmed(socket, kind) do
    case socket.assigns.confirm do
      %{kind: ^kind} -> :ok
      _other -> {:error, :unconfirmed}
    end
  end

  defp require_confirmed_choice(socket, kind, choice) do
    case socket.assigns.confirm do
      %{kind: ^kind, choice: ^choice} -> :ok
      _other -> {:error, :unconfirmed}
    end
  end

  defp require_cap(socket, capability) do
    Policy.authorize(socket.assigns.scope, capability)
  end

  defp known_choice("succeeded"), do: {:ok, "succeeded"}
  defp known_choice("failed"), do: {:ok, "failed"}
  defp known_choice("retry"), do: {:ok, "retry"}

  defp known_choice(_choice) do
    {:error,
     Error.new(:validation, :invalid_resolution,
       message: "Uncertainty resolution must be succeeded, failed, or retry."
     )}
  end

  defp resolve_attrs("retry", params) do
    acknowledged =
      get_in(params, ["retry", "acknowledge_duplicate_risk"]) ||
        Map.get(params, "acknowledge_duplicate_risk")

    %{acknowledge_duplicate_risk: acknowledged in [true, "true"]}
  end

  defp resolve_attrs(_choice, _params), do: %{}

  defp resolve_flash("succeeded"), do: "Uncertain effect marked succeeded."
  defp resolve_flash("failed"), do: "Uncertain effect marked failed."
  defp resolve_flash("retry"), do: "Uncertain effect queued for retry."
  defp resolve_flash(_choice), do: "Uncertainty resolved."

  defp retry_form(params \\ %{}) do
    to_form(Map.merge(%{"acknowledge_duplicate_risk" => "false"}, stringify_keys(params)),
      as: :retry
    )
  end

  defp stringify_keys(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end
end
