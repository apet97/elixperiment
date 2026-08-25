defmodule PumbleAutomation.Connections.ResolvedConnection do
  @moduledoc """
  A validated connection, ready to build a request from, carrying no secret.

  This is what `PumbleAutomation.Connections.Resolver` returns and what the
  Safe HTTP transport receives. `:secret_headers` holds handles — a header name and
  a secret id — and never a value. The transport resolves each handle through
  `PumbleAutomation.Connections.SecretResolver` at the moment it writes the
  header, so a decrypted credential never sits inside a struct that is passed
  between processes, logged, or held across a retry.

  The struct is inert. It has no functions that reach the network and no
  behaviour of its own: everything about it was decided when the connection
  row was written and checked again when it was resolved.
  """

  @enforce_keys [:id, :installation_id, :name, :base_origin, :policy_version]
  defstruct [
    :id,
    :installation_id,
    :name,
    :base_origin,
    :base_path_prefix,
    :policy_version,
    headers: %{},
    secret_headers: []
  ]

  @typedoc "One header this connection fills from a secret, named by id."
  @type secret_handle :: %{header: String.t(), secret_id: Ecto.UUID.t()}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          installation_id: Ecto.UUID.t(),
          name: String.t(),
          base_origin: String.t(),
          base_path_prefix: String.t() | nil,
          policy_version: pos_integer(),
          headers: %{String.t() => String.t()},
          secret_headers: [secret_handle()]
        }

  @doc "The secret ids this resolved connection will ask for at execution time."
  @spec secret_ids(t()) :: [Ecto.UUID.t()]
  def secret_ids(%__MODULE__{secret_headers: handles}) do
    handles |> Enum.map(& &1.secret_id) |> Enum.uniq()
  end
end
