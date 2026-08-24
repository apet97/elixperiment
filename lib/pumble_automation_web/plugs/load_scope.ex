defmodule PumbleAutomationWeb.Plugs.LoadScope do
  @moduledoc """
  Builds the request's `PumbleAutomation.Scope` once, from the rows already read.

  Assigns `:scope`. Everything downstream authorizes against that struct and
  never against a workspace id, member id, or role that arrived in a parameter:
  the assign is derived from the session `PumbleAutomationWeb.Plugs.FetchSession`
  verified, so a request cannot name a tenant it did not authenticate into.

  A request with no member gets no scope rather than an empty one, so a missing
  `RequireMember` in a pipeline fails as a `KeyError` on the first authorization
  instead of quietly authorizing nobody.
  """

  @behaviour Plug

  import Plug.Conn

  alias PumbleAutomation.Scope

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{assigns: %{current_member: member}} = conn, _opts)
      when not is_nil(member) do
    assign(conn, :scope, Scope.new(member))
  end

  def call(conn, _opts), do: conn
end
