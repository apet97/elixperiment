defmodule PumbleAutomation.ConnectionsFixtures do
  @moduledoc """
  Secrets and HTTP connections for tests that need one.

  Every fixture goes through `PumbleAutomation.Connections`, so a fixture
  cannot hold a row the context would refuse, and a change to what a write
  does cannot leave these tests passing against a shape that no longer exists.

  The fixtures take an owner scope because writing either kind is owner work.
  """

  alias PumbleAutomation.Connections
  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Scope

  @doc "Creates one secret and returns it. Its `:value` is `nil`, as everywhere."
  @spec secret(Scope.t(), map()) :: Secret.t()
  def secret(%Scope{} = scope, attrs \\ %{}) do
    {:ok, secret} =
      Connections.create_secret(
        scope,
        Map.merge(
          %{
            name: "API_TOKEN_#{System.unique_integer([:positive])}",
            value: "s3cr3t-#{System.unique_integer([:positive])}",
            kind: "api_key"
          },
          attrs
        )
      )

    secret
  end

  @doc "Creates one HTTP connection and returns it."
  @spec connection(Scope.t(), map()) :: Connection.t()
  def connection(%Scope{} = scope, attrs \\ %{}) do
    {:ok, connection} =
      Connections.create_connection(
        scope,
        Map.merge(
          %{
            name: "Tickets #{System.unique_integer([:positive])}",
            base_origin: "https://api.example.test",
            base_path_prefix: "/v1"
          },
          attrs
        )
      )

    connection
  end
end
