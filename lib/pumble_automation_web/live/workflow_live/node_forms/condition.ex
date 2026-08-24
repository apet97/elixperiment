defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Condition do
  @moduledoc false
  use PumbleAutomationWeb, :html

  import PumbleAutomationWeb.FormComponents

  alias PumbleAutomation.Workflows.Node.ConditionConfig
  alias PumbleAutomation.Workflows.Node.Predicate

  attr :form, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :form_id, :string, required: true
  attr :references, :list, default: []
  attr :target, :any, default: nil
  attr :predicate_rows, :list, default: []

  def fields(assigns) do
    assigns =
      assigns
      |> assign(:combinators, enum_options(ConditionConfig.combinators()))
      |> assign(:comparators, enum_options(Predicate.comparators()))

    ~H"""
    <.field_hint text="All is AND, any is OR, and none is NOT over the group. Comparisons use the same operators the runtime understands." />
    <.input
      field={@form[:combinator]}
      type="select"
      label="Combinator"
      options={@combinators}
      disabled={not @can_manage}
    />

    <div id={"#{@form_id}-predicates"} class="space-y-3">
      <div
        :for={{row, index} <- Enum.with_index(@predicate_rows)}
        id={"#{@form_id}-predicate-#{index}"}
        class="rounded-md border border-line bg-surface p-3"
      >
        <.reference_helper
          id={"#{@form_id}-predicate-#{index}-refs"}
          field={"predicates.#{index}.left"}
          references={@references}
          can_manage={@can_manage}
          target={@target}
        />
        <.input
          id={"#{@form.id}_predicates_#{index}_left"}
          name={"#{@form.name}[predicates][#{index}][left]"}
          value={Map.get(row, "left", "")}
          type="text"
          label="Left"
          disabled={not @can_manage}
        />
        <.input
          id={"#{@form.id}_predicates_#{index}_comparator"}
          name={"#{@form.name}[predicates][#{index}][comparator]"}
          value={Map.get(row, "comparator", "eq")}
          type="select"
          label="Comparator"
          options={@comparators}
          disabled={not @can_manage}
        />
        <.input
          id={"#{@form.id}_predicates_#{index}_right"}
          name={"#{@form.name}[predicates][#{index}][right]"}
          value={Map.get(row, "right", "")}
          type="text"
          label="Right"
          disabled={not @can_manage}
        />
        <.button
          :if={@can_manage}
          id={"#{@form_id}-remove-predicate-#{index}"}
          variant="ghost"
          type="button"
          phx-click="remove_predicate"
          phx-value-index={index}
          phx-target={@target}
        >
          Remove comparison
        </.button>
      </div>
    </div>

    <.button
      :if={@can_manage}
      id={"#{@form_id}-add-predicate"}
      variant="secondary"
      type="button"
      phx-click="add_predicate"
      phx-target={@target}
    >
      Add comparison
    </.button>
    """
  end

  defp enum_options(mapping) do
    mapping
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{String.replace(&1, "_", " "), &1})
  end
end
