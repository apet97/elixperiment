defmodule PumbleAutomation.Performance.IngressCapacityTest do
  @moduledoc """
  Bounded local capacity proof for the two signed ingress boundaries.

  Timings are printed as observations only. Release gates in this module are
  semantic: exact durable counts, tenant scope, and the indexed trigger lookup
  shape. Nothing here calls Pumble or any other external service.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.DataCase, only: [explain_index_plan: 2, index_backed?: 1]
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow

  @callback_count 6
  @webhook_count 6
  @binding_count 25
  @pumble_secret "test-signing-secret"
  @pumble_timestamp "1767225600000"

  setup do
    WebhookService.reset_rate_table()
    :ok
  end

  test "signed Pumble callbacks match through the index and create one durable run each" do
    %{installation: installation, member: member} =
      InstallationsFixtures.install(workspace: "W_FAKE001")

    scope = Scope.new(member)
    _target = activate_event!(scope, installation.id, "C_FAKE001")

    for index <- 1..(@binding_count - 1) do
      put_noise_binding!(installation.id, "C_CAPACITY_NOISE_#{index}")
    end

    candidate_query =
      TriggerBinding.candidates(installation.id,
        kind: "pumble_event",
        type: "NEW_MESSAGE",
        channel_id: "C_FAKE001"
      )

    plan = explain_index_plan(candidate_query, analyze: true)
    assert index_backed?(plan)
    refute plan =~ "Seq Scan on trigger_bindings"
    refute plan =~ "Seq Scan on workflows"
    emit_plan("callback_trigger_match", plan, true)

    {elapsed_us, responses} =
      :timer.tc(fn ->
        for sequence <- 1..@callback_count do
          sequence
          |> callback_body()
          |> post_callback()
        end
      end)

    assert Enum.all?(responses, &(&1.status == 200))
    assert Enum.all?(responses, &(response(&1, 200) == "ok"))

    assert tenant_count(ReceivedEvent, installation.id) == @callback_count
    assert tenant_count(Execution, installation.id) == @callback_count
    admitted = min(@callback_count, Concurrency.max_running())
    assert advance_job_count(installation.id) == admitted

    emit_metric("signed_callback_acceptance", @callback_count, elapsed_us,
      active_bindings: @binding_count,
      executions: @callback_count,
      admitted_jobs: admitted
    )
  end

  test "signed generic webhooks accept exact raw bytes and create one durable run each" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)

    definition =
      Definition.new(
        Trigger.new(:webhook, %{require_signature: true}),
        [delay_node()]
      )

    workflow =
      drafted_workflow(installation.id, %{
        name: "Signed capacity webhook",
        draft_definition: Definition.encode(definition)
      })

    assert {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)
    credentials = activated.webhook_credentials
    assert is_binary(credentials.token)
    assert is_binary(credentials.signing_secret)

    {elapsed_us, responses} =
      :timer.tc(fn ->
        for sequence <- 1..@webhook_count do
          raw_body = Jason.encode!(%{"sequence" => sequence, "kind" => "capacity"})
          signature = WebhookEndpoint.sign_body(credentials.signing_secret, raw_body)

          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> credentials.token)
          |> put_req_header(WebhookService.signature_header(), signature)
          |> put_req_header("idempotency-key", "capacity-webhook-#{sequence}")
          |> post(~p"/hooks/#{credentials.public_id}", raw_body)
        end
      end)

    receipt_ids =
      Enum.map(responses, fn conn ->
        assert %{"id" => receipt_id} = json_response(conn, 202)
        receipt_id
      end)

    assert length(Enum.uniq(receipt_ids)) == @webhook_count
    assert tenant_count(ReceivedEvent, installation.id) == @webhook_count
    assert tenant_count(Execution, installation.id) == @webhook_count
    admitted = min(@webhook_count, Concurrency.max_running())
    assert advance_job_count(installation.id) == admitted

    emit_metric("signed_webhook_acceptance", @webhook_count, elapsed_us,
      exact_raw_hmac: true,
      executions: @webhook_count,
      admitted_jobs: admitted
    )
  end

  defp activate_event!(scope, installation_id, channel_id) do
    definition =
      Definition.new(
        Trigger.new(:pumble_event, %{
          event: :new_message,
          channel_ids: [channel_id],
          ignore_bot_messages: true
        }),
        [delay_node()]
      )

    workflow =
      drafted_workflow(installation_id, %{
        name: "Capacity event target",
        draft_definition: Definition.encode(definition)
      })

    assert {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)
    activated
  end

  # Noise rows retain the same valid shape as activation projections, but do
  # not need compiled programs because the indexed channel predicate excludes
  # them before execution creation. The target itself uses full activation.
  defp put_noise_binding!(installation_id, channel_id) do
    definition =
      Definition.new(
        Trigger.new(:pumble_event, %{
          event: :new_message,
          channel_ids: [channel_id],
          ignore_bot_messages: true
        }),
        [delay_node()]
      )

    workflow =
      drafted_workflow(installation_id, %{
        name: "Capacity noise #{channel_id}",
        draft_definition: Definition.encode(definition)
      })

    version = version(workflow)

    workflow
    |> Workflow.changeset(%{status: "active", active_version_id: version.id})
    |> Repo.update!()

    trigger_binding(version, %{
      channel_id: channel_id,
      filter_config: %{"keyword" => nil, "ignore_bot_messages" => true}
    })
  end

  defp callback_body(sequence) do
    fixture = PumbleFake.fixture("callbacks/event_new_message.json")

    inner =
      fixture["body"]
      |> Jason.decode!()
      |> Map.put("mId", "M_CAPACITY_#{sequence}")
      |> Map.put("rid", "RID_CAPACITY_#{sequence}")

    fixture
    |> Map.put("body", Jason.encode!(inner))
    |> Jason.encode!()
  end

  defp post_callback(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-pumble-request-timestamp", @pumble_timestamp)
    |> put_req_header(
      "x-pumble-request-signature",
      Signature.compute(@pumble_secret, @pumble_timestamp, body)
    )
    |> post(~p"/pumble/callbacks", body)
  end

  defp tenant_count(schema, installation_id) do
    Repo.aggregate(from(row in schema, where: row.installation_id == ^installation_id), :count)
  end

  defp advance_job_count(installation_id) do
    worker = Oban.Worker.to_string(AdvanceExecutionWorker)

    Repo.aggregate(
      from(job in Oban.Job,
        where: job.worker == ^worker,
        where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
      ),
      :count
    )
  end

  defp emit_metric(name, count, elapsed_us, metadata) do
    details = Enum.map_join(metadata, " ", fn {key, value} -> "#{key}=#{value}" end)

    IO.puts(
      "CAPACITY_METRIC name=#{name} count=#{count} total_us=#{elapsed_us} " <>
        "avg_us=#{div(elapsed_us, count)} #{details} gate=semantic"
    )
  end

  defp emit_plan(name, plan, index_backed) do
    digest = :sha256 |> :crypto.hash(plan) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    IO.puts(
      "CAPACITY_PLAN name=#{name} index_backed=#{index_backed} " <>
        "seq_trigger_bindings=#{plan =~ "Seq Scan on trigger_bindings"} " <>
        "seq_workflows=#{plan =~ "Seq Scan on workflows"} digest=#{digest}"
    )
  end
end
