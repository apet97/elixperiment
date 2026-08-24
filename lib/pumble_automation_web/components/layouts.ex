defmodule PumbleAutomationWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PumbleAutomationWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :any,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_installation, :any, default: nil
  attr :current_member, :any, default: nil
  attr :nav_current, :atom, default: :home

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div
      id="app-shell"
      data-layout="responsive"
      class="min-h-dvh overflow-x-hidden bg-canvas text-ink"
    >
      <a href="#main-content" id="skip-to-main" class="pa-skip">Skip to content</a>

      <%= if @current_scope do %>
        <div class="lg:grid lg:min-h-dvh lg:grid-cols-[15rem_minmax(0,1fr)]">
          <.sidebar
            current_scope={@current_scope}
            current_installation={@current_installation}
            current_member={@current_member}
            nav_current={@nav_current}
          />
          <div class="flex min-h-dvh min-w-0 flex-col">
            <.topbar
              current_scope={@current_scope}
              current_installation={@current_installation}
              current_member={@current_member}
            />
            <main id="main-content" tabindex="-1" class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
              <div class="mx-auto max-w-5xl space-y-6">
                {render_slot(@inner_block)}
              </div>
            </main>
          </div>
        </div>
      <% else %>
        <header class="flex items-center justify-between border-b border-line bg-raised px-4 py-3 sm:px-6">
          <.link navigate={~p"/"} class="text-sm font-semibold text-ink">Workflow Automation</.link>
          <.theme_toggle />
        </header>
        <main id="main-content" tabindex="-1" class="px-4 py-12 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      <% end %>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
