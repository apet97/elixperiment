defmodule PumbleAutomation.Installations.Credentials do
  @moduledoc """
  The one way to obtain a live Pumble credential for an installation.

  Nothing outside this module reads `:encrypted_bot_token` or
  `:encrypted_access_token` to make a call with it. A caller names an
  installation and a credential kind; this module reads the row, refuses the
  credential when the installation or the authorization no longer permits its
  use, and returns the plaintext token together with the scope snapshot that was
  granted with it.

  ## Why resolution happens per request

  `PumbleAutomation.Crypto.EncryptedBinary` decrypts when the row loads, so the
  plaintext exists exactly as long as the struct that carries it. Resolving at
  request time — rather than when a client is constructed — keeps that window to
  one request, and it means a revocation that lands between two calls is seen by
  the second one. A long-lived client holding a decrypted token would keep
  working after the workspace revoked it.

  ## Refusals happen before the network

  A missing, revoked, or uninstalled credential is a local, permanent failure.
  Sending the request anyway would leak the fact that this application still
  holds a token, cost a round trip, and return a `401` that says less than the
  local check already knows.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Repo

  # Statuses in which the stored bot credential is still meant to be used. A
  # `degraded` workspace has a working token and a reduced capability, which is
  # exactly the state where a call may still be attempted.
  @usable_statuses ~w(active degraded)

  @typedoc """
  Which credential to use.

  `:bot` is the workspace bot token. `{:user, pumble_user_id}` is one member's
  access token, used only where the action must be attributed to that person.
  """
  @type kind :: :bot | {:user, String.t()}

  @typedoc """
  A resolved credential.

  `:actor_id` is the Pumble workspace-user id the token acts as: the bot user id
  for `:bot`, the member's id for `{:user, _}`. `:scopes` is the snapshot this
  application recorded at authorization, which is empty when no scope set was
  configured — an empty list means "unknown", never "none granted".
  """
  @type t :: %{
          kind: :bot | :user,
          token: String.t(),
          installation_id: Ecto.UUID.t(),
          pumble_workspace_id: String.t(),
          actor_id: String.t() | nil,
          scopes: [String.t()]
        }

  @doc """
  Resolves the credential of `kind` for `installation_id`.

  Returns `{:error, t:PumbleAutomation.Error.t/0}` when the installation is
  unknown, when its lifecycle forbids use, or when the ciphertext is absent
  because a revocation cleared it. The error never carries a token.
  """
  @spec resolve(Ecto.UUID.t(), kind()) :: {:ok, t()} | {:error, Error.t()}
  def resolve(installation_id, kind)

  def resolve(installation_id, :bot) when is_binary(installation_id) do
    with {:ok, installation} <- fetch_installation(installation_id) do
      bot_credential(installation)
    end
  end

  def resolve(installation_id, {:user, pumble_user_id})
      when is_binary(installation_id) and is_binary(pumble_user_id) do
    with {:ok, installation} <- fetch_installation(installation_id) do
      user_credential(installation, pumble_user_id)
    end
  end

  defp fetch_installation(installation_id) do
    case safe_get(installation_id) do
      nil ->
        {:error,
         Error.new(:not_found, :installation_not_found,
           message: "This workspace is not installed."
         )}

      %Installation{status: status} = installation when status in @usable_statuses ->
        {:ok, installation}

      %Installation{} ->
        {:error,
         Error.new(:permission, :installation_revoked,
           message: "This workspace's authorization is no longer valid."
         )}
    end
  end

  # A malformed id is a caller defect, not a database question, and
  # `Repo.get/2` raises on one. Treating it as "not found" keeps the boundary
  # returning errors rather than raising into a job.
  defp safe_get(installation_id) do
    case Ecto.UUID.cast(installation_id) do
      {:ok, id} -> Repo.get(Installation, id)
      :error -> nil
    end
  end

  defp bot_credential(%Installation{encrypted_bot_token: token} = installation)
       when is_binary(token) and byte_size(token) > 0 do
    {:ok,
     %{
       kind: :bot,
       token: token,
       installation_id: installation.id,
       pumble_workspace_id: installation.pumble_workspace_id,
       actor_id: installation.bot_user_id,
       scopes: installation.bot_scopes
     }}
  end

  defp bot_credential(%Installation{}) do
    {:error,
     Error.new(:permission, :bot_credential_missing,
       message: "This workspace has no usable bot credential."
     )}
  end

  defp user_credential(%Installation{} = installation, pumble_user_id) do
    query =
      from authorization in UserAuthorization,
        where:
          authorization.installation_id == ^installation.id and
            authorization.pumble_user_id == ^pumble_user_id

    case Repo.one(query) do
      %UserAuthorization{status: "active", encrypted_access_token: token} = authorization
      when is_binary(token) and byte_size(token) > 0 ->
        {:ok,
         %{
           kind: :user,
           token: token,
           installation_id: installation.id,
           pumble_workspace_id: installation.pumble_workspace_id,
           actor_id: authorization.pumble_user_id,
           scopes: authorization.scopes
         }}

      _other ->
        {:error,
         Error.new(:permission, :user_credential_missing,
           message: "This member has not authorized the application."
         )}
    end
  end
end
