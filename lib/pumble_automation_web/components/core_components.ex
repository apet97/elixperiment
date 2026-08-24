defmodule PumbleAutomationWeb.CoreComponents do
  @moduledoc """
  Base UI primitives for the application shell.

  Styling is Tailwind utilities plus the design tokens in `assets/css/app.css`.
  Status always includes a text label so color is never the only signal.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 max-w-sm cursor-pointer rounded-lg border bg-raised p-4 shadow-lg",
        @kind == :info && "border-signal",
        @kind == :error && "border-danger"
      ]}
      {@rest}
    >
      <div class="flex gap-3">
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0 text-signal"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0 text-danger"
        />
        <div class="min-w-0 text-sm">
          <p :if={@title} class="font-semibold text-ink">{@title}</p>
          <p class="text-muted">{msg}</p>
        </div>
        <button type="button" class="ml-auto self-start text-muted hover:text-ink" aria-label="Close">
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any
  attr :variant, :string, values: ~w(primary secondary ghost danger)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "bg-signal text-raised hover:bg-signal-strong border-transparent",
      "secondary" => "bg-raised text-ink border-line hover:border-signal",
      "ghost" => "bg-transparent text-ink border-transparent hover:bg-surface",
      "danger" => "bg-danger text-raised border-transparent hover:opacity-90",
      nil => "bg-signal text-raised hover:bg-signal-strong border-transparent"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        [
          "inline-flex items-center justify-center gap-2 rounded-md border px-3 py-2 text-sm font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-50",
          Map.fetch!(variants, assigns[:variant])
        ]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "the form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"
  attr :describedby, :string, default: nil, doc: "the id of persistent field help text"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-2">
      <label for={@id} class="flex items-center gap-2 text-sm text-ink">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={describedby_ids(@describedby, field_error_id(@id, @errors))}
          class={
            @class ||
              "size-4 rounded border border-line bg-raised text-signal"
          }
          {@rest}
        />
        {@label}
      </label>
      <.field_errors id={@id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1 block text-sm font-medium text-ink">{@label}</span>
        <select
          id={@id}
          name={@name}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={describedby_ids(@describedby, field_error_id(@id, @errors))}
          class={[
            @class ||
              "w-full rounded-md border border-line bg-raised px-3 py-2 text-sm text-ink",
            @errors != [] && (@error_class || "border-danger")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.field_errors id={@id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1 block text-sm font-medium text-ink">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={describedby_ids(@describedby, field_error_id(@id, @errors))}
          class={[
            @class ||
              "w-full rounded-md border border-line bg-raised px-3 py-2 text-sm text-ink",
            @errors != [] && (@error_class || "border-danger")
          ]}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.field_errors id={@id} errors={@errors} />
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1 block text-sm font-medium text-ink">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={describedby_ids(@describedby, field_error_id(@id, @errors))}
          class={[
            @class ||
              "w-full rounded-md border border-line bg-raised px-3 py-2 text-sm text-ink",
            @errors != [] && (@error_class || "border-danger")
          ]}
          {@rest}
        />
      </label>
      <.field_errors id={@id} errors={@errors} />
    </div>
    """
  end

  defp field_errors(assigns) do
    ~H"""
    <div :if={@errors != []} id={"#{@id}-errors"} role="alert">
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp field_error_id(_id, []), do: nil
  defp field_error_id(id, _errors), do: "#{id}-errors"

  defp describedby_ids(help_id, error_id) do
    case Enum.reject([help_id, error_id], &(&1 in [nil, ""])) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm text-danger">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[
      @actions != [] && "flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between",
      "pb-4"
    ]}>
      <div class="min-w-0">
        <h1 class="pa-break text-xl font-semibold leading-8 text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex flex-wrap gap-2 sm:flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :caption, :string, default: nil, doc: "visually hidden table caption"
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto rounded-lg border border-line bg-raised">
      <table class="w-full text-left text-sm">
        <caption :if={@caption} class="sr-only">{@caption}</caption>
        <thead class="border-b border-line bg-surface text-muted">
          <tr>
            <th :for={col <- @col} class="px-3 py-2 font-medium">{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="border-b border-line last:border-0"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={["px-3 py-2", @row_click && "hover:cursor-pointer"]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="px-3 py-2">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-line rounded-lg border border-line bg-raised">
      <li :for={item <- @item} class="px-4 py-3">
        <div class="text-xs font-medium uppercase tracking-wide text-muted">{item.title}</div>
        <div class="mt-1 text-sm text-ink">{render_slot(item)}</div>
      </li>
    </ul>
    """
  end

  @doc """
  Surface card for grouped content.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :header
  slot :actions

  def card(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "rounded-lg border border-line bg-raised p-5 shadow-[0_1px_0_rgba(21,32,40,0.04)]",
        @class
      ]}
    >
      <header
        :if={@header != [] or @actions != []}
        class="mb-4 flex items-start justify-between gap-4"
      >
        <div class="text-sm font-semibold text-ink">{render_slot(@header)}</div>
        <div>{render_slot(@actions)}</div>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Status pill. The label is required so color is never the only signal.
  """
  attr :id, :string, required: true
  attr :tone, :string, values: ~w(neutral ok warn danger info)
  attr :label, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span
      id={@id}
      class="inline-flex items-center gap-2 rounded-full border border-line bg-surface px-2.5 py-1 text-xs font-medium text-ink"
    >
      <span class={["size-2 rounded-full", tone_dot(@tone)]} aria-hidden="true"></span>
      {@label}
    </span>
    """
  end

  @doc """
  Inline banner for recovery, warnings, and confirmations.
  """
  attr :id, :string, required: true
  attr :tone, :string, values: ~w(info warn danger ok)
  attr :title, :string, required: true
  slot :inner_block, required: true

  def banner(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class={[
        "rounded-lg border bg-surface px-4 py-3",
        @tone == "info" && "border-signal",
        @tone == "ok" && "border-ok",
        @tone == "warn" && "border-warn",
        @tone == "danger" && "border-danger"
      ]}
    >
      <p class="text-sm font-semibold text-ink">{@title}</p>
      <div class="mt-1 text-sm text-muted">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Empty collection state with a next action slot."
  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class="pa-state rounded-lg border border-dashed border-line bg-surface px-6 py-10 text-center"
    >
      <p class="text-base font-semibold text-ink">{@title}</p>
      <p class="mx-auto mt-2 max-w-md text-sm text-muted">{render_slot(@inner_block)}</p>
      <div :if={@action != []} class="mt-4">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc "Loading placeholder."
  attr :id, :string, required: true
  attr :label, :string, default: "Loading"

  def loading_state(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      aria-busy="true"
      aria-live="polite"
      class="pa-state rounded-lg border border-line bg-surface px-4 py-6 text-sm text-muted"
    >
      <.icon name="hero-arrow-path" class="mr-2 inline size-4 motion-safe:animate-spin" />
      {@label}
    </div>
    """
  end

  @doc "Safe error placeholder. Do not pass exception messages from production."
  attr :id, :string, required: true
  attr :title, :string, default: "Something went wrong"
  slot :inner_block, required: true

  def error_state(assigns) do
    ~H"""
    <div id={@id} role="alert" class="pa-state rounded-lg border border-danger bg-surface px-4 py-4">
      <p class="text-sm font-semibold text-ink">{@title}</p>
      <p class="mt-1 text-sm text-muted">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  @doc """
  Modal dialog used for confirmations. Escape cancels. Focus moves to the first
  control when the dialog mounts.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_cancel, :any, required: true
  attr :class, :any, default: "max-w-md"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-40 flex items-end justify-center bg-ink/40 p-4 sm:items-center"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-mounted={JS.focus_first(to: "##{@id}-panel")}
      phx-window-keydown={cancel_command(@on_cancel)}
      phx-key="Escape"
    >
      <div
        id={"#{@id}-panel"}
        tabindex="-1"
        class={[
          "w-full max-h-[90dvh] overflow-y-auto rounded-lg border border-line bg-raised p-5 shadow-xl",
          @class
        ]}
      >
        <h2 id={"#{@id}-title"} class="text-lg font-semibold text-ink">{@title}</h2>
        <div class="mt-2">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  defp cancel_command(%JS{} = js), do: js
  defp cancel_command(event) when is_binary(event), do: JS.push(event)

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Interpolates Ecto `%{field}` placeholders in an error message.
  """
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp tone_dot("ok"), do: "bg-ok"
  defp tone_dot("warn"), do: "bg-warn"
  defp tone_dot("danger"), do: "bg-danger"
  defp tone_dot("info"), do: "bg-info"
  defp tone_dot(_neutral), do: "bg-muted"
end
