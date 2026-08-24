defmodule PumbleAutomationWeb.InboundWebhookFailureTest do
  @moduledoc """
  A rejected Oban insert must not 202 a webhook that has no durable job.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.IngressFixtures
  import PumbleAutomation.WorkflowsFixtures
  import Phoenix.ConnTest
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger

  @endpoint PumbleAutomationWeb.Endpoint

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "a rejected job insert answers 503 and leaves the receipt retryable" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition:
          Definition.encode(Definition.new(Trigger.new(:webhook, %{}), [delay_node()]))
      })

    {:ok, %{version: version}} = Workflows.activate_workflow(scope, workflow.id, 0)
    token = WebhookEndpoint.generate_token()
    endpoint = webhook_endpoint(version, %{token: token})

    {_name, drop} = reject_job_insert!(installation.id)
    on_exit(drop)

    conn = post_webhook(endpoint.public_id, token, %{"fail" => true})
    assert json_response(conn, 503)["error"] == "unavailable"

    assert [%ReceivedEvent{processing_state: "received"}] =
             Repo.all(
               from event in ReceivedEvent, where: event.installation_id == ^installation.id
             )

    refute Repo.exists?(from e in Execution, where: e.installation_id == ^installation.id)

    drop.()

    retry = post_webhook(endpoint.public_id, token, %{"fail" => true})
    assert %{"id" => _} = json_response(retry, 202)

    assert [%ReceivedEvent{processing_state: "processed"}] =
             Repo.all(
               from event in ReceivedEvent, where: event.installation_id == ^installation.id
             )

    assert Repo.aggregate(
             from(e in Execution, where: e.installation_id == ^installation.id),
             :count
           ) == 1
  end

  defp post_webhook(public_id, token, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> Base.url_encode64(token, padding: false))
    |> put_req_header("idempotency-key", "resume-once")
    |> post("/hooks/#{public_id}", Jason.encode!(body))
  end

  defp reject_job_insert!(installation_id) do
    suffix = System.unique_integer([:positive])
    name = "reject_oban_jobs_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'job insert rejected';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{name}
    BEFORE INSERT ON oban_jobs
    FOR EACH ROW
    WHEN ((NEW.args ->> 'installation_id') = '#{installation_id}')
    EXECUTE FUNCTION #{name}()
    """)

    drop = fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON oban_jobs")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end

    {name, drop}
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from job in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
