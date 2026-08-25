defmodule PumbleAutomation.Pumble.Blocks do
  @moduledoc """
  The message payloads this product sends, and nothing else.

  v1 posts four things: a message, a threaded reply, a direct message, and an
  approval message carrying two buttons (product contract). This module builds
  exactly those and refuses everything else. It
  is not a block-kit port: a constructor exists here because a v1 node needs it,
  and the absent constructors are absent on purpose.

  ## Shapes

  The message request is `{text, blocks?, attachments?, files?}` — SDK source
  `api/v1/MessagesApiClientV1.ts`, `processMessagePayload()`. Block shapes come
  from SDK documentation `docs/blocks.md`: a `rich_text` block wraps
  `rich_text_section` elements, which wrap `text` elements; an `actions` block
  wraps `button` elements whose label is a `plain_text` element. These are SDK
  documentation, not live probes, so they are `INFERRED` for this application.

  Every interactive element is emitted with `loadingTimeout: 0`. Matrix `X-6`
  records why: a positive value starts a client-side spinner that only the
  internal `POST /v1/interactions/complete` endpoint can stop, and that endpoint
  is marked internal and must not be called. Zero makes it unnecessary.

  ## Limits are local and say so

  Pumble publishes no message-size limit, and `PR-12` is open on the one it
  enforces. The caps here are this application's own, chosen to be far below any
  plausible provider limit, and a payload that exceeds one is refused locally
  rather than sent to find out. The button label cap of 75 characters is the one
  documented number (`docs/blocks.md`, Button).

  ## User content is data, never markup

  Text is carried in a `text` element's `text` field, which the provider renders
  as content rather than parsing as markup, so nothing here escapes or rewrites
  what a user wrote. What it does do is refuse it: text must be a binary, must
  be non-empty once trimmed, and must be inside the cap and valid UTF-8.
  """

  alias PumbleAutomation.Pumble.Client.Error

  @max_text_bytes 8_000
  @max_button_label_length 75
  @max_blocks 50

  # `ReactionRequest` validates `code` as `:.*:` with length 3 to 200 — SDK
  # source `api/v1/types.ts`. Server enforcement is `INFERRED`, so the same
  # check happens here before a request is built.
  @reaction_code_pattern ~r/\A:.*:\z/
  @min_reaction_code_length 3
  @max_reaction_code_length 200

  @typedoc "A JSON-ready message request body."
  @type message :: %{required(String.t()) => term()}

  @doc """
  Builds a plain text message body.

  Returns `{:error, error}` with class `:validation` when the text is empty,
  oversized, or not a valid UTF-8 binary.
  """
  @spec message(String.t()) :: {:ok, message()} | {:error, Error.t()}
  def message(text) do
    with {:ok, text} <- validate_text(text) do
      {:ok, %{"text" => text}}
    end
  end

  @doc """
  Builds a message body carrying pre-built blocks alongside its text.

  The text is still required: it is what a client that cannot render blocks
  shows, and Pumble's own request type makes it mandatory.
  """
  @spec message(String.t(), [map()]) :: {:ok, message()} | {:error, Error.t()}
  def message(text, blocks) when is_list(blocks) do
    with {:ok, text} <- validate_text(text),
         :ok <- validate_blocks(blocks) do
      {:ok, %{"text" => text, "blocks" => blocks}}
    end
  end

  def message(_text, _blocks), do: {:error, invalid("blocks must be a list")}

  @doc """
  Builds a workflow send/reply/DM body from rendered text and optional blocks.

  Workflow nodes may only attach `rich_text` blocks. Auth-looking keys and
  URL/endpoint fields are refused so a template cannot set credentials or
  name a Pumble path. `nil` or `[]` produces a text-only body.
  """
  @spec workflow_message(String.t(), [map()] | nil) :: {:ok, message()} | {:error, Error.t()}
  def workflow_message(text, blocks \\ nil)

  def workflow_message(text, blocks) when blocks in [nil, []], do: message(text)

  def workflow_message(text, blocks) when is_list(blocks) do
    with :ok <- validate_workflow_blocks(blocks) do
      message(text, blocks)
    end
  end

  def workflow_message(_text, _blocks), do: {:error, invalid("blocks must be a list")}

  @doc """
  Builds the approval message: one line of text and two buttons.

  `approve` and `reject` are `{label, action_id, value}`. The action id is what
  the block-interaction callback carries back, so it is how a click is matched
  to a waiting approval node.
  """
  @spec approval_message(String.t(), {String.t(), String.t(), String.t()}, {
          String.t(),
          String.t(),
          String.t()
        }) :: {:ok, message()} | {:error, Error.t()}
  def approval_message(text, approve, reject) do
    with {:ok, text} <- validate_text(text),
         {:ok, approve_button} <- button(approve, "primary"),
         {:ok, reject_button} <- button(reject, "danger") do
      {:ok,
       %{
         "text" => text,
         "blocks" => [
           rich_text(text),
           %{"type" => "actions", "elements" => [approve_button, reject_button]}
         ]
       }}
    end
  end

  @doc """
  Builds a reaction request body.

  `skin_tone` is optional and omitted when `nil`, because the provider's type
  makes it optional and an explicit `null` is not the same as an absent field.
  """
  @spec reaction(String.t(), integer() | nil) :: {:ok, map()} | {:error, Error.t()}
  def reaction(code, skin_tone \\ nil)

  def reaction(code, skin_tone) when is_binary(code) do
    cond do
      String.length(code) < @min_reaction_code_length or
          String.length(code) > @max_reaction_code_length ->
        {:error,
         invalid(
           "a reaction code is between #{@min_reaction_code_length} and " <>
             "#{@max_reaction_code_length} characters"
         )}

      not Regex.match?(@reaction_code_pattern, code) ->
        {:error, invalid("a reaction code is wrapped in colons")}

      is_nil(skin_tone) ->
        {:ok, %{"code" => code}}

      is_integer(skin_tone) ->
        {:ok, %{"code" => code, "skinTone" => skin_tone}}

      true ->
        {:error, invalid("a skin tone is an integer")}
    end
  end

  def reaction(_code, _skin_tone), do: {:error, invalid("a reaction code is a string")}

  @doc """
  Builds a Home view publish body from pre-built blocks.

  `PublishHomeViewRequest` is `{blocks, title?, state?}` — SDK source
  `api/v1/types.ts`. Only `blocks` is sent, because that is all the onboarding
  view needs.
  """
  @spec home_view([map()]) :: {:ok, map()} | {:error, Error.t()}
  def home_view(blocks) when is_list(blocks) do
    with :ok <- validate_blocks(blocks) do
      {:ok, %{"blocks" => blocks}}
    end
  end

  def home_view(_blocks), do: {:error, invalid("blocks must be a list")}

  @doc """
  Builds one `rich_text` block holding a single line of text.

  Exposed because a Home view and an approval message both need one, and a
  caller assembling blocks should not have to spell the nesting out again.
  """
  @spec rich_text(String.t()) :: map()
  def rich_text(text) when is_binary(text) do
    %{
      "type" => "rich_text",
      "elements" => [
        %{
          "type" => "rich_text_section",
          "elements" => [%{"type" => "text", "text" => text}]
        }
      ]
    }
  end

  @doc "The largest message text this application sends, in bytes."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "The largest number of blocks this application sends in one payload."
  @spec max_blocks() :: pos_integer()
  def max_blocks, do: @max_blocks

  @doc """
  Returns a copy of `message` with interactive button values redacted.

  Operators and dry-run traces may show the block shape. They must not show
  the bound action payload.
  """
  @spec redact_interactive(map()) :: map()
  def redact_interactive(message) when is_map(message) do
    case Map.get(message, "blocks") do
      blocks when is_list(blocks) -> Map.put(message, "blocks", Enum.map(blocks, &redact_block/1))
      _missing -> message
    end
  end

  def redact_interactive(message), do: message

  defp button({label, action_id, value}, style)
       when is_binary(label) and is_binary(action_id) and is_binary(value) do
    cond do
      String.trim(label) == "" or String.length(label) > @max_button_label_length ->
        {:error, invalid("a button label is 1 to #{@max_button_label_length} characters")}

      String.trim(action_id) == "" ->
        {:error, invalid("a button needs an action id")}

      true ->
        {:ok,
         %{
           "type" => "button",
           "text" => %{"type" => "plain_text", "text" => label},
           "onAction" => action_id,
           "value" => value,
           "style" => style,
           "loadingTimeout" => 0
         }}
    end
  end

  defp button(_spec, _style), do: {:error, invalid("a button is {label, action id, value}")}

  defp redact_block(%{"type" => "actions", "elements" => elements} = block)
       when is_list(elements) do
    Map.put(block, "elements", Enum.map(elements, &redact_element/1))
  end

  defp redact_block(block), do: block

  defp redact_element(%{"type" => "button"} = element) do
    Map.put(element, "value", "[REDACTED]")
  end

  defp redact_element(element), do: element

  defp validate_text(text) when is_binary(text) do
    cond do
      not String.valid?(text) -> {:error, invalid("message text must be valid UTF-8")}
      String.trim(text) == "" -> {:error, invalid("message text must not be empty")}
      byte_size(text) > @max_text_bytes -> {:error, invalid(too_long())}
      true -> {:ok, text}
    end
  end

  defp validate_text(_text), do: {:error, invalid("message text must be a string")}

  defp validate_blocks(blocks) when is_list(blocks) do
    cond do
      length(blocks) > @max_blocks ->
        {:error, invalid("a message carries at most #{@max_blocks} blocks")}

      not Enum.all?(blocks, &is_map/1) ->
        {:error, invalid("every block must be a map")}

      true ->
        :ok
    end
  end

  @workflow_block_types ~w(rich_text)
  @forbidden_block_key ~r/(token|secret|authorization|header|endpoint|url|host|cookie|bearer|password)/i

  defp validate_workflow_blocks(blocks) when is_list(blocks) do
    with :ok <- validate_blocks(blocks) do
      cond do
        not Enum.all?(blocks, &supported_workflow_block?/1) ->
          {:error,
           invalid("workflow blocks must be rich_text and must not set auth or endpoints")}

        Enum.any?(blocks, &forbidden_block_keys?/1) ->
          {:error, invalid("workflow blocks must not set auth headers or endpoints")}

        true ->
          :ok
      end
    end
  end

  defp supported_workflow_block?(block) when is_map(block) do
    type = Map.get(block, "type") || Map.get(block, :type)
    type in @workflow_block_types
  end

  defp supported_workflow_block?(_block), do: false

  defp forbidden_block_keys?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, inner} ->
      forbidden_block_key?(key) or forbidden_block_keys?(inner)
    end)
  end

  defp forbidden_block_keys?(values) when is_list(values) do
    Enum.any?(values, &forbidden_block_keys?/1)
  end

  defp forbidden_block_keys?(_value), do: false

  defp forbidden_block_key?(key) when is_atom(key) do
    key |> Atom.to_string() |> forbidden_block_key?()
  end

  defp forbidden_block_key?(key) when is_binary(key), do: Regex.match?(@forbidden_block_key, key)
  defp forbidden_block_key?(_key), do: false

  defp too_long do
    "message text is at most #{@max_text_bytes} bytes (a local limit; PR-12 is open " <>
      "on the provider's own)"
  end

  defp invalid(summary), do: Error.new(:validation, body_summary: summary)
end
