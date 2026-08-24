defmodule PumbleAutomation.Observability.DiagnosticExportTest do
  @moduledoc """
  Privacy-safe diagnostic export: golden allowlist, forbidden-value scan,
  tenant isolation, size/time bounds, artifact expiry, and owner audit.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Phoenix.LiveViewTest

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Diagnostics.Export
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.ExecutionsFixtures
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomationWeb.BrowserSession

  @planted_message "PLANTED_PRIVATE_MESSAGE"
  @planted_body "PLANTED_RAW_BODY"
  @planted_job_token "PLANTED_JOB_TOKEN"
  @planted_approval "PLANTED_APPROVAL_TOKEN"
  @secret_values [
    @planted_message,
    @planted_body,
    @planted_job_token,
    @planted_approval,
    "bot-access-token",
    "user-access-token"
  ]

  setup do
    dir = Path.join(System.tmp_dir!(), "pa-diag-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:pumble_automation, Export, [])

    Application.put_env(
      :pumble_automation,
      Export,
      Keyword.merge(previous, tmp_dir: dir)
    )

    Export.setup()

    on_exit(fn ->
      Application.put_env(:pumble_automation, Export, previous)
      File.rm_rf(dir)
    end)

    %{installation: installation, member: member, session_token: token} =
      InstallationsFixtures.install()

    %{
      dir: dir,
      installation: installation,
      member: member,
      scope: Scope.new(member),
      session_token: token
    }
  end

  describe "golden export" do
    test "the bundle names hashes, error codes, provider ids, jobs, and limits", %{
      scope: scope,
      installation: installation
    } do
      %{execution: execution, job: job} = planted_run!(installation)

      assert {:ok, result} = Export.generate(scope, execution_id: execution.id)
      bundle = result.bundle
      timeline = hd(bundle["executions"])
      attempt = hd(hd(timeline["steps"])["attempts"])

      assert bundle["schema_version"] == 1
      assert bundle["application"]["name"] == "pumble_automation"
      assert bundle["application"]["version"] == "0.1.0"
      assert bundle["installation"]["id"] == installation.id
      assert bundle["installation"]["status"] == "active"
      assert bundle["installation"]["workspace_id"] == installation.pumble_workspace_id
      assert is_list(bundle["installation"]["bot_scopes"])
      assert is_list(bundle["installation"]["user_scopes"])
      assert bundle["selection"]["execution_id"] == execution.id
      assert bundle["selection"]["truncated"] == false

      assert Enum.sort(Map.keys(bundle)) ==
               Enum.sort([
                 "application",
                 "executions",
                 "exported_at",
                 "installation",
                 "jobs",
                 "limits",
                 "schema_version",
                 "selection",
                 "workflows"
               ])

      assert Enum.sort(Map.keys(bundle["installation"])) ==
               Enum.sort([
                 "bot_scopes",
                 "bot_user_id",
                 "id",
                 "status",
                 "user_scopes",
                 "workspace_id"
               ])

      workflow = Enum.find(bundle["workflows"], &(&1["id"] == timeline["workflow_id"]))
      assert workflow["name"]
      assert timeline["definition_hash"] =~ ~r/\A[0-9a-f]{64}\z/
      assert timeline["trigger_channel_id"] == "chan-planted"
      assert attempt["error_code"] == "http_403"
      assert attempt["remote_request_id"] == "req-planted"
      assert attempt["oban_job_id"] == job.id
      assert Enum.any?(bundle["jobs"], &(&1["id"] == job.id))
      assert bundle["limits"]["running_executions"] == 5
      assert result.digest =~ ~r/\A[0-9a-f]{64}\z/
      assert result.signature =~ ~r/\A[0-9a-f]{64}\z/
      assert result.field_names == Enum.sort(result.field_names)
      assert "executions.0.error_code" not in result.field_names
      assert Enum.any?(result.field_names, &String.ends_with?(&1, "error_code"))
      assert File.regular?(result.artifact_path)
    end
  end

  describe "forbidden-value scan" do
    test "secrets, tokens, bodies, and message text never appear in JSON or ZIP", %{
      scope: scope,
      installation: installation
    } do
      %{execution: execution} = planted_run!(installation)

      assert {:ok, result} = Export.generate(scope, execution_id: execution.id)
      json = Jason.encode!(result.bundle)
      {:ok, zip} = Export.read_artifact(scope, result.artifact_id)
      {:ok, files} = :zip.extract(zip, [:memory])
      assert Enum.map(files, fn {name, _bytes} -> name end) == [~c"bundle.json"]
      zip_json = Enum.map_join(files, "", fn {_name, bytes} -> bytes end)

      for planted <- @secret_values do
        refute json =~ planted
        refute zip_json =~ planted
      end

      refute Enum.any?(result.field_names, fn name ->
               name
               |> String.split(".")
               |> Enum.any?(&(&1 in ~w(token secret body text message payload raw password)))
             end)

      refute json =~ "[REDACTED]"
      refute json =~ "encrypted"
      refute json =~ "token_digest"
      refute json =~ @planted_message
      refute zip =~ @planted_body
    end
  end

  describe "cross-tenant" do
    test "a foreign execution is not found and a local bundle names only this tenant", %{
      scope: scope,
      installation: installation
    } do
      %{installation: other, member: other_member} = InstallationsFixtures.install()
      %{execution: foreign} = planted_run!(other)
      %{execution: local} = planted_run!(installation)

      assert {:error, %Error{class: :not_found}} =
               Export.generate(scope, execution_id: foreign.id)

      assert {:ok, result} = Export.generate(scope, execution_id: local.id)
      encoded = Jason.encode!(result.bundle)
      refute encoded =~ other.pumble_workspace_id
      refute encoded =~ other.id
      assert result.bundle["installation"]["id"] == installation.id

      assert {:error, %Error{class: :not_found}} =
               Export.read_artifact(Scope.new(other_member), result.artifact_id)
    end
  end

  describe "size and time limits" do
    test "a missing selection, oversize window, and oversize bundle are refused", %{
      scope: scope,
      installation: installation,
      dir: dir
    } do
      %{execution: execution} = planted_run!(installation)

      assert {:error, %Error{code: :selection_required}} = Export.generate(scope, [])

      from = DateTime.add(DateTime.utc_now(), -(Export.max_window_seconds() + 60), :second)

      assert {:error, %Error{code: :window_too_large}} =
               Export.generate(scope, from: from, until: DateTime.utc_now())

      previous = Application.get_env(:pumble_automation, Export, [])
      Application.put_env(:pumble_automation, Export, Keyword.put(previous, :max_bytes, 32))

      try do
        assert {:error, %Error{code: :diagnostics_too_large}} =
                 Export.generate(scope, execution_id: execution.id)
      after
        Application.put_env(:pumble_automation, Export, previous)
      end

      assert File.ls!(dir) == []
    end

    test "a time window is capped and reports truncation", %{
      scope: scope,
      installation: installation
    } do
      _first = planted_run!(installation)
      _second = planted_run!(installation)
      now = DateTime.utc_now()

      previous = Application.get_env(:pumble_automation, Export, [])
      Application.put_env(:pumble_automation, Export, Keyword.put(previous, :max_executions, 1))

      try do
        assert {:ok, result} =
                 Export.generate(scope,
                   from: DateTime.add(now, -120, :second),
                   until: DateTime.add(now, 120, :second)
                 )

        assert length(result.bundle["executions"]) == 1
        assert result.bundle["selection"]["truncated"] == true
      after
        Application.put_env(:pumble_automation, Export, previous)
      end
    end
  end

  describe "temporary cleanup" do
    test "expired artifacts are deleted and unreadable afterwards", %{
      scope: scope,
      installation: installation
    } do
      %{execution: execution} = planted_run!(installation)

      assert {:ok, result} = Export.generate(scope, execution_id: execution.id, ttl_seconds: 1)
      path = result.artifact_path
      meta = String.replace_suffix(path, ".zip", ".meta.json")
      assert File.regular?(path)
      assert File.regular?(meta)

      assert {:ok, 0} = Export.cleanup_expired(now: DateTime.utc_now())
      assert File.regular?(path)

      later = DateTime.add(DateTime.utc_now(), 5, :second)
      assert {:ok, 1} = Export.cleanup_expired(now: later)
      refute File.exists?(path)
      refute File.exists?(meta)
      refute File.exists?(path <> ".partial")

      assert {:error, %Error{class: :not_found}} =
               Export.read_artifact(scope, result.artifact_id)
    end
  end

  describe "role and audit" do
    test "an editor cannot export and an owner export is audited", %{
      installation: installation,
      member: member,
      scope: scope
    } do
      %{execution: execution} = planted_run!(installation)
      editor = Scope.new(InstallationsFixtures.set_role(member, "editor"))

      assert {:error, %Error{class: :permission}} =
               Export.generate(editor, execution_id: execution.id)

      assert {:ok, result} = Export.generate(scope, execution_id: execution.id)

      event =
        Repo.get_by!(AuditEvent,
          action: "admin.diagnostics_exported",
          installation_id: installation.id
        )

      assert event.actor_type == "user"
      assert event.actor_id == scope.member_id
      assert event.installation_id == installation.id
      assert event.metadata["source"] == "support"
      assert event.metadata["result"] == "ok"
      assert event.metadata["count"] == length(result.field_names)
    end
  end

  describe "owner LiveView" do
    test "an owner previews field names; editors and visitors cannot export", %{
      conn: conn,
      session_token: token,
      installation: installation
    } do
      %{execution: execution} = planted_run!(installation)
      {:ok, view, _html} = live(log_in(conn, token), ~p"/settings/diagnostics")

      assert has_element?(view, "#diagnostics-form")
      assert has_element?(view, "#diagnostics-export")

      view
      |> form("#diagnostics-form", export: %{execution_id: execution.id})
      |> render_submit()

      assert has_element?(view, "#diagnostics-fields")
      assert has_element?(view, "#diagnostics-json")
      assert has_element?(view, "#diagnostics-digest")
      html = render(view)
      assert html =~ "application"
      assert html =~ "definition_hash"
      refute html =~ @planted_message
      refute html =~ "bot-access-token"

      %{session_token: editor_token, member: editor} = InstallationsFixtures.install()
      InstallationsFixtures.set_role(editor, "editor")
      {:ok, editor_view, _html} = live(log_in(conn, editor_token), ~p"/settings/diagnostics")
      assert has_element?(editor_view, "#diagnostics-forbidden")
      refute has_element?(editor_view, "#diagnostics-form")

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/diagnostics")
      assert to == BrowserSession.sign_in_path()
    end
  end

  defp planted_run!(installation) do
    version = ExecutionsFixtures.version(installation.id)

    execution =
      ExecutionsFixtures.execution(version, %{
        status: "failed",
        trigger_snapshot: %{
          "type" => "NEW_MESSAGE",
          "text" => @planted_message,
          "channel_id" => "chan-planted",
          "actor_id" => "actor-planted"
        },
        context: %{
          "execution" => %{"run_mode" => "live"},
          "body" => @planted_body
        }
      })

    {:ok, job} =
      %{
        "installation_id" => installation.id,
        "execution_id" => execution.id,
        "expected_node_id" => execution.current_node_id,
        "generation" => 0,
        "token" => @planted_job_token
      }
      |> AdvanceExecutionWorker.new()
      |> Oban.insert()

    step =
      ExecutionsFixtures.step_execution(execution, %{
        status: "failed",
        node_type: "pumble_action",
        output: %{
          "excerpt" => @planted_message,
          "reason" => @planted_message,
          "message_id" => "msg-planted",
          "channel_id" => "chan-planted",
          "status" => "403"
        }
      })

    {:ok, _attempt} =
      StepAttempt.create(step, %{
        status: "failed",
        error_class: "permanent",
        error_code: "http_403",
        remote_status: 403,
        remote_request_id: "req-planted",
        duration_ms: 12,
        oban_job_id: job.id,
        ended_at: DateTime.utc_now()
      })

    _approval =
      ExecutionsFixtures.approval(step, %{
        token: "#{@planted_approval}-#{System.unique_integer([:positive])}"
      })

    %{execution: execution, job: job, version: version}
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
