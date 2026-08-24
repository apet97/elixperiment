defmodule PumbleAutomationWeb.ExecutionLiveTest do
  @moduledoc """
  Execution history, sanitized timelines, role controls, and operator actions.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PumbleAutomation.ExecutionsFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.History
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomationWeb.BrowserSession

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/executions")
      assert to == BrowserSession.sign_in_path()
    end

    test "an editor sees the list and cancel, not uncertainty resolution", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      execution = queued_execution(Scope.new(member), installation.id)

      {:ok, index, _html} = live(log_in(conn, token), ~p"/executions")
      assert has_element?(index, "#execution-index")
      assert has_element?(index, "#nav-executions")
      assert has_element?(index, "#execution-#{execution.id}")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions/#{execution.id}")
      assert has_element?(view, "#cancel-prompt")
      refute has_element?(view, "#resolve-failed-prompt")
      refute has_element?(view, "#resolve-retry-prompt")

      html = render_click(view, "confirm_resolve", %{"choice" => "failed"})
      assert html =~ "You do not have permission to do that."
    end

    test "a viewer sees history without cancel or resolve controls", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install()

      execution = queued_execution(Scope.new(member), installation.id)
      InstallationsFixtures.set_role(member, "viewer")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions/#{execution.id}")

      assert has_element?(view, "#execution-show")
      assert has_element?(view, "#execution-controls-readonly")
      refute has_element?(view, "#cancel-prompt")
      refute has_element?(view, "#resolve-succeeded-prompt")

      html = render_click(view, "confirm_cancel", %{})
      assert html =~ "You do not have permission to do that."
    end
  end

  describe "status and timeline rendering" do
    test "the show page lists trigger, version, attempts, wait, and branch fields", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "owner")

      scope = Scope.new(member)
      delay = delay_node()
      halt = stop_node()
      %{version: version} = activate!(scope, installation.id, definition([delay, halt]))

      {:ok, execution} =
        Engine.create(scope, %{
          workflow_version_id: version.id,
          execution_key: "hist-#{System.unique_integer([:positive])}",
          trigger_snapshot: %{
            "type" => "NEW_MESSAGE",
            "correlation_id" => "corr-history-1",
            "channel_id" => "channel-1"
          }
        })

      {:ok, snapshot} = Engine.claim(job_args(execution))
      resume_at = DateTime.add(DateTime.utc_now(), 90, :second)

      {:ok, outcome} =
        Outcome.new(%{
          kind: :wait_delay,
          edge: "next",
          resume_at: resume_at,
          output: %{"resume_at" => DateTime.to_iso8601(resume_at)}
        })

      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)

      extra =
        step_execution(waiting, %{
          node_id: halt.id,
          node_type: "stop",
          status: "queued"
        })

      step_attempt(extra, %{status: "started", duration_ms: 0})

      approval(extra, %{pumble_message_id: "pumble-msg-1"})

      {:ok, view, html} = live(log_in(conn, token), ~p"/executions/#{waiting.id}")

      assert has_element?(view, ~s(#execution-show[data-status="waiting_delay"]))
      assert has_element?(view, "#execution-id")
      assert has_element?(view, "#execution-key")
      assert has_element?(view, "#correlation-id")
      assert has_element?(view, "div#execution-copy-fields")
      refute has_element?(view, "dl#execution-copy-fields")

      assert has_element?(
               view,
               ~s(#execution-id-copy-control[phx-hook="CopyToClipboard"][phx-update="ignore"])
             )

      assert has_element?(view, ~s(#execution-id-copy[aria-label="Copy Execution ID"]))
      assert has_element?(view, "#execution-version-link")
      assert has_element?(view, ~s(#step-#{delay.id}[data-status="waiting_delay"]))
      assert has_element?(view, "#step-attempts-#{delay.id}")
      assert has_element?(view, "#step-approval-#{halt.id}")
      assert has_element?(view, "#attempt-diagnostics-#{halt.id}-1", "0 ms")
      assert html =~ "Version #{version.version_number}"
      assert html =~ "corr-history-1"
      assert html =~ "next"
      assert html =~ DateTime.to_iso8601(resume_at)
      assert html =~ "pumble-msg-1"

      href = view |> element("#execution-version-link") |> render()
      assert href =~ ~p"/workflows/#{waiting.workflow_id}"
      refute href =~ "/edit"
    end
  end

  describe "pagination and query count" do
    test "cursor pagination walks older executions", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      scope = Scope.new(member)
      %{version: version} = activate!(scope, installation.id)

      ids =
        Enum.map(1..21, fn _index ->
          queued_execution(scope, installation.id, version).id
        end)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions")

      assert has_element?(view, "#execution-pagination")
      assert has_element?(view, "#pagination-next")
      visible = Enum.count(ids, &has_element?(view, "#execution-#{&1}"))
      assert visible == 20

      view |> element("#pagination-next") |> render_click()
      assert has_element?(view, "#pagination-newest")
      visible = Enum.count(ids, &has_element?(view, "#execution-#{&1}"))
      assert visible == 1
    end

    test "status and workflow filters the page", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      scope = Scope.new(member)
      first = activate!(scope, installation.id, definition([delay_node()]), "Alpha runs")
      second = activate!(scope, installation.id, definition([stop_node()]), "Beta runs")
      alpha = queued_execution(scope, installation.id, first.version)
      beta = queued_execution(scope, installation.id, second.version)
      {:ok, cancelled} = Engine.cancel(scope, beta.id)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions")

      view
      |> form("#execution-filter-form", filter: %{workflow_id: first.workflow.id})
      |> render_change()

      assert has_element?(view, "#execution-#{alpha.id}")
      refute has_element?(view, "#execution-#{cancelled.id}")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions")

      view
      |> form("#execution-filter-form", filter: %{status: "cancelled"})
      |> render_change()

      assert has_element?(view, "#execution-#{cancelled.id}")
      refute has_element?(view, "#execution-#{alpha.id}")
    end

    test "listing many executions does not add a query per row", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      scope = Scope.new(member)
      %{version: version} = activate!(scope, installation.id)
      for _index <- 1..12, do: queued_execution(scope, installation.id, version)

      {_result, queries} =
        count_queries(fn -> live(log_in(conn, token), ~p"/executions") end)

      assert queries < 12
    end

    test "opening a long timeline does not add a query per step", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      scope = Scope.new(member)
      execution = queued_execution(scope, installation.id)

      for _index <- 1..8 do
        step_execution(execution, %{
          node_id: Ecto.UUID.generate(),
          node_type: "delay",
          status: "completed",
          selected_edge: "next"
        })
      end

      {_result, queries} =
        count_queries(fn -> live(log_in(conn, token), ~p"/executions/#{execution.id}") end)

      assert queries < 16
    end
  end

  describe "cancel race" do
    test "an editor can cancel a queued execution", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      execution = queued_execution(Scope.new(member), installation.id)
      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions/#{execution.id}")

      view |> element("#cancel-prompt") |> render_click()
      assert has_element?(view, "#cancel-confirm")
      view |> element("#cancel-submit") |> render_click()

      assert has_element?(view, ~s(#execution-show[data-status="cancelled"]))
      assert Repo.get!(Execution, execution.id).status == "cancelled"
    end

    test "two sessions cancel the same queued run and both see cancelled", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      execution = queued_execution(Scope.new(member), installation.id)
      path = ~p"/executions/#{execution.id}"

      {:ok, session_a, _html} = live(log_in(conn, token), path)
      {:ok, session_b, _html} = live(log_in(build_conn(), token), path)

      session_a |> element("#cancel-prompt") |> render_click()
      session_b |> element("#cancel-prompt") |> render_click()
      session_a |> element("#cancel-submit") |> render_click()
      session_b |> element("#cancel-submit") |> render_click()

      assert has_element?(session_a, ~s(#execution-show[data-status="cancelled"]))
      assert has_element?(session_b, ~s(#execution-show[data-status="cancelled"]))
      assert Repo.get!(Execution, execution.id).status == "cancelled"
    end

    test "a stale cancel of a completed run conflicts and refreshes", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      scope = Scope.new(member)
      execution = queued_execution(scope, installation.id)
      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions/#{execution.id}")

      {:ok, snapshot} = Engine.claim(job_args(execution))
      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})
      assert {:ok, completed} = Engine.finalize(snapshot, outcome)
      assert completed.status == "completed"

      view |> element("#cancel-prompt") |> render_click()
      html = view |> element("#cancel-submit") |> render_click()

      assert html =~ "The execution cannot make that transition."
      assert has_element?(view, ~s(#execution-show[data-status="completed"]))
      refute has_element?(view, "#cancel-prompt")
    end
  end

  describe "uncertainty actions" do
    test "an owner can fail or retry a paused execution", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "owner")

      scope = Scope.new(member)
      execution = paused_execution(scope, installation.id)
      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions/#{execution.id}")

      [step] = execution_steps(execution.id)
      assert has_element?(view, "#attempt-diagnostics-#{step.node_id}-1")
      assert render(view) =~ "Effect key"
      assert render(view) =~ "Request summary"
      assert render(view) =~ "Dispatch evidence"

      assert has_element?(
               view,
               "#attempt-diagnostics-#{step.node_id}-1 dd",
               "Possibly sent"
             )

      assert render(view) =~ "Bytes may have left"
      assert render(view) =~ "Operator guidance"
      assert has_element?(view, "#resolve-failed-prompt")
      assert has_element?(view, "#resolve-retry-prompt")

      view |> element("#resolve-retry-prompt") |> render_click()
      assert has_element?(view, "#uncertain-retry-confirm")
      html = render(view)
      assert html =~ "duplicate risk"

      html =
        view
        |> form("#uncertain-retry-form", %{
          "choice" => "retry",
          "retry" => %{"acknowledge_duplicate_risk" => "false"}
        })
        |> render_submit()

      assert html =~ "acknowledging the duplicate risk"
      assert Repo.get!(Execution, execution.id).status == "paused_uncertain"

      view
      |> form("#uncertain-retry-form", %{
        "choice" => "retry",
        "retry" => %{"acknowledge_duplicate_risk" => "true"}
      })
      |> render_submit()

      assert has_element?(view, ~s(#execution-show[data-status="running"]))
    end

    test "diagnostic clipping preserves valid UTF-8", %{conn: _conn} do
      %{installation: installation, member: member} =
        InstallationsFixtures.install(role: "owner")

      scope = Scope.new(member)
      execution = paused_execution(scope, installation.id)
      [attempt] = Repo.all(from a in StepAttempt, where: a.installation_id == ^installation.id)
      value = String.duplicate("a", 511) <> "💥"

      assert {1, _rows} =
               Repo.update_all(
                 from(a in StepAttempt, where: a.id == ^attempt.id),
                 set: [diagnostics: %{"message" => value}]
               )

      assert {:ok, detail} = History.get_detail(scope, execution.id)
      [stored] = detail.steps |> hd() |> Map.fetch!(:attempts)
      clipped = stored.diagnostics["message"]

      assert String.valid?(clipped)
      assert byte_size(clipped) == 511
    end

    test "an owner can mark an uncertain effect failed", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "owner")

      execution = paused_execution(Scope.new(member), installation.id)
      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions/#{execution.id}")

      view |> element("#resolve-failed-prompt") |> render_click()
      view |> element("#uncertain-failed-submit") |> render_click()

      assert has_element?(view, ~s(#execution-show[data-status="failed"]))
      assert Repo.get!(Execution, execution.id).status == "failed"
    end
  end

  describe "redaction and cross-tenant" do
    test "raw message text is omitted from trigger and step output", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "owner")

      scope = Scope.new(member)
      planted = "s3cret-private-payload-must-not-leak"
      %{version: version} = activate!(scope, installation.id)

      {:ok, execution} =
        Engine.create(scope, %{
          workflow_version_id: version.id,
          execution_key: "redact-#{System.unique_integer([:positive])}",
          trigger_snapshot: %{
            "type" => "NEW_MESSAGE",
            "correlation_id" => "corr-redact",
            "text" => planted,
            "channel_id" => "channel-1"
          }
        })

      step_execution(execution, %{
        node_id: Ecto.UUID.generate(),
        node_type: "pumble_action",
        status: "completed",
        output: %{"text" => planted, "message_id" => "msg-safe"}
      })

      {:ok, view, html} = live(log_in(conn, token), ~p"/executions/#{execution.id}")

      assert has_element?(view, "#correlation-id")
      assert html =~ "msg-safe"
      assert html =~ "corr-redact"
      refute html =~ planted
      refute html =~ "token_digest"
      refute html =~ "super-secret"
    end

    test "another workspace's execution does not leak existence", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")
      other = InstallationsFixtures.install()
      theirs = queued_execution(Scope.new(other.member), other.installation.id)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in(conn, token), ~p"/executions/#{theirs.id}")

      assert to == ~p"/executions"

      {:ok, view, _html} = live(log_in(conn, token), ~p"/executions")
      refute has_element?(view, "#execution-#{theirs.id}")
    end
  end

  defp queued_execution(scope, installation_id, version \\ nil) do
    version = version || activate!(scope, installation_id).version

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: version.id,
        execution_key: "ui-#{System.unique_integer([:positive])}"
      })

    Repo.get!(Execution, execution.id)
  end

  defp paused_execution(scope, installation_id) do
    %{version: version} = activate!(scope, installation_id, definition([stop_node()]))
    execution = queued_execution(scope, installation_id, version)
    {:ok, snapshot} = Engine.claim(job_args(execution))

    {:ok, outcome} =
      Outcome.new(%{
        kind: :uncertain,
        error_class: "side_effect_uncertain",
        message: "The remote write may have succeeded.",
        output: %{"request_written" => true}
      })

    {:ok, paused} = Engine.finalize(snapshot, outcome)
    assert paused.status == "paused_uncertain"
    paused
  end

  defp execution_steps(execution_id) do
    Repo.all(
      from step in PumbleAutomation.Executions.StepExecution,
        where: step.execution_id == ^execution_id,
        order_by: [asc: step.inserted_at]
    )
  end

  defp activate!(scope, installation_id, definition \\ definition([delay_node()]), name \\ nil) do
    attrs = %{draft_definition: Definition.encode(definition)}
    attrs = if name, do: Map.put(attrs, :name, name), else: attrs
    workflow = drafted_workflow(installation_id, attrs)
    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end

  defp count_queries(fun) do
    handler = "execution-live-query-count-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])
    mine = self()

    :telemetry.attach(
      handler,
      [:pumble_automation, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == mine, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end
end
