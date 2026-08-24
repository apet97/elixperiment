defmodule PumbleAutomationWeb.AdminComponents do
  @moduledoc """
  Shared chrome for tenant administration pages: confirmations and usage notes.
  """
  use PumbleAutomationWeb, :html

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def confirm_shell(assigns) do
    ~H"""
    <.modal id={@id} title={@title} on_cancel="cancel_confirm">
      {render_slot(@inner_block)}
    </.modal>
    """
  end

  attr :id, :string, required: true
  attr :workflows, :list, default: []
  attr :connections, :list, default: []

  def usage_note(assigns) do
    ~H"""
    <p :if={@workflows != [] or @connections != []} id={@id} class="mt-2 text-xs text-muted">
      Used by {usage_text(@workflows, @connections)}.
    </p>
    <p :if={@workflows == [] and @connections == []} id={@id} class="mt-2 text-xs text-muted">
      Not referenced by an active workflow.
    </p>
    """
  end

  defp usage_text(workflows, connections) do
    [name_list("workflow", workflows), name_list("connection", connections)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp name_list(_kind, []), do: nil
  defp name_list(kind, names), do: "#{kind} #{Enum.join(names, ", ")}"
end
