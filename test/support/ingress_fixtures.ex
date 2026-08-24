defmodule PumbleAutomation.IngressFixtures do
  @moduledoc """
  Received-event and webhook-endpoint rows for tests that need one.

  Every row goes through its schema changeset, so a test cannot hold a shape
  the schema would refuse.
  """

  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.WorkflowVersion
  alias PumbleAutomation.WorkflowsFixtures

  @doc "Inserts a received event for `installation_id`."
  @spec received_event(String.t(), map()) :: ReceivedEvent.t()
  def received_event(installation_id, attrs \\ %{}) do
    %ReceivedEvent{}
    |> ReceivedEvent.changeset(
      Map.merge(
        %{
          installation_id: installation_id,
          provider: "pumble",
          class: "event",
          type: "NEW_MESSAGE",
          dedup_key: "dedup-#{System.unique_integer([:positive])}",
          raw_body_hash: ReceivedEvent.hash_body("body-#{System.unique_integer([:positive])}"),
          data: %{"channel_id" => "channel-1"},
          occurred_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc "A drafted workflow version an endpoint can bind to."
  @spec version(String.t(), map()) :: WorkflowVersion.t()
  def version(installation_id, attrs \\ %{}) do
    installation_id
    |> WorkflowsFixtures.drafted_workflow()
    |> WorkflowsFixtures.version(attrs)
  end

  @doc """
  Inserts a webhook endpoint bound to `version`.

  Pass `:token` to choose the plaintext; only its digest is stored.
  """
  @spec webhook_endpoint(WorkflowVersion.t(), map()) :: WebhookEndpoint.t()
  def webhook_endpoint(%WorkflowVersion{} = version, attrs \\ %{}) do
    {token, attrs} = Map.pop(attrs, :token, WebhookEndpoint.generate_token())

    %WebhookEndpoint{}
    |> WebhookEndpoint.changeset(
      Map.merge(
        %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          public_id: WebhookEndpoint.generate_public_id(),
          token_digest: WebhookEndpoint.digest(token)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
