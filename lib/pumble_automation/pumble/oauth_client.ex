defmodule PumbleAutomation.Pumble.OauthClient do
  @moduledoc """
  The one way to turn a Pumble authorization code into credentials.

  This module owns a single wire operation, `A-16` in
  `docs/evidence/pumble_source_matrix.md`: `POST {base}/oauth2/access` with a
  `multipart/form-data` body of exactly three fields named `client-id`,
  `client-secret`, and `code`. The names are hyphenated, not underscored, and
  the request is *unauthenticated*: it carries neither the `token` nor the
  `x-app-token` header every other Pumble call carries (`H-16`). The vendor SDK
  sends it through a bare HTTP client for that reason, and so does this one.

  The response is five fields and nothing else — `accessToken`, `botToken?`,
  `userId`, `botId?`, `workspaceId`. There is no expiry, no scope list, and no
  refresh token, and no refresh endpoint exists (`A-21`). A caller that wants to
  know which scopes a credential carries must use the set this application
  asked for, because the response does not say.

  ## Why the base URL is configuration and never a payload

  The OAuth client contract fixes the base URL to a configured value. It is not read
  from a token claim, a callback parameter, or a redirect: an attacker who can
  choose the host this request goes to gets the client secret. `config/config.exs`
  holds the official host and every environment inherits it.

  ## Bounded, unretried, capped

  Three limits, each for a distinct failure:

    * the connect and receive timeouts bound a Pumble that never answers;
    * `retry: false` bounds a Pumble that answers ambiguously. An
      authorization code is single-use, so a retried exchange after an unclear
      success burns the code and cannot tell success from failure. Recovery is
      a new user-initiated flow, never an automatic replay;
    * `max_response_bytes/0` bounds a response that never ends. The body is
      streamed and abandoned the moment it passes the cap, so an oversized
      response costs a bounded amount of memory rather than the node.

  Redirects are refused too. The token endpoint answering `302` is a
  misconfiguration or an attack, not a hop to follow with a secret in hand.

  ## Nothing here logs a code or a token

  No function in this module writes a code, an access token, or a bot token to a
  log, an exception, or an error's `:details`. Failures are described by shape —
  a status, a reason atom — never by content. `PumbleAutomation.Error` sanitizes
  `:details` as a backstop, but this module does not rely on it.
  """

  alias PumbleAutomation.Error

  @exchange_path "/oauth2/access"

  # The documented response is five short strings. 64 KiB is far above any
  # honest answer and far below a body that could hurt this node.
  @max_response_bytes 65_536

  @connect_timeout_ms 5_000
  @receive_timeout_ms 10_000

  @typedoc """
  A successful exchange, renamed into this application's vocabulary.

  `:bot_token` and `:bot_user_id` are `nil` when the grant carried no bot
  authorization. Whether that is acceptable is the caller's decision: an install
  needs a bot token, a sign-in does not.
  """
  @type tokens :: %{
          access_token: String.t(),
          bot_token: String.t() | nil,
          bot_user_id: String.t() | nil,
          pumble_user_id: String.t(),
          pumble_workspace_id: String.t()
        }

  @doc """
  Exchanges an authorization code for credentials.

  Returns `{:ok, tokens}` on a `200` carrying a well-formed body, and
  `{:error, t:PumbleAutomation.Error.t/0}` otherwise. The error never contains
  the code.

  A `5xx` answer is marked retryable, because repeating the *whole user flow*
  can succeed. That flag is advice to a human path, not permission for this
  module to resend the same code.
  """
  @spec exchange_code(String.t()) :: {:ok, tokens()} | {:error, Error.t()}
  def exchange_code(code) when is_binary(code) and byte_size(code) > 0 do
    case Req.request(request_options(code)) do
      {:ok, response} -> handle_response(response)
      {:error, exception} -> {:error, transport_error(exception)}
    end
  rescue
    exception ->
      {:error,
       Error.new(:dependency, :oauth_exchange_failed,
         message: "The Pumble authorization service could not be reached.",
         retryable?: true,
         cause: exception.__struct__
       )}
  end

  def exchange_code(_code) do
    {:error,
     Error.new(:validation, :oauth_code_missing,
       message: "The authorization response carried no code."
     )}
  end

  @doc "The largest response body this client will read, in bytes."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc """
  Returns the configured Pumble API base URL.

  Exposed so that a caller building a sibling request uses the same fixed host
  rather than deriving one of its own.
  """
  @spec base_url() :: String.t()
  def base_url do
    :pumble_automation
    |> Application.fetch_env!(:pumble)
    |> Keyword.fetch!(:api_base_url)
  end

  defp request_options(code) do
    pumble = Application.fetch_env!(:pumble_automation, :pumble)

    [
      method: :post,
      url: base_url() <> @exchange_path,
      form_multipart: [
        {"client-id", Keyword.fetch!(pumble, :client_id)},
        {"client-secret", Keyword.fetch!(pumble, :client_secret)},
        {"code", code}
      ],
      into: &collect/2,
      decode_body: false,
      retry: false,
      redirect: false,
      receive_timeout: @receive_timeout_ms
    ]
    |> Keyword.merge(transport_options())
    |> Keyword.merge(http_options())
  end

  # Configured overrides. Tests point this at a `Req.Test` stub, which is the
  # only supported way to reach this client without a network.
  defp http_options do
    Application.get_env(:pumble_automation, :pumble_http_options, [])
  end

  # TLS settings are built only for a real connection. Under a stub adapter they
  # are unused, and `:public_key.cacerts_get/0` raises on a host with no trust
  # store, which would turn an offline unit test into a failure about
  # certificates.
  defp transport_options do
    if Keyword.has_key?(http_options(), :plug) do
      []
    else
      [
        connect_options: [
          timeout: @connect_timeout_ms,
          transport_opts: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            depth: 3,
            versions: [:"tlsv1.2", :"tlsv1.3"],
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
      ]
    end
  end

  # Accumulates the body in the response's private map and abandons the request
  # as soon as it passes the cap. Halting here closes the connection, so an
  # endless body is never fully read.
  defp collect({:data, data}, {request, response}) do
    accumulated = (response.private[:body_acc] || "") <> data

    if byte_size(accumulated) > @max_response_bytes do
      {:halt, {request, Req.Response.put_private(response, :body_overflow, true)}}
    else
      {:cont, {request, Req.Response.put_private(response, :body_acc, accumulated)}}
    end
  end

  defp handle_response(%Req.Response{private: %{body_overflow: true}}) do
    {:error,
     Error.new(:dependency, :oauth_response_too_large,
       message: "The Pumble authorization service returned an unusable response.",
       details: %{limit_bytes: @max_response_bytes}
     )}
  end

  defp handle_response(%Req.Response{status: 200} = response) do
    response.private
    |> Map.get(:body_acc, "")
    |> Jason.decode()
    |> case do
      {:ok, body} when is_map(body) -> extract_tokens(body)
      _other -> {:error, malformed_error()}
    end
  end

  defp handle_response(%Req.Response{status: status}) do
    {:error,
     Error.new(:dependency, :oauth_exchange_rejected,
       message: "The Pumble authorization service rejected the exchange.",
       retryable?: status >= 500,
       details: %{http_status: status}
     )}
  end

  defp extract_tokens(body) do
    with {:ok, access_token} <- required_string(body, "accessToken"),
         {:ok, pumble_user_id} <- required_string(body, "userId"),
         {:ok, workspace_id} <- required_string(body, "workspaceId") do
      {:ok,
       %{
         access_token: access_token,
         bot_token: optional_string(body, "botToken"),
         bot_user_id: optional_string(body, "botId"),
         pumble_user_id: pumble_user_id,
         pumble_workspace_id: workspace_id
       }}
    end
  end

  defp required_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, malformed_error(key)}
    end
  end

  defp optional_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _other -> nil
    end
  end

  # The missing field is named because a field name is a schema fact, not a
  # secret. The value that failed the check is never included.
  defp malformed_error(field \\ nil) do
    Error.new(:dependency, :oauth_response_malformed,
      message: "The Pumble authorization service returned an unusable response.",
      details: if(field, do: %{missing_field: field}, else: %{})
    )
  end

  defp transport_error(%Req.TransportError{reason: reason}) when reason in [:timeout, :closed] do
    Error.new(:timeout, :oauth_exchange_timeout,
      message: "The Pumble authorization service did not answer in time.",
      retryable?: true,
      details: %{reason: reason}
    )
  end

  defp transport_error(exception) do
    Error.new(:dependency, :oauth_exchange_failed,
      message: "The Pumble authorization service could not be reached.",
      retryable?: true,
      cause: exception
    )
  end
end
