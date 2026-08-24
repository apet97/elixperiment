defmodule PumbleAutomation.Pumble.Response do
  @moduledoc """
  The per-class response contract, in one place.

  Pumble's callback classes do not share a reply shape, and the differences are
  not cosmetic — an event is answered with plain text and has no failure reply
  at all, while an interaction is answered with JSON and may be refused. Every
  status code and body shape this application sends back to Pumble is built
  here, so the rules can be read, tested, and changed once.

  The four constructors and their evidence:

    * `event_ack/0` — `200` with the plain-text body `ok` (`K-6`). Events have
      no acknowledgement helper and no negative reply; the SDK answers `ok`
      before it even runs the handler.
    * `ack/1` — `200` `application/json` with `{"message": …}`, or `{}` when no
      message is given, because an omitted argument is dropped by JSON encoding
      in the SDK (`K-1`). Applies to `C-2` through `C-8`.
    * `nack/2` — the refusal for the same classes, `400` by default, with
      `{"message": …}` (`K-2`). The HTTP adapter defaults to `400`; only the
      socket adapter uses `500`, and this application has no socket transport.
    * `response/1` — `200` `application/json` with an arbitrary body (`K-3`).
      This is how a modal envelope or a dynamic-menu options list is returned.

  ## One response, and only one

  All three SDK helpers check `res.headersSent` and silently do nothing on a
  second call (`K-8`). This module makes that guard unnecessary rather than
  reimplementing it: a constructor returns a value, the caller sends it once,
  and there is no second write to suppress. An acknowledgement and a modal are
  mutually exclusive for the same reason (`X-1`), which is a property of the
  transport and not a rule this application may relax.

  ## Messages are for people, not for debugging

  Whatever Pumble does with `message` — `PR-14` has not settled whether the user
  sees it — a refusal message is written as if the user reads it. It never names
  an internal module, a database state, an exception, or any part of the
  callback content.
  """

  @typedoc """
  A terminal response: the encoding, the status, and the body.

  `:text` bodies are sent as `text/plain`; `:json` bodies are encoded as
  `application/json`.
  """
  @type t :: {:text, 200, String.t()} | {:json, pos_integer(), map()}

  @doc "The acknowledgement for an ordinary Pumble event (`C-1`, `K-6`)."
  @spec event_ack() :: {:text, 200, String.t()}
  def event_ack, do: {:text, 200, "ok"}

  @doc """
  The positive acknowledgement for an interactive callback (`K-1`).

  With no message the body is `{}`, which is what the SDK sends when `ack()` is
  called with no argument.
  """
  @spec ack(String.t() | nil) :: {:json, 200, map()}
  def ack(message \\ nil)
  def ack(nil), do: {:json, 200, %{}}
  def ack(message) when is_binary(message), do: {:json, 200, %{"message" => message}}

  @doc """
  The negative acknowledgement for an interactive callback (`K-2`).

  `status` defaults to `400`, the HTTP adapter's default.
  """
  @spec nack(String.t(), pos_integer()) :: {:json, pos_integer(), map()}
  def nack(message, status \\ 400) when is_binary(message) and is_integer(status) do
    {:json, status, %{"message" => message}}
  end

  @doc "An arbitrary JSON reply, such as a modal or an options envelope (`K-3`)."
  @spec response(map()) :: {:json, 200, map()}
  def response(body) when is_map(body), do: {:json, 200, body}
end
