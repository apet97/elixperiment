defmodule PumbleAutomation.Pumble.Manifest do
  @moduledoc """
  The add-on manifest, as a struct this application can check and render.

  The manifest is installation configuration, not runtime state. Product
  contract Section 1.2 freezes the manual trigger surface at one slash command,
  one global shortcut, and one message shortcut, and product contract Section 6
  states plainly that these do not change when a user edits a workflow. Nothing in this module
  is derived from workflow data, and nothing here can be extended at runtime.

  ## Why the shortcut carries two names

  `M-4`: the vendor tooling normalizes a shortcut's display name to
  `downcase` with whitespace replaced by underscores, keeps the original as
  `displayName`, and it is the *normalized* value that arrives in the callback
  and that handler routing compares against. This module performs the same
  normalization, so the name this application registers is the name it will be
  called by.

  ## No secret can be rendered

  `M-10` requires `appKey`, `clientSecret`, and `signingSecret` to be absent
  from a served or published manifest. They are absent here by construction:
  the struct has no field for any of them, so `render/1` cannot leak one whatever
  it is passed. `:id` is the client id, which is not a secret and is required.

  The one `dynamicMenus` entry is also static. Its `pick_workflow` action is a
  shared product picker; Pumble's options-load payload does not say whether a
  global or message shortcut opened it, so ingress serves the documented union
  of aliases visible in either picker.

  `render/1` produces the JSON-ready map for manifest validation; `to_json/1`
  encodes it.
  """

  alias PumbleAutomation.Pumble.Payload

  @slash_command "/workflow"
  @global_shortcut "Run workflow"
  @message_shortcut "Run workflow on message"
  @dynamic_menu_action "pick_workflow"

  @type entry_point :: %{name: String.t(), display_name: String.t(), url: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          display_name: String.t(),
          bot: boolean(),
          bot_title: String.t(),
          socket_mode: boolean(),
          description: String.t(),
          slash_command: entry_point(),
          global_shortcut: entry_point(),
          message_shortcut: entry_point(),
          dynamic_menu: %{on_action: String.t(), url: String.t()},
          default_home_view: %{enabled: boolean(), blocks: [map()]},
          callback_url: String.t(),
          redirect_urls: [String.t()],
          events: [String.t()],
          bot_scopes: [String.t()],
          user_scopes: [String.t()]
        }

  @enforce_keys [:id, :name, :display_name, :callback_url]
  defstruct [
    :id,
    :name,
    :display_name,
    :callback_url,
    bot: true,
    bot_title: "Workflow Automation Bot",
    socket_mode: false,
    description: "Build and run Pumble workflows.",
    slash_command: nil,
    global_shortcut: nil,
    message_shortcut: nil,
    dynamic_menu: nil,
    default_home_view: %{enabled: false, blocks: []},
    redirect_urls: [],
    events: [],
    bot_scopes: [],
    user_scopes: []
  ]

  @doc """
  Builds the manifest from application configuration.

  Every URL is absolute and derived from the configured public base URL, because
  `M-9` requires absolute HTTPS redirect URLs in production and a relative entry
  would depend on whichever host answered.
  """
  @spec build() :: t()
  def build do
    pumble = Application.fetch_env!(:pumble_automation, :pumble)
    base = Application.fetch_env!(:pumble_automation, :public_url)
    callback_url = base <> callback_path()

    %__MODULE__{
      id: Keyword.fetch!(pumble, :client_id),
      name: "workflow-automation",
      display_name: "Workflow Automation",
      callback_url: callback_url,
      slash_command: entry_point(@slash_command, callback_url),
      global_shortcut: entry_point(@global_shortcut, callback_url),
      message_shortcut: entry_point(@message_shortcut, callback_url),
      dynamic_menu: %{on_action: @dynamic_menu_action, url: callback_url},
      redirect_urls: [base <> "/oauth/callback"],
      events: Payload.trigger_event_types() ++ Payload.lifecycle_event_types(),
      bot_scopes: Keyword.get(pumble, :bot_scopes, []),
      user_scopes: Keyword.get(pumble, :user_scopes, [])
    }
  end

  @doc """
  Renders the manifest as the JSON-ready map Pumble is given.

  The field names are Pumble's, and they appear only here and in the transport,
  as with every other wire vocabulary in this application.
  """
  @spec render(t()) :: map()
  def render(%__MODULE__{} = manifest) do
    %{
      "id" => manifest.id,
      "name" => manifest.name,
      "displayName" => manifest.display_name,
      "bot" => manifest.bot,
      "botTitle" => manifest.bot_title,
      "socketMode" => manifest.socket_mode,
      "description" => manifest.description,
      "redirectUrls" => manifest.redirect_urls,
      "scopes" => %{
        "botScopes" => manifest.bot_scopes,
        "userScopes" => manifest.user_scopes
      },
      "slashCommands" => [
        %{"command" => manifest.slash_command.name, "url" => manifest.slash_command.url}
      ],
      "shortcuts" => [
        shortcut(manifest.global_shortcut, "GLOBAL"),
        shortcut(manifest.message_shortcut, "ON_MESSAGE")
      ],
      "eventSubscriptions" => %{
        "url" => manifest.callback_url,
        "events" => manifest.events
      },
      "blockInteraction" => %{"url" => manifest.callback_url},
      "viewAction" => %{"url" => manifest.callback_url},
      "dynamicMenus" => [
        %{"url" => manifest.dynamic_menu.url, "onAction" => manifest.dynamic_menu.on_action}
      ],
      "defaultHomeView" => %{
        "enabled" => manifest.default_home_view.enabled,
        "blocks" => manifest.default_home_view.blocks
      }
    }
  end

  @doc "The rendered manifest as JSON."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = manifest), do: manifest |> render() |> Jason.encode!()

  @doc "The frozen manual entry-point names, before normalization."
  @spec entry_point_names() :: %{atom() => String.t()}
  def entry_point_names do
    %{
      slash_command: @slash_command,
      global_shortcut: @global_shortcut,
      message_shortcut: @message_shortcut
    }
  end

  @doc "The one frozen action id registered for workflow-picker option loads."
  @spec dynamic_menu_action() :: String.t()
  def dynamic_menu_action, do: @dynamic_menu_action

  @doc """
  Normalizes a display name the way the vendor tooling does (`M-4`).
  """
  @spec normalize_name(String.t()) :: String.t()
  def normalize_name(display_name) when is_binary(display_name) do
    display_name
    |> String.downcase()
    |> String.replace(~r/\s+/u, "_")
  end

  defp entry_point(display_name, url) do
    %{name: normalize_name(display_name), display_name: display_name, url: url}
  end

  defp shortcut(entry, type) do
    %{
      "name" => entry.name,
      "displayName" => entry.display_name,
      "url" => entry.url,
      "shortcutType" => type
    }
  end

  defp callback_path do
    :pumble_automation
    |> Application.fetch_env!(:pumble_callbacks)
    |> Keyword.fetch!(:path_prefix)
  end
end
