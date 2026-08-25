defmodule PumbleAutomationWeb.Plugs.CacheRawBody do
  @moduledoc """
  The body reader `Plug.Parsers` uses, so that a Pumble callback or inbound
  webhook keeps its bytes.

  A HMAC is computed over the entity body exactly as it arrived. Decoding JSON
  and re-encoding it changes key order, whitespace, and escaping, so a signature
  computed after a parse is a signature over different bytes and proves nothing.
  This reader therefore runs *inside* `Plug.Parsers`, before any decoder sees the
  body, and stores what it read in `conn.private[:raw_body]`.

  ## Which paths are retained

  Pumble callback paths and inbound webhook paths are accumulated here with
  their configured body caps and stored on `conn.private[:raw_body]`. Every
  other request is accumulated against `Limits.get(:max_request_body_bytes)`
  and is not retained.

  ## Limits

  `config :pumble_automation, :pumble_callbacks` supplies the callback body limit
  from the product limits, the per-read chunk size, and the read timeout. Inbound
  webhooks use `:inbound_webhooks` for their 512 KiB cap. The limit is checked
  after every chunk, so an oversized body is refused while it is still arriving
  rather than after it has been buffered whole.

  ## Failure behavior

    * over the limit — `Plug.Parsers.RequestTooLargeError`, which Plug renders as
      `413`;
    * a truncated or unreadable read — `Plug.BadRequestError`, rendered as `400`.

  Both are raised before a decoder runs, so an over-limit or truncated callback
  never reaches the router.

  ## What is never logged

  The raw body is not logged, not put in `conn.assigns`, and not copied into
  params. A callback body may carry the text of a private message. The only
  consumers of these bytes are
  `PumbleAutomationWeb.Plugs.VerifyPumbleSignature` for Pumble callbacks and
  `PumbleAutomation.Ingress.WebhookService` for generic webhook raw-body HMAC
  verification and receipt hashing.

  ## A note for reverse proxies

  The bytes must arrive unchanged. A proxy that re-encodes JSON, re-chunks with a
  transformation, or strips a trailing newline breaks every signature. Pass the
  body through verbatim.
  """

  alias PumbleAutomation.Limits

  @doc """
  Reads the request body, retaining the raw bytes for a Pumble callback.

  Matches the `:body_reader` contract of `Plug.Parsers`: it is called with the
  connection and the reader options.

  Every path answers `{:ok, body, conn}` — it reads to the end or raises. The
  per-path cap is applied while the body is still arriving.
  """
  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()}
  def read_body(%Plug.Conn{} = conn, _opts) do
    {limit, retain?} = path_policy(conn.request_path)
    settings = settings()

    read_opts = [
      length: settings[:read_length],
      read_length: settings[:read_length],
      read_timeout: settings[:read_timeout]
    ]

    accumulate(conn, read_opts, limit, [], 0, retain?)
  end

  @doc "The configured callback path prefix."
  @spec path_prefix() :: String.t()
  def path_prefix, do: settings()[:path_prefix]

  @doc "The configured callback body limit, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: Limits.get(:pumble_callback_body_bytes)

  @doc "True when `path` is under the configured callback prefix."
  @spec callback_path?(String.t()) :: boolean()
  def callback_path?(path) when is_binary(path), do: String.starts_with?(path, path_prefix())

  @doc "True when `path` is under the inbound webhook prefix."
  @spec webhook_path?(String.t()) :: boolean()
  def webhook_path?(path) when is_binary(path) do
    String.starts_with?(path, webhook_path_prefix())
  end

  defp path_policy(path) do
    cond do
      callback_path?(path) -> {max_body_bytes(), true}
      webhook_path?(path) -> {webhook_max_body_bytes(), true}
      true -> {Limits.get(:max_request_body_bytes), false}
    end
  end

  defp webhook_path_prefix do
    :pumble_automation
    |> Application.get_env(:inbound_webhooks, [])
    |> Keyword.get(:path_prefix, "/hooks")
  end

  defp webhook_max_body_bytes do
    Limits.get(:generic_webhook_body_bytes)
  end

  defp accumulate(conn, opts, limit, chunks, size, retain?) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        chunks = check_limit([chunk | chunks], size + byte_size(chunk), limit)
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        conn = if retain?, do: Plug.Conn.put_private(conn, :raw_body, body), else: conn

        {:ok, body, conn}

      {:more, chunk, conn} ->
        size = size + byte_size(chunk)
        chunks = check_limit([chunk | chunks], size, limit)

        accumulate(conn, opts, limit, chunks, size, retain?)

      {:error, _reason} ->
        raise Plug.BadRequestError
    end
  end

  defp check_limit(_chunks, size, limit) when size > limit do
    raise Plug.Parsers.RequestTooLargeError
  end

  defp check_limit(chunks, _size, _limit), do: chunks

  defp settings, do: Application.fetch_env!(:pumble_automation, :pumble_callbacks)
end
