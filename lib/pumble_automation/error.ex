defmodule PumbleAutomation.Error do
  @moduledoc """
  The shared internal error vocabulary.

  Every domain returns the same shape when an operation fails, so callers can
  classify a failure without matching on the module that produced it. Six fields
  carry everything a caller, a log line, and a retry policy need:

    * `:class` — the broad category, used to choose a response and a retry rule.
    * `:code` — a stable, specific atom. Log lines and metrics group by it.
    * `:message` — a short sentence that is safe to show to a user or to write
      into an API response. It never names a host, a credential, or a value.
    * `:retryable?` — whether repeating the same call can succeed later.
    * `:details` — structured context for logs only. Never rendered to a client.
    * `:cause` — the underlying error, exception, or `t:t/0`, for logs only.

  ## No web types

  This module and the errors it builds contain no `Plug` or `Phoenix` type. A
  domain that returns an error must not know how that error becomes an HTTP
  status, and a domain function must stay callable from a job, a mix task, or a
  test with no connection in scope. The web layer owns the mapping from
  `:class` to a status code.

  ## Redaction

  `:details` is written to logs, and logs are read by more people than the
  request was. `new/3` therefore runs `sanitize/1` over the details before
  storing them: any key that reads like a token, secret, code, password,
  credential, signature, cookie, or authorization header has its value replaced
  with `"[REDACTED]"`. Nested maps, lists, and keyword lists are walked too.

  Redaction is a safety net, not a licence. Do not put a secret in `:details`
  and rely on the pattern to catch it, because the pattern only knows the names
  it was taught.
  """

  @redacted "[REDACTED]"

  # Key names whose values are never safe to log. Matched case-insensitively
  # against the key of every detail entry, at every depth.
  @secret_key_pattern ~r/(token|secret|code|password|passwd|credential|api[_-]?key|signature|cookie|authorization|bearer)/i

  @typedoc """
  The broad failure category.

    * `:validation` — the caller sent something the domain refuses.
    * `:not_found` — the addressed resource does not exist or is not visible.
    * `:conflict` — the resource exists in a state that forbids the operation.
    * `:permission` — the actor is known but not allowed.
    * `:dependency` — something this application depends on failed.
    * `:timeout` — a bounded wait elapsed.
    * `:rate_limited` — a quota was reached.
    * `:internal` — a defect in this application.
  """
  @type class ::
          :validation
          | :not_found
          | :conflict
          | :permission
          | :dependency
          | :timeout
          | :rate_limited
          | :internal

  @type t :: %__MODULE__{
          class: class(),
          code: atom(),
          message: String.t(),
          retryable?: boolean(),
          details: map(),
          cause: term()
        }

  @enforce_keys [:class, :code, :message]
  defstruct [:class, :code, :message, :cause, retryable?: false, details: %{}]

  @doc """
  Builds an error of `class` identified by `code`.

  Options:

    * `:message` — the safe message. Defaults to a generic sentence for the
      class, which is always safe but rarely useful, so pass one.
    * `:retryable?` — defaults to the usual answer for the class.
    * `:details` — a map of log-only context. It is sanitized before storage.
    * `:cause` — the underlying error, for logs only.

  ## Examples

      iex> error = PumbleAutomation.Error.new(:validation, :bad_action, details: %{token: "abc"})
      iex> error.details
      %{token: "[REDACTED]"}

  """
  @spec new(class(), atom(), keyword()) :: t()
  def new(class, code, opts \\ []) when is_atom(class) and is_atom(code) do
    %__MODULE__{
      class: class,
      code: code,
      message: Keyword.get(opts, :message, default_message(class)),
      retryable?: Keyword.get(opts, :retryable?, default_retryable?(class)),
      details: opts |> Keyword.get(:details, %{}) |> sanitize(),
      cause: Keyword.get(opts, :cause)
    }
  end

  @doc """
  Returns whether repeating the same call can succeed later.
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{retryable?: retryable?}), do: retryable?

  @doc """
  Replaces the value of every secret-looking key with `"[REDACTED]"`.

  Walks plain maps, lists, and two-element tuples, so keyword lists and nested
  structures are covered. Structs and scalars are returned unchanged, because a
  struct carries its own meaning and this function must not rebuild it.
  """
  @spec sanitize(term()) :: term()
  def sanitize(details) when is_map(details) and not is_struct(details) do
    Map.new(details, fn {key, value} -> sanitize_entry(key, value) end)
  end

  def sanitize(details) when is_list(details) do
    Enum.map(details, &sanitize/1)
  end

  def sanitize({key, value}), do: sanitize_entry(key, value)

  def sanitize(other), do: other

  @doc """
  Returns the pattern that `sanitize/1` matches key names against.

  Exposed so that other modules can hold their own allowlists to the same
  standard in a test, instead of copying the pattern and drifting from it.
  """
  @spec secret_key_pattern() :: Regex.t()
  def secret_key_pattern, do: @secret_key_pattern

  defp sanitize_entry(key, value) do
    if secret_key?(key) do
      {key, @redacted}
    else
      {key, sanitize(value)}
    end
  end

  defp secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()
  defp secret_key?(key) when is_binary(key), do: Regex.match?(@secret_key_pattern, key)
  defp secret_key?(_key), do: false

  defp default_message(:validation), do: "The request is not valid."
  defp default_message(:not_found), do: "The resource was not found."
  defp default_message(:conflict), do: "The resource is in a conflicting state."
  defp default_message(:permission), do: "The action is not permitted."
  defp default_message(:dependency), do: "A dependency is unavailable."
  defp default_message(:timeout), do: "The operation timed out."
  defp default_message(:rate_limited), do: "The rate limit was reached."
  defp default_message(:internal), do: "An internal error occurred."

  defp default_retryable?(class), do: class in [:dependency, :timeout, :rate_limited]
end
