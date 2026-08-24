defmodule PumbleAutomationWeb.CopyComponents do
  @moduledoc """
  Client-side copy controls for values that must never make a server round trip.
  """
  use PumbleAutomationWeb, :html

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :type, :string, default: "text", values: ~w(password text url)
  attr :autocomplete, :string, default: nil
  slot :help

  def copy_field(assigns) do
    ~H"""
    <div>
      <label for={@id} class="block text-sm font-medium text-ink">{@label}</label>
      <div class="mt-1 flex items-stretch gap-2">
        <input
          id={@id}
          type={@type}
          readonly
          value={@value}
          autocomplete={@autocomplete}
          aria-describedby={@help != [] && "#{@id}-help"}
          class="min-w-0 flex-1 rounded-md border border-line bg-surface px-3 py-2 font-mono text-xs text-ink"
        />
        <div
          id={"#{@id}-copy-control"}
          phx-hook="CopyToClipboard"
          phx-update="ignore"
          data-copy-source={@id}
          data-copy-label={@label}
        >
          <button
            id={"#{@id}-copy"}
            type="button"
            aria-label={"Copy #{@label}"}
            aria-describedby={"#{@id}-copy-status"}
            class="inline-flex h-full items-center gap-1.5 rounded-md border border-line bg-raised px-3 py-2 text-xs font-medium text-ink transition hover:border-signal hover:text-signal-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-signal"
          >
            <.icon name="hero-clipboard-document-micro" class="size-4" />
            <span data-copy-button-label>Copy</span>
          </button>
          <span
            id={"#{@id}-copy-status"}
            role="status"
            aria-live="polite"
            aria-atomic="true"
            class="sr-only"
          ></span>
        </div>
      </div>
      <p :if={@help != []} id={"#{@id}-help"} class="mt-1 text-xs text-muted">
        {render_slot(@help)}
      </p>
    </div>
    """
  end
end
