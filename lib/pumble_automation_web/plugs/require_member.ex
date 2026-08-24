defmodule PumbleAutomationWeb.Plugs.RequireMember do
  @moduledoc """
  Stops a request that carries no usable session.

  Answers `302` to the sign-in path and halts. The redirect is the same for a
  cookie that was never presented, one that expired, one that was revoked, and
  one whose installation is gone: `PumbleAutomationWeb.Plugs.FetchSession` has
  already collapsed all four into an absent member, and telling them apart would
  describe the state of somebody else's session to whoever asked.

  Runs after `FetchSession` and before `PumbleAutomationWeb.Plugs.LoadScope`,
  which is what lets `LoadScope` assume a member exists.
  """

  @behaviour Plug

  import Plug.Conn

  alias PumbleAutomationWeb.BrowserSession

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{assigns: %{current_member: member}} = conn, _opts)
      when not is_nil(member) do
    conn
  end

  def call(conn, _opts) do
    conn
    |> Phoenix.Controller.redirect(to: BrowserSession.sign_in_path())
    |> halt()
  end
end
