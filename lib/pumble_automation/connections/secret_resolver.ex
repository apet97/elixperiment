defmodule PumbleAutomation.Connections.SecretResolver do
  @moduledoc """
  The one place a secret's plaintext is read. Not for general use.

  > #### Read this before calling anything here {: .warning}
  >
  > This module exists for the action executor, and for nothing else. It is
  > deliberately not part of `PumbleAutomation.Connections`, because the point
  > of that context is that every function in it is safe to call from a
  > controller or a LiveView, and this one is not.
  >
  > Call `resolve_for_action/2` at the moment an outbound request is being
  > built, use the value, and let it go out of scope. Do not return it to a
  > caller, do not put it in a struct that outlives the request, do not put it
  > in an `Ecto` row, an audit row, a log line, an error, or a telemetry
  > measurement.

  ## Why it takes an installation id and not a scope

  It runs inside an execution, where there is no member and no session — the
  authority was decided when the workflow version was activated. The tenant is
  still mandatory: the id is matched against the row, so a workflow version
  that names another tenant's secret resolves to `:not_found`, exactly as a
  random UUID does.

  ## A decryption failure is permanent

  `PumbleAutomation.Crypto.EncryptedBinary` raises
  `PumbleAutomation.Crypto.VaultError` when a stored envelope does not
  authenticate. That is not a transient dependency failure and it is never
  retried: the ciphertext was changed by something that is not this
  application, or the key that wrote it is gone. This module turns it into the
  typed, non-retryable `:internal` error the vault built, so the action stops
  permanently instead of running without the credential it needed.

  ## `last_used_at` is best effort

  The touch and the `secret.used` audit row happen after the value is read and
  outside any transaction the caller owns. A failed touch must not fail the
  action: the timestamp is an operator aid for finding unused credentials, not
  a control. Neither the touch nor the audit row carries the value.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Crypto.VaultError
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope

  @doc """
  Returns the plaintext of `secret_id` inside `installation_id`.

  Answers `Policy.not_found/0` for a secret that does not exist, for one that
  belongs to another tenant, and for a malformed identifier — the same error,
  field for field, so that a workflow definition cannot be used to test whether
  another workspace holds a given secret id.
  """
  @spec resolve_for_action(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def resolve_for_action(installation_id, secret_id) do
    with {:ok, tenant} <- cast_uuid(installation_id),
         {:ok, id} <- cast_uuid(secret_id),
         {:ok, {name, kind, value}} <- read(tenant, id) do
      touch(tenant, id, name, kind)
      {:ok, value}
    end
  end

  @doc """
  Returns the plaintext of the secret named `name` inside `installation_id`.

  Same answers as `resolve_for_action/2`: a missing name, another tenant, and
  a malformed identifier are all `Policy.not_found/0`. The name is looked up
  first so this module remains the only reader of `:value`.
  """
  @spec resolve_named_for_action(Ecto.UUID.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def resolve_named_for_action(installation_id, name) when is_binary(name) do
    with {:ok, tenant} <- cast_uuid(installation_id),
         true <- name_ok?(name),
         {:ok, id} <- lookup_name(tenant, name) do
      resolve_for_action(tenant, id)
    else
      false -> {:error, Policy.not_found()}
      {:error, %Error{}} = error -> error
    end
  end

  def resolve_named_for_action(_installation_id, _name) do
    {:error, Policy.not_found()}
  end

  # The only query in the application that names `:value`. Every other read of
  # this table gets a struct whose `:value` is `nil`, because the field is
  # declared `load_in_query: false`.
  defp read(installation_id, secret_id) do
    query =
      from secret in Secret,
        where: secret.id == ^secret_id and secret.installation_id == ^installation_id,
        select: {secret.name, secret.kind, secret.value}

    case Repo.one(query) do
      nil -> Scope.refuse_unknown(Secret, secret_id, installation_id, :secrets)
      {name, kind, value} -> {:ok, {name, kind, value}}
    end
  rescue
    exception in VaultError -> {:error, exception.error}
  end

  defp touch(installation_id, secret_id, name, kind) do
    query =
      from secret in Secret,
        where: secret.id == ^secret_id and secret.installation_id == ^installation_id

    {_touched, _rows} = Repo.update_all(query, set: [last_used_at: DateTime.utc_now()])

    # Best effort means best effort: a lost diagnostic event must not fail the
    # action that was already allowed to read the value.
    _appended =
      Writer.append_best_effort(%{
        installation_id: installation_id,
        actor_type: "job",
        action: "secret.used",
        resource_type: "secret",
        resource_id: secret_id,
        metadata: %{"resource_name" => name, "target_kind" => kind, "source" => "action_executor"}
      })

    :ok
  end

  defp name_ok?(name), do: Regex.match?(Secret.name_format(), name)

  defp lookup_name(installation_id, name) do
    query =
      from secret in Secret,
        where: secret.installation_id == ^installation_id and secret.name == ^name,
        select: secret.id

    case Repo.one(query) do
      nil -> {:error, Policy.not_found()}
      id -> {:ok, id}
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Policy.not_found()}
    end
  end
end
