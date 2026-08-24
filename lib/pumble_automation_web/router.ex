defmodule PumbleAutomationWeb.Router do
  use PumbleAutomationWeb, :router

  # Scripts come only from this origin. Theme bootstrap lives in app.js so the
  # root layout has no inline script. `style-src` allows inline style attributes
  # that LiveView JS show/hide writes. WebSocket connects are same-origin plus
  # ws/wss for the LiveView socket. The string is literal so Sobelow Config.CSP
  # can see it; it must match `PumbleAutomationWeb.Plugs.SecurityHeaders.csp/0`.
  @secure_browser_headers %{
    "content-security-policy" =>
      "default-src 'self'; base-uri 'self'; font-src 'self'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; form-action 'self'; frame-ancestors 'self'; frame-src 'none'",
    "referrer-policy" => "strict-origin-when-cross-origin",
    "permissions-policy" =>
      "camera=(), microphone=(), geolocation=(), payment=(), usb=(), browsing-topics=()"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PumbleAutomationWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @secure_browser_headers
    # Resolves the session cookie on every HTML page, including public LiveViews.
    # It never halts; `RequireMember` decides what absence means.
    plug PumbleAutomationWeb.Plugs.FetchSession
  end

  # The browser stack for anything a member must be signed in to reach. It runs
  # after `:browser`, never instead of it: `protect_from_forgery` and the secure
  # headers are exactly what a protected route needs most.
  #
  # `FetchSession` already ran in `:browser`. `RequireMember` halts when it
  # resolved to nothing; `LoadScope` therefore always has a member to build a
  # scope from.
  pipeline :authenticated do
    plug PumbleAutomationWeb.Plugs.RequireMember
    plug PumbleAutomationWeb.Plugs.LoadScope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Pumble callbacks carry no session and no CSRF token; their only credential is
  # the signature over the raw body. The pipeline is therefore one plug, and the
  # raw bytes it verifies against were retained further up, by the body reader
  # `PumbleAutomationWeb.Endpoint` gives `Plug.Parsers`.
  pipeline :pumble_callbacks do
    plug PumbleAutomationWeb.Plugs.VerifyPumbleSignature
  end

  # Onboarding is public so a missing session can render a recovery screen.
  # A signed-in visitor still gets the authenticated shell from the mount hook.
  scope "/", PumbleAutomationWeb do
    pipe_through :browser

    live_session :onboarding, on_mount: [{PumbleAutomationWeb.Live.Hooks, :maybe_scope}] do
      live "/", OnboardingLive
    end
  end

  # Ending a session is a mutation, so it is a DELETE inside the browser
  # pipeline and carries that pipeline's CSRF token.
  scope "/", PumbleAutomationWeb do
    pipe_through [:browser, :authenticated]

    delete "/session/sign-out", SessionController, :delete
    delete "/session/all", SessionController, :delete_all

    live_session :workspace, on_mount: [{PumbleAutomationWeb.Live.Hooks, :require_scope}] do
      live "/workflows", WorkflowLive.Index, :index
      live "/workflows/new", WorkflowLive.Index, :new
      live "/workflows/:id/edit", WorkflowLive.Edit
      live "/workflows/:id", WorkflowLive.Show
      live "/executions", ExecutionLive.Index
      live "/executions/:id", ExecutionLive.Show
      live "/secrets", SecretLive.Index, :index
      live "/secrets/new", SecretLive.Index, :new
      live "/connections", ConnectionLive.Index, :index
      live "/connections/new", ConnectionLive.Index, :new
      live "/connections/:id/edit", ConnectionLive.Index, :edit
      live "/members", MemberLive.Index
      live "/audit", AuditLive.Index
      live "/settings", SettingsLive.Index
      live "/settings/operations", SettingsLive.Operations
      live "/settings/diagnostics", SettingsLive.Diagnostics
    end
  end

  # The OAuth round trip. Both routes are unauthenticated by necessity: the
  # first runs before anyone has a session, and the second is a top-level
  # navigation Pumble sends the browser on, carrying no cookie of ours it could
  # be asked for. The `state` parameter is the CSRF control here, which is why
  # `PumbleAutomation.Installations.OauthStates` consumes it atomically rather
  # than merely checking it.
  scope "/oauth", PumbleAutomationWeb do
    pipe_through :browser

    get "/install", OauthController, :install
    get "/callback", OauthController, :callback
  end

  # Operational endpoints. They are unauthenticated because load balancers and
  # orchestrators have no credential to present, and they pipe through :api
  # rather than :browser: a probe carries no session and no CSRF token, and its
  # response must never depend on one. See PumbleAutomationWeb.HealthController
  # for why the bodies carry no infrastructure detail.
  scope "/health", PumbleAutomationWeb do
    pipe_through :api

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  # Every Pumble callback enters here and nowhere else. The path prefix matches
  # `config :pumble_automation, :pumble_callbacks, :path_prefix`, which is what
  # decides where raw bytes are retained; the two must move together.
  #
  # `PumbleAutomationWeb.PumbleCallbackController.dispatch/2` classifies the
  # verified callback and sends the response its class requires.
  #
  # `log: false` is a security setting, not a noise setting. Phoenix's dispatch
  # log writes the parsed parameters at debug level, and a callback's parameters
  # are the callback body: message text, channel ids, and actor ids. Plan Section
  # 12.1 and `P4-T01` forbid writing that down, and `filter_parameters` cannot
  # help because the field names are Pumble's and open-ended. Dispatch is instead
  # recorded by the audit trail, which records what happened without the content.
  scope "/pumble", PumbleAutomationWeb do
    pipe_through :pumble_callbacks

    post "/callbacks", PumbleCallbackController, :dispatch, log: false
  end

  # Inbound webhooks are unauthenticated at the pipeline: the credential is a
  # bearer token verified inside the controller against a keyed digest. CSRF
  # does not apply. `log: false` keeps the body out of Phoenix dispatch logs.
  scope "/hooks", PumbleAutomationWeb do
    post "/:public_id", InboundWebhookController, :create, log: false
  end

  # Other scopes may use custom stacks.
  # scope "/api", PumbleAutomationWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:pumble_automation, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PumbleAutomationWeb.Telemetry
    end
  end
end
