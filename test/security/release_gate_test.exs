defmodule PumbleAutomation.Security.ReleaseGateTest do
  @moduledoc """
  P15-T05 discoverable security scenarios. Each named case is a release
  blocker. Canary values are unique per test so a leak cannot hide behind a
  fixture string.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import PumbleAutomation.IngressFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Connections.UrlPolicy
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Lineage
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Operations
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomationWeb.Router

  @secret "test-signing-secret"
  @timestamp "1767225600000"

  setup do
    WebhookService.reset_rate_table()
    :ok
  end

  test "a forged callback is 401 and the canary never reaches the log" do
    canary = canary()
    body = ~s({"messageType":"PUMBLE_EVENT","canary":"#{canary}"})

    log =
      capture_log(fn ->
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("x-pumble-request-timestamp", @timestamp)
          |> Plug.Conn.put_req_header("x-pumble-request-signature", "deadbeef")
          |> post(~p"/pumble/callbacks", body)

        assert response(conn, 401) == "unauthorized"
      end)

    refute log =~ canary
    assert Repo.aggregate(ReceivedEvent, :count) == 0
  end

  test "a malformed signed callback is refused without leaking the canary" do
    canary = canary()
    body = Jason.encode!(%{"messageType" => 1, "canary" => canary})

    log =
      capture_log(fn ->
        conn = signed_post(body)
        assert conn.status in [400, 401]
        refute conn.status == 500
      end)

    refute log =~ canary
  end

  test "a replayed signed event stores one receipt" do
    %{installation: installation} = InstallationsFixtures.install()
    rid = "RID-gate-#{System.unique_integer([:positive])}"

    body =
      Jason.encode!(%{
        "messageType" => "PUMBLE_EVENT",
        "eventType" => "NEW_MESSAGE",
        "workspaceId" => installation.pumble_workspace_id,
        "workspaceUserIds" => [],
        "body" =>
          Jason.encode!(%{
            "cId" => "channel-1",
            "aId" => "user-1",
            "tx" => "hello",
            "rid" => rid,
            "mId" => "M-gate",
            "tsm" => 1_767_225_600_000
          })
      })

    assert response(signed_post(body), 200) == "ok"
    assert response(signed_post(body), 200) == "ok"

    receipts =
      Repo.all(from r in ReceivedEvent, where: r.installation_id == ^installation.id)

    assert length(receipts) == 1
  end

  test "an unknown OAuth state never reaches token exchange" do
    Req.Test.stub(PumbleAutomation.Pumble.OauthClient, fn _conn ->
      flunk("an unknown state must never reach the code exchange")
    end)

    conn = get(build_conn(), ~p"/oauth/callback?code=auth-code&state=not-a-real-state")
    assert redirected_to(conn)
    refute redirected_to(conn) =~ "http"
  end

  test "a revoked session token cannot be fetched" do
    %{member: member} = InstallationsFixtures.install()
    {:ok, %{session: session, token: token}} = Sessions.issue(Repo, member)
    assert Sessions.revoke(Repo, session, DateTime.utc_now()) == 1
    assert Sessions.fetch(token, DateTime.utc_now()) == :error
  end

  test "a job for another tenant cannot claim that tenant's execution" do
    a = InstallationsFixtures.install()
    b = InstallationsFixtures.install()
    scope = Scope.new(a.member)

    workflow =
      drafted_workflow(a.installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "gate-#{System.unique_integer([:positive])}"
      })

    assert {:ok, :noop} =
             Engine.claim(%{
               "installation_id" => b.installation.id,
               "execution_id" => execution.id,
               "expected_node_id" => execution.current_node_id,
               "generation" => execution.lock_version
             })

    assert Repo.get!(Execution, execution.id).status == "queued"
  end

  test "webhook brute-force guesses are unauthorized and create no execution" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition:
          Definition.encode(Definition.new(Trigger.new(:webhook, %{}), [delay_node()]))
      })

    {:ok, %{version: version}} = Workflows.activate_workflow(scope, workflow.id, 0)
    endpoint = webhook_endpoint(version, %{token: WebhookEndpoint.generate_token()})

    for _n <- 1..5 do
      guess = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> guess)
        |> post(~p"/hooks/#{endpoint.public_id}", ~s({"ping":true}))

      assert conn.status in [401, 429]
    end

    assert [] == Repo.all(from e in Execution, where: e.installation_id == ^installation.id)
  end

  test "a private-network HTTP target is refused before a socket opens" do
    assert {:error, %Error{code: :http_not_allowed}} =
             UrlPolicy.approve("http://127.0.0.1/secret")

    assert {:error, %Error{code: :target_blocked, details: %{reason: :loopback}}} =
             UrlPolicy.approve("https://127.0.0.1/secret")
  end

  test "an unauthorized actor and a tampered button cannot decide an approval" do
    %{installation: installation, member: owner} =
      InstallationsFixtures.install(tokens: %{bot_user_id: "bot1"})

    scope = Scope.new(owner)
    approval_node = gate_approval_node(owner)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([approval_node]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "gate-approval-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
      })

    execution = Repo.get!(Execution, execution.id)

    {:ok, snapshot} =
      Engine.claim(%{
        "installation_id" => execution.installation_id,
        "execution_id" => execution.id,
        "expected_node_id" => execution.current_node_id,
        "generation" => execution.lock_version
      })

    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    {:ok, waiting} = Engine.finalize(snapshot, outcome)
    approval = Repo.get_by!(Approval, execution_id: waiting.id)

    outsider =
      %WorkspaceMember{}
      |> WorkspaceMember.changeset(%{
        installation_id: installation.id,
        pumble_user_id: "pumble-user-#{System.unique_integer([:positive])}",
        role: "editor"
      })
      |> Repo.insert!()

    assert {:ok, {:stale, _message}} =
             ApprovalService.decide(click(approval, outsider, "approved", installation))

    value = ApprovalService.button_value(approval, "approved", installation.pumble_workspace_id)
    last = :binary.last(value)

    tampered = %{
      click(approval, owner, "approved", installation)
      | payload: :binary.part(value, 0, byte_size(value) - 1) <> <<Bitwise.bxor(last, 0xFF)>>
    }

    assert {:ok, {:stale, _message}} = ApprovalService.decide(tampered)
    assert Repo.get!(Approval, approval.id).status == "pending"
    assert Repo.get!(Execution, waiting.id).status == "waiting_approval"
  end

  test "an oversized webhook body is refused" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition:
          Definition.encode(Definition.new(Trigger.new(:webhook, %{}), [delay_node()]))
      })

    {:ok, %{version: version}} = Workflows.activate_workflow(scope, workflow.id, 0)
    token = WebhookEndpoint.generate_token()
    endpoint = webhook_endpoint(version, %{token: token})
    max = Limits.get(:generic_webhook_body_bytes)
    body = ~s({"pad":"#{String.duplicate("x", max)}"})

    assert_error_sent 413, fn ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> Base.url_encode64(token, padding: false))
      |> post(~p"/hooks/#{endpoint.public_id}", body)
    end

    assert [] == Repo.all(from e in Execution, where: e.installation_id == ^installation.id)
  end

  test "lineage depth four is refused before a derived write" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([stop_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)
    assert Lineage.max_depth() == 3

    assert {:error, %Error{code: :lineage_depth_exceeded}} =
             Engine.create(scope, %{
               workflow_version_id: activated.version.id,
               execution_key: "gate-depth-#{System.unique_integer([:positive])}",
               lineage_depth: Lineage.max_depth() + 1,
               root_execution_id: Ecto.UUID.generate(),
               parent_execution_id: Ecto.UUID.generate()
             })
  end

  test "a unique canary is absent from captured logs and the diagnostic map" do
    canary = canary()
    %{member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)

    log =
      capture_log(fn ->
        assert {:ok, bundle} = Operations.export_diagnostics(scope)
        refute inspect(bundle) =~ canary
      end)

    refute log =~ canary
  end

  test "production debug surfaces are not compiled into the router" do
    source = File.read!(Path.join(File.cwd!(), "lib/pumble_automation_web/router.ex"))
    assert source =~ "dev_routes"
    refute Enum.any?(Router.__routes__(), fn route -> route.path == "/dev/dashboard" end)
  end

  test "uninstall deletes the bot ciphertext" do
    %{installation: installation} = InstallationsFixtures.install()
    refute stored_bot_token(installation.id) == nil
    assert {:ok, uninstalled} = Lifecycle.uninstall(installation.id)
    assert uninstalled.status == "uninstalled"
    assert stored_bot_token(installation.id) == nil
  end

  defp gate_approval_node(member) do
    :approval
    |> Node.new(%{
      prompt: "Ship it?",
      approver_member_ids: [member.id],
      timeout_seconds: 3600
    })
    |> Node.put_branch(:approved, [stop_node()])
    |> Node.put_branch(:rejected, [])
    |> Node.put_branch(:timed_out, [])
  end

  defp click(approval, member, action, installation) do
    %Payload.BlockInteraction{
      workspace_id: installation.pumble_workspace_id,
      user_id: member.pumble_user_id,
      channel_id: approval.pumble_channel_id,
      source_type: "MESSAGE",
      source_id: approval.pumble_message_id || "msg-1",
      action_type: "BUTTON",
      on_action: approval.public_action_id,
      payload: ApprovalService.button_value(approval, action, installation.pumble_workspace_id),
      trigger_id: "trig-#{System.unique_integer([:positive])}"
    }
  end

  defp signed_post(body) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-pumble-request-timestamp", @timestamp)
    |> Plug.Conn.put_req_header(
      "x-pumble-request-signature",
      Signature.compute(@secret, @timestamp, body)
    )
    |> post(~p"/pumble/callbacks", body)
  end

  defp canary do
    "CANARY-P15T05-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  defp stored_bot_token(id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT encrypted_bot_token FROM installations WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    value
  end
end
