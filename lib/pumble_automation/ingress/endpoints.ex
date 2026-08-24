defmodule PumbleAutomation.Ingress.Endpoints do
  @moduledoc """
  Tenant-scoped inbound webhook endpoint listing and credential rotation.

  The plaintext token is generated here, shown once to the caller, and stored
  only as a keyed digest. Rotation keeps the previous digest valid for
  `WebhookEndpoint.rotation_overlap_seconds/0`. When raw-body signatures are
  enabled, the owner-only rotation also replaces the encrypted HMAC secret and
  keeps its prior value for the same bounded overlap. Both new plaintext
  credentials are returned once and are never selected by listing queries.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Workflow

  @doc "Lists this tenant's webhook endpoints with workflow names, never a token."
  @spec list(Scope.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :read_workflows) do
      query =
        from endpoint in WebhookEndpoint,
          join: workflow in Workflow,
          on:
            workflow.id == endpoint.workflow_id and
              workflow.installation_id == endpoint.installation_id,
          where: endpoint.installation_id == ^scope.installation_id,
          order_by: [asc: workflow.name, asc: endpoint.public_id],
          select: %{
            id: endpoint.id,
            public_id: endpoint.public_id,
            enabled: endpoint.enabled or endpoint.signature_enabled,
            require_signature: endpoint.require_signature,
            last_used_at: endpoint.last_used_at,
            workflow_id: endpoint.workflow_id,
            workflow_name: workflow.name,
            overlap_expires_at: endpoint.previous_token_expires_at
          }

      {:ok, Enum.map(Repo.all(query), &with_url/1)}
    end
  end

  @doc """
  Rotates an endpoint's credentials and returns their new plaintext once.

  Owner-only (`:manage_credentials`). Cross-tenant ids are not found.
  """
  @spec rotate(Scope.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             endpoint: WebhookEndpoint.t(),
             token: String.t(),
             signing_secret: String.t() | nil
           }}
          | {:error, Error.t()}
  def rotate(%Scope{} = scope, id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with :ok <- Policy.authorize(scope, :manage_credentials),
         {:ok, uuid} <- cast_id(id) do
      Multi.new()
      |> Service.as_multi()
      |> Multi.run(:endpoint, fn repo, _changes -> lock_for_rotation(repo, scope, uuid) end)
      |> Multi.run(:rotation, fn repo, %{endpoint: endpoint} ->
        rotate_locked(repo, endpoint, now)
      end)
      |> Writer.append(:audit, fn %{rotation: %{endpoint: updated}} ->
        %{
          installation_id: scope.installation_id,
          actor_type: "user",
          actor_id: scope.member_id,
          action: "credential.rotated",
          resource_type: "webhook_endpoint",
          resource_id: updated.id,
          metadata: %{
            "result" => "ok",
            "actor_role" => scope.role,
            "resource_name" => updated.public_id,
            "target_kind" => "webhook"
          }
        }
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{rotation: %{endpoint: updated, token: token, signing_secret: signing_secret}}} ->
          {:ok,
           %{
             endpoint: scrub(updated),
             token: encode_token(token),
             signing_secret: signing_secret
           }}

        {:error, _step, %Error{} = error, _done} ->
          {:error, error}

        {:error, _step, %Ecto.Changeset{} = changeset, _done} ->
          {:error,
           Error.new(:validation, :webhook_rotate_rejected,
             message: "The webhook credentials could not be rotated.",
             details: %{fields: Keyword.keys(changeset.errors)}
           )}

        {:error, _step, reason, _done} ->
          {:error,
           Error.new(:internal, :webhook_rotate_failed,
             message: "The webhook credentials could not be rotated.",
             cause: reason
           )}
      end
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Policy.not_found()}
    end
  end

  defp lock_for_rotation(repo, %Scope{} = scope, uuid) do
    query =
      from endpoint in WebhookEndpoint.by_id_for_rotation(scope.installation_id, uuid),
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> Scope.refuse_unknown(WebhookEndpoint, uuid, scope.installation_id, :webhooks)
      endpoint -> {:ok, endpoint}
    end
  end

  defp rotate_locked(repo, %WebhookEndpoint{} = endpoint, now) do
    token = WebhookEndpoint.generate_token()
    signing_secret = if endpoint.require_signature, do: WebhookEndpoint.generate_signing_secret()
    expires_at = DateTime.add(now, WebhookEndpoint.rotation_overlap_seconds(), :second)

    attrs = %{
      token_digest: WebhookEndpoint.digest(token),
      previous_token_digest: endpoint.token_digest,
      previous_token_expires_at: expires_at
    }

    attrs =
      if endpoint.require_signature do
        primary_version = WebhookEndpoint.signing_secret_key_version()

        Map.merge(attrs, %{
          signing_secret: signing_secret,
          signing_secret_key_version: primary_version,
          previous_signing_secret: endpoint.signing_secret,
          previous_signing_secret_key_version: primary_version,
          previous_signing_secret_expires_at: expires_at
        })
      else
        attrs
      end

    endpoint
    |> WebhookEndpoint.changeset(attrs)
    |> repo.update()
    |> case do
      {:ok, updated} ->
        {:ok, %{endpoint: updated, token: token, signing_secret: signing_secret}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp with_url(row) do
    Map.put(row, :url, public_url(row.public_id))
  end

  @doc "The externally configured URL for one opaque webhook public id."
  @spec public_url(String.t()) :: String.t()
  def public_url(public_id) when is_binary(public_id) do
    Application.fetch_env!(:pumble_automation, :public_url) <>
      WebhookService.path_prefix() <> "/" <> public_id
  end

  defp encode_token(token), do: Base.url_encode64(token, padding: false)

  defp scrub(%WebhookEndpoint{} = endpoint) do
    %{
      endpoint
      | token_digest: nil,
        previous_token_digest: nil,
        signing_secret: nil,
        previous_signing_secret: nil
    }
  end
end
