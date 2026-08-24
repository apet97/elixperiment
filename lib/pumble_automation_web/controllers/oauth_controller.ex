defmodule PumbleAutomationWeb.OauthController do
  @moduledoc """
  The two browser endpoints of the OAuth round trip.

  `install/2` mints a state and sends the browser to Pumble's consent screen.
  `callback/2` takes the browser back, consumes the state, exchanges the code,
  and completes the flow.

  The controller is deliberately thin. It reads request parameters, calls the
  installations context, and turns one of two answers into a redirect. Every
  decision that matters — whether a state is usable, what an intent may do, who
  becomes owner, what is written — belongs to
  `PumbleAutomation.Installations.Service` and
  `PumbleAutomation.Installations.OauthStates`, and none of it is reachable from
  here without going through them.

  ## Where a browser can be sent

  Two redirects leave this module. The outbound one goes to the configured
  consent host and nowhere else, because the host is configuration rather than a
  parameter. The inbound one goes to a path from
  `PumbleAutomation.Installations.ReturnPaths`, resolved from a key stored on the
  state row. A caller cannot supply a URL to either, and `redirect(to:)` refuses
  a non-local path as a second, independent layer.

  ## What is never written down

  The authorization code appears in the query string of exactly one request and
  is passed to the exchange client and nowhere else. It is not logged, not put in
  a flash, not echoed into a redirect, and not stored. `config/config.exs` filters
  `code` and `state` out of Phoenix's parameter logging, so the framework does not
  write them either.

  A failure produces a generic message and a correlation id. The audit event
  carries the correlation id and a reason atom, which is enough to find the
  request in the logs and never enough to replay it.
  """

  use PumbleAutomationWeb, :controller

  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.ReturnPaths
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Logging
  alias PumbleAutomation.Pumble.OauthClient
  alias PumbleAutomationWeb.BrowserSession

  @doc """
  Starts an authorization by minting a state and redirecting to consent.

  Accepts an optional `intent` (defaulting to `install`) and an optional `return`
  key. Both are validated against closed sets before anything is stored, so an
  unknown value fails here rather than becoming a row.
  """
  def install(conn, params) do
    correlation_id = Ecto.UUID.generate()

    with {:ok, intent} <- fetch_intent(params),
         {:ok, token, _state} <- create_state(params, intent) do
      log_oauth(conn, correlation_id, "oauth.install", "ok", nil)
      redirect(conn, external: consent_url(token, intent, params))
    else
      {:error, %Error{} = error} -> fail(conn, error, correlation_id, "oauth.install_failed")
    end
  end

  @doc """
  Completes an authorization.

  The state is consumed before the code is exchanged, and in its own statement.
  That order is the one that fails safely: a duplicate callback is refused at the
  first step, before a code is ever sent, and a failure after the exchange leaves
  the state consumed rather than replayable.
  """
  def callback(conn, %{"state" => state_token, "code" => code})
      when is_binary(state_token) and is_binary(code) do
    correlation_id = Ecto.UUID.generate()

    with {:ok, state} <- OauthStates.consume(state_token),
         {:ok, return_path} <- ReturnPaths.fetch(state.return_path_key),
         {:ok, tokens} <- OauthClient.exchange_code(code),
         {:ok, result} <- complete(conn, state, tokens, correlation_id) do
      log_oauth(conn, correlation_id, "oauth.callback", "ok", result.installation.id)

      conn
      |> put_session_token(result)
      |> redirect(to: return_path)
    else
      {:error, %Error{} = error} -> fail(conn, error, correlation_id, "oauth.callback_failed")
    end
  end

  def callback(conn, _params) do
    error =
      Error.new(:validation, :oauth_callback_incomplete,
        message: "The authorization did not complete. Start again."
      )

    fail(conn, error, Ecto.UUID.generate(), "oauth.callback_failed")
  end

  defp complete(conn, state, tokens, correlation_id) do
    Service.complete_oauth(state, tokens,
      correlation_id: correlation_id,
      user_agent_hash: user_agent_hash(conn)
    )
  end

  # `:request_metadata` records the shape of the request, never who made it. A
  # source label is enough to tell a browser-initiated flow from one a future
  # administrative path starts, and it identifies nobody.
  defp create_state(params, intent) do
    OauthStates.create(intent,
      return_path_key: params["return"],
      request_metadata: %{"source" => "browser"}
    )
  end

  defp fetch_intent(params) do
    intent = Map.get(params, "intent", "install")

    if intent in OauthState.intents() do
      {:ok, intent}
    else
      {:error,
       Error.new(:validation, :unknown_oauth_intent,
         message: "The requested authorization is not available."
       )}
    end
  end

  # `A-17`: the consent screen takes `clientId`, `redirectUrl`, `scopes`, and an
  # optional `state`, `defaultWorkspaceId`, and `isReinstall`. `scopes` joins the
  # user scopes with the bot scopes, each bot scope prefixed `bot:` (`A-18`).
  defp consent_url(token, intent, params) do
    pumble = Application.fetch_env!(:pumble_automation, :pumble)

    query =
      [
        clientId: Keyword.fetch!(pumble, :client_id),
        redirectUrl: redirect_uri(),
        scopes: scope_parameter(pumble),
        state: token
      ]
      |> maybe_put(:defaultWorkspaceId, params["workspace"])
      |> maybe_put(:isReinstall, if(intent == "reinstall", do: "true"))

    Keyword.fetch!(pumble, :consent_url) <> "?" <> URI.encode_query(query)
  end

  defp scope_parameter(pumble) do
    user_scopes = Keyword.get(pumble, :user_scopes, [])
    bot_scopes = Enum.map(Keyword.get(pumble, :bot_scopes, []), &("bot:" <> &1))

    Enum.join(user_scopes ++ bot_scopes, ",")
  end

  # The exact redirect URI, built from the configured public URL so that it
  # matches what the Pumble application registration holds.
  defp redirect_uri do
    Application.fetch_env!(:pumble_automation, :public_url) <> ~p"/oauth/callback"
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Keyword.put(query, key, value)

  # Plan Section 11.2. Every cookie attribute, and the renewal of the Phoenix
  # session that goes with a sign-in, lives in `PumbleAutomationWeb.BrowserSession`.
  defp put_session_token(conn, %{session_token: token}) when is_binary(token) do
    BrowserSession.put(conn, token)
  end

  defp put_session_token(conn, _result), do: conn

  defp user_agent_hash(conn) do
    case get_req_header(conn, "user-agent") do
      [user_agent | _rest] -> :crypto.hash(:sha256, user_agent)
      [] -> nil
    end
  end

  # Best effort, and correctly so: the flow has already failed, and a failure to
  # record the failure must not replace one generic error page with another. The
  # `oauth` namespace is the one that may carry no installation id, which is
  # exactly the pre-install case this handles.
  defp fail(conn, %Error{} = error, correlation_id, action) do
    _ =
      Writer.append_best_effort(%{
        actor_type: "system",
        action: action,
        correlation_id: correlation_id,
        metadata: %{
          result: "error",
          reason: Atom.to_string(error.code),
          source: "oauth",
          retryable: Error.retryable?(error)
        }
      })

    log_oauth(conn, correlation_id, oauth_log_name(action), "error", nil, error)

    conn
    |> put_flash(:error, error.message)
    |> redirect(to: ReturnPaths.failure_path())
  end

  defp log_oauth(conn, correlation_id, operation, status, installation_id, error \\ nil) do
    fields = %{
      operation: operation,
      event_type: "oauth",
      status: status,
      request_id: conn.assigns[:request_id],
      correlation_id: correlation_id,
      installation_id: installation_id
    }

    fields =
      if error do
        Map.merge(fields, %{error_code: error.code, error_class: error.class})
      else
        fields
      end

    level = if status == "error", do: :warning, else: :info
    Logging.event(level, operation, fields)
  end

  defp oauth_log_name("oauth.install_failed"), do: "oauth.install"
  defp oauth_log_name(_action), do: "oauth.callback"

  @doc "The name of the cookie that carries the browser session token."
  @spec session_cookie() :: String.t()
  defdelegate session_cookie, to: BrowserSession, as: :cookie
end
