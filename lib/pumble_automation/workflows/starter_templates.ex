defmodule PumbleAutomation.Workflows.StarterTemplates do
  @moduledoc """
  First-party starter definitions for the workflow creation flow.

  Each template is built with `Definition.new/2`, `Trigger.new/2`, and
  `Node.new/2`. Creating from a template is therefore the same as creating a
  blank draft and editing it: there is no hidden execution path, and two
  creates from the same template do not share node identity.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node

  @type catalog_entry :: %{id: String.t(), name: String.t(), summary: String.t()}

  @doc "The templates the creation form may offer, in display order."
  @spec catalog() :: [catalog_entry()]
  def catalog do
    [
      %{
        id: "blank",
        name: "Blank draft",
        summary: "A manual trigger and no steps. Add the path in the editor."
      },
      %{
        id: "welcome",
        name: "Welcome message",
        summary: "When a new message arrives, reply in the same channel."
      },
      %{
        id: "scheduled",
        name: "Daily reminder",
        summary: "Post a check-in message every day at 09:00 UTC."
      }
    ]
  end

  @doc "The catalog identifier of every first-party template."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(catalog(), & &1.id)

  @doc "A newly constructed definition for `id`, or a typed refusal."
  @spec fetch(String.t() | nil) :: {:ok, Definition.t()} | {:error, Error.t()}
  def fetch(id) when is_binary(id) do
    case build(id) do
      %Definition{} = definition ->
        {:ok, definition}

      nil ->
        {:error,
         Error.new(:validation, :unknown_template, message: "That template is not available.")}
    end
  end

  def fetch(_id) do
    {:error,
     Error.new(:validation, :unknown_template, message: "That template is not available.")}
  end

  @doc "An empty manual workflow. Used when duplicating a row that has no draft."
  @spec blank() :: Definition.t()
  def blank do
    Definition.new(Trigger.new(:manual, %{slash_command: true}), [])
  end

  defp build("blank"), do: blank()

  defp build("welcome") do
    Definition.new(
      Trigger.new(:pumble_event, %{event: :new_message, ignore_bot_messages: true}),
      [
        Node.new(:pumble_action, %{
          action: :send_message,
          channel_id: "{{ trigger.channel_id }}",
          text: "Welcome. This workflow replies in the same channel."
        })
      ]
    )
  end

  defp build("scheduled") do
    Definition.new(
      Trigger.new(:schedule, %{
        schedule_type: :daily,
        time_of_day: "09:00",
        timezone: "Etc/UTC"
      }),
      [
        Node.new(:pumble_action, %{
          action: :send_message,
          channel_id: "channel-id",
          text: "Daily check-in."
        })
      ]
    )
  end

  defp build(_id), do: nil
end
