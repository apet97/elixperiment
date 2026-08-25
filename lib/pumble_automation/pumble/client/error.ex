defmodule PumbleAutomation.Pumble.Client.Error do
  @moduledoc """
  The only failure shape a Pumble API call produces.

  The Pumble client contract fixes the four fields: `:class`, `:status`, `:retry_after`,
  and `:body_summary`. Two more are carried because a log line without them
  cannot be acted on: `:operation`, which names the adapter function that
  failed, and `:provider_request_id`, which is the correlation value the far
  side returned, if it returned one.

  `:class` is drawn from the Pumble client error taxonomy. The classifier never invents a
  class outside it, and it never decides *whether to retry*: that is the node
  runner's decision, made from the class and the action's own semantics. See
  `PumbleAutomation.Pumble.Client.retry_safety/1`.

  ## What the status classes mean here

  | Status | Class | Retry |
  |---|---|---|
  | 400 | `:validation` | never — the payload is wrong |
  | 401 | `:authentication` | never — the credential is gone |
  | 403 | `:missing_scope` or `:authorization` | never |
  | 404 | `:not_found` | never |
  | 409 | `:conflict` | never |
  | 429 | `:rate_limited` | after `:retry_after` |
  | 5xx, idempotent effect | `:remote_transient` | yes |
  | 5xx, other | `:side_effect_uncertain` | not automatically |
  | other 4xx | `:remote_permanent` | never |

  `401` and `403` are never transient. A retry cannot make a revoked token valid
  or change a provider permission refusal, and repeating the call only
  reproduces the failure against a workspace that already refused it.

  A `5xx` on a write is `:side_effect_uncertain` rather than `:remote_transient`
  because Pumble publishes no idempotency key on writes (`U-3`, `PR-09`): an
  error status does not prove the message was not posted. The uncertain outcome
  goes to an operator instead of being replayed into a duplicate message.

  ## Bounded, redacted summaries

  `:body_summary` exists to answer "what did the far side say?" in a log line,
  not to carry the response. It is truncated to #{256} bytes, stripped of
  control characters, and — when the body is JSON — passed through
  `PumbleAutomation.Error.sanitize/1`, so a token echoed back in an error body
  does not reach a log.
  """

  alias PumbleAutomation.Error, as: DomainError

  @max_summary_bytes 256

  # `Retry-After` is `INFERRED` for Pumble (`H-14`, `PR-08`): no header name is
  # proven and none appears in the vendor SDK. A value is therefore a hint, and
  # a hint is clamped. Anything outside the window is replaced by the ceiling
  # rather than trusted, so a hostile or broken header cannot park a job for a
  # day or spin it in a tight loop.
  @min_retry_after_seconds 1
  @max_retry_after_seconds 900

  @typedoc """
  The error classes this boundary can produce.
  """
  @type class ::
          :validation
          | :authentication
          | :authorization
          | :missing_scope
          | :installation_revoked
          | :not_found
          | :conflict
          | :rate_limited
          | :transient_transport
          | :remote_transient
          | :remote_permanent
          | :ambiguous_transport
          | :side_effect_uncertain
          | :resource_limit
          | :internal_invariant

  @type t :: %__MODULE__{
          class: class(),
          status: non_neg_integer() | nil,
          retry_after: pos_integer() | nil,
          body_summary: String.t() | nil,
          operation: atom() | nil,
          provider_request_id: String.t() | nil
        }

  @enforce_keys [:class]
  defstruct [:class, :status, :retry_after, :body_summary, :operation, :provider_request_id]

  @doc """
  Builds an error of `class`.

  Options are the remaining struct fields. `:body_summary` is summarized and
  redacted here, so a caller may pass a raw body.
  """
  @spec new(class(), keyword()) :: t()
  def new(class, opts \\ []) when is_atom(class) do
    %__MODULE__{
      class: class,
      status: Keyword.get(opts, :status),
      retry_after: Keyword.get(opts, :retry_after),
      body_summary: opts |> Keyword.get(:body_summary) |> summarize(),
      operation: Keyword.get(opts, :operation),
      provider_request_id: Keyword.get(opts, :provider_request_id)
    }
  end

  @doc """
  Classifies an HTTP response that is not a success.

  Options:

    * `:operation` — the adapter function that made the call.
    * `:provider_request_id` — the sanitized correlation value, if any.
    * `:retry_after_header` — the raw header value, if any.
    * `:idempotent_effect?` — whether repeating this call cannot duplicate an
      effect. It decides the `5xx` class and nothing else.
    * `:scope` — the scope this operation maps to, which turns a `403` into
      `:missing_scope` instead of a bare `:authorization`.
  """
  @spec from_status(non_neg_integer(), term(), keyword()) :: t()
  def from_status(status, body, opts \\ []) when is_integer(status) do
    opts
    |> Keyword.take([:operation, :provider_request_id])
    |> Keyword.merge(status: status, body_summary: body)
    |> Keyword.merge(status_fields(status, opts))
    |> then(&new(Keyword.fetch!(&1, :class), &1))
  end

  @doc """
  Classifies a transport failure, which has no status and no body.

  A failure that cannot have written anything is `:transient_transport`. A
  timeout or a closed connection may have delivered the request, so it is
  `:ambiguous_transport` unless the effect is idempotent, in which case
  repeating it is safe and the class is `:transient_transport`.
  """
  @spec from_transport(term(), keyword()) :: t()
  def from_transport(reason, opts \\ []) do
    class =
      cond do
        reason not in [:timeout, :closed] -> :transient_transport
        Keyword.get(opts, :idempotent_effect?, false) -> :transient_transport
        true -> :ambiguous_transport
      end

    new(class,
      operation: Keyword.get(opts, :operation),
      body_summary: "transport: #{inspect(reason)}"
    )
  end

  @doc """
  Translates a credential-resolution failure into this vocabulary.

  Resolution happens before the network, so these errors carry no status.
  """
  @spec from_credential_error(DomainError.t(), keyword()) :: t()
  def from_credential_error(%DomainError{code: code} = error, opts \\ []) do
    class =
      case code do
        :installation_not_found -> :not_found
        :installation_revoked -> :installation_revoked
        _other -> :authentication
      end

    new(class, operation: Keyword.get(opts, :operation), body_summary: error.message)
  end

  @doc """
  Whether repeating the identical call can succeed without a further decision.

  `:ambiguous_transport` and `:side_effect_uncertain` answer `false`: repeating
  them is a *policy* choice about duplicate effects, never an automatic one.
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{class: class}) do
    class in [:rate_limited, :transient_transport, :remote_transient]
  end

  @doc "The largest body summary this module stores, in bytes."
  @spec max_summary_bytes() :: pos_integer()
  def max_summary_bytes, do: @max_summary_bytes

  @doc """
  Parses a `Retry-After` header value into a bounded number of seconds.

  Accepts the delay-seconds form only. An HTTP-date, a malformed value, and an
  absent header all return `nil`; a value outside the bounds is clamped.
  """
  @spec parse_retry_after(term()) :: pos_integer() | nil
  def parse_retry_after(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> clamp_retry_after(seconds)
      _other -> nil
    end
  end

  def parse_retry_after([value | _rest]), do: parse_retry_after(value)
  def parse_retry_after(_value), do: nil

  defp clamp_retry_after(seconds) do
    seconds
    |> max(@min_retry_after_seconds)
    |> min(@max_retry_after_seconds)
  end

  defp status_fields(400, _opts), do: [class: :validation]
  defp status_fields(401, _opts), do: [class: :authentication]
  defp status_fields(404, _opts), do: [class: :not_found]
  defp status_fields(409, _opts), do: [class: :conflict]

  defp status_fields(403, opts) do
    if Keyword.get(opts, :scope), do: [class: :missing_scope], else: [class: :authorization]
  end

  defp status_fields(429, opts) do
    [
      class: :rate_limited,
      retry_after: opts |> Keyword.get(:retry_after_header) |> parse_retry_after()
    ]
  end

  defp status_fields(status, opts) when status >= 500 do
    if Keyword.get(opts, :idempotent_effect?, false) do
      [class: :remote_transient]
    else
      [class: :side_effect_uncertain]
    end
  end

  defp status_fields(_status, _opts), do: [class: :remote_permanent]

  # A decoded body is redacted key by key and then printed; anything else is
  # treated as text. Either way the result is one bounded, single-line string.
  defp summarize(nil), do: nil

  defp summarize(body) when is_map(body) or is_list(body) do
    body
    |> DomainError.sanitize()
    |> inspect(limit: 10, printable_limit: @max_summary_bytes)
    |> summarize()
  end

  defp summarize(body) when is_binary(body) do
    slice = binary_slice(body, 0, @max_summary_bytes)

    # A truncated UTF-8 body can end mid-codepoint, and a Pumble error body is
    # not guaranteed to be text at all. An invalid slice is described rather
    # than printed, because a regex over invalid UTF-8 raises.
    if String.valid?(slice) do
      slice
      |> String.replace(~r/[[:cntrl:]]+/u, " ")
      |> String.trim()
      |> case do
        "" -> nil
        summary -> summary
      end
    else
      "non-text body, #{byte_size(body)} bytes"
    end
  end

  defp summarize(body), do: body |> inspect() |> summarize()
end
