defmodule PumbleAutomationWeb.InboundWebhookControllerTest do
  @moduledoc """
  Authenticated inbound webhooks: token rotation, bounds, rate limits,
  idempotency, and tenant isolation.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.IngressFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Limits

  setup do
    WebhookService.reset_rate_table()
    %{installation: installation, member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)
    %{version: version} = activate_webhook!(scope, installation.id)
    token = WebhookEndpoint.generate_token()
    endpoint = webhook_endpoint(version, %{token: token})

    %{
      scope: scope,
      installation_id: installation.id,
      version: version,
      endpoint: endpoint,
      token: token
    }
  end

  describe "auth and rotation" do
    test "a valid bearer token returns 202 with an opaque receipt id", %{
      conn: conn,
      endpoint: endpoint,
      token: token,
      version: version
    } do
      conn = post_webhook(conn, endpoint.public_id, token, %{"ping" => true})

      assert %{"id" => receipt_id} = json_response(conn, 202)
      assert {:ok, _} = Ecto.UUID.cast(receipt_id)
      refute json_response(conn, 202) |> Map.has_key?("token")

      assert [%ReceivedEvent{id: ^receipt_id, class: "webhook", processing_state: "processed"}] =
               Repo.all(ReceivedEvent)

      assert [%Execution{workflow_version_id: version_id}] = Repo.all(Execution)
      assert version_id == version.id
      assert_enqueued(worker: AdvanceExecutionWorker)
    end

    test "the previous token works until the overlap expires", %{
      conn: conn,
      version: version
    } do
      current = WebhookEndpoint.generate_token()
      previous = WebhookEndpoint.generate_token()
      now = DateTime.utc_now()

      endpoint =
        webhook_endpoint(version, %{
          token: current,
          previous_token_digest: WebhookEndpoint.digest(previous),
          previous_token_expires_at: DateTime.add(now, 60, :second)
        })

      conn = post_webhook(conn, endpoint.public_id, previous, %{"ok" => true})
      assert %{"id" => _} = json_response(conn, 202)
    end

    test "an unknown public id and a bad token both answer 401 without disclosure", %{
      conn: conn,
      endpoint: endpoint
    } do
      missing = post_webhook(conn, WebhookEndpoint.generate_public_id(), endpoint_token(), %{})
      bad = post_webhook(build_conn(), endpoint.public_id, endpoint_token(), %{})

      assert missing.status == 401
      assert bad.status == 401
      assert json_response(missing, 401) == json_response(bad, 401)
      refute json_response(missing, 401)["id"]
    end

    test "the fixed header authenticates the same way as Authorization", %{
      conn: conn,
      endpoint: endpoint,
      token: token
    } do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header(WebhookService.token_header(), encode_token(token))
        |> post(~p"/hooks/#{endpoint.public_id}", Jason.encode!(%{"via" => "header"}))

      assert %{"id" => _} = json_response(conn, 202)
    end

    test "a token in the query string is never accepted", %{
      conn: conn,
      endpoint: endpoint,
      token: token
    } do
      encoded = encode_token(token)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> encoded)
        |> post(
          "/hooks/#{endpoint.public_id}?token=#{encoded}",
          Jason.encode!(%{"no" => true})
        )

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      refute Repo.exists?(Execution)
    end

    test "repeated credential headers are ambiguous even when another credential is valid", %{
      endpoint: endpoint,
      token: token,
      version: version
    } do
      encoded = encode_token(token)
      raw_body = ~s({"ambiguous":true})

      repeated_authorization =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header(WebhookService.token_header(), encoded)
        |> put_repeated_header("authorization", ["Bearer " <> encoded, "Bearer " <> encoded])
        |> post(~p"/hooks/#{endpoint.public_id}", raw_body)

      repeated_token =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> encoded)
        |> put_repeated_header(WebhookService.token_header(), [encoded, encoded])
        |> post(~p"/hooks/#{endpoint.public_id}", raw_body)

      signing_secret = WebhookEndpoint.generate_signing_secret()
      signed_token = WebhookEndpoint.generate_token()

      signed_endpoint =
        webhook_endpoint(version, %{
          token: signed_token,
          require_signature: true,
          signing_secret: signing_secret,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
        })

      signature = WebhookEndpoint.sign_body(signing_secret, raw_body)

      repeated_signature =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> encode_token(signed_token))
        |> put_repeated_header(WebhookService.signature_header(), [signature, signature])
        |> post(~p"/hooks/#{signed_endpoint.public_id}", raw_body)

      for conn <- [repeated_authorization, repeated_token, repeated_signature] do
        assert json_response(conn, 401) == %{"error" => "unauthorized"}
      end

      refute Repo.exists?(Execution)
    end
  end

  describe "optional raw-body HMAC" do
    test "a required signature authenticates the exact raw request bytes", %{
      conn: conn,
      version: version
    } do
      token = WebhookEndpoint.generate_token()
      signing_secret = WebhookEndpoint.generate_signing_secret()

      endpoint =
        webhook_endpoint(version, %{
          token: token,
          require_signature: true,
          signing_secret: signing_secret,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
        })

      raw_body = ~s({"ping": true, "space": "preserved"})
      signature = WebhookEndpoint.sign_body(signing_secret, raw_body)

      conn = post_raw_webhook(conn, endpoint.public_id, token, raw_body, signature)
      assert %{"id" => _} = json_response(conn, 202)
    end

    test "missing, malformed, and invalid signatures share one generic auth failure", %{
      version: version
    } do
      token = WebhookEndpoint.generate_token()
      signing_secret = WebhookEndpoint.generate_signing_secret()

      endpoint =
        webhook_endpoint(version, %{
          token: token,
          require_signature: true,
          signing_secret: signing_secret,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
        })

      raw_body = ~s({"authenticated":false})

      responses =
        for signature <- [nil, "sha256=not-hex", "sha256=" <> String.duplicate("0", 64)] do
          conn = post_raw_webhook(build_conn(), endpoint.public_id, token, raw_body, signature)
          {conn.status, json_response(conn, 401)}
        end

      assert Enum.uniq(responses) == [{401, %{"error" => "unauthorized"}}]
      refute Repo.exists?(Execution)
      refute Repo.exists?(ReceivedEvent)
    end

    test "a signature over re-encoded or mutated bytes is refused", %{
      conn: conn,
      version: version
    } do
      token = WebhookEndpoint.generate_token()
      signing_secret = WebhookEndpoint.generate_signing_secret()

      endpoint =
        webhook_endpoint(version, %{
          token: token,
          require_signature: true,
          signing_secret: signing_secret,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
        })

      signed = ~s({"n":1})
      mutated = ~s({"n": 1})
      signature = WebhookEndpoint.sign_body(signing_secret, signed)

      conn = post_raw_webhook(conn, endpoint.public_id, token, mutated, signature)
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      refute Repo.exists?(Execution)
    end

    test "the previous signing secret works only during its overlap", %{
      conn: conn,
      version: version
    } do
      token = WebhookEndpoint.generate_token()
      current_secret = WebhookEndpoint.generate_signing_secret()
      previous_secret = WebhookEndpoint.generate_signing_secret()
      now = DateTime.utc_now()

      endpoint =
        webhook_endpoint(version, %{
          token: token,
          require_signature: true,
          signing_secret: current_secret,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version(),
          previous_signing_secret: previous_secret,
          previous_signing_secret_key_version: WebhookEndpoint.signing_secret_key_version(),
          previous_signing_secret_expires_at: DateTime.add(now, 60, :second)
        })

      raw_body = ~s({"rotation":true})
      signature = WebhookEndpoint.sign_body(previous_secret, raw_body)

      conn = post_raw_webhook(conn, endpoint.public_id, token, raw_body, signature)
      assert %{"id" => _} = json_response(conn, 202)
    end
  end

  describe "content type, size, and depth" do
    test "a non-JSON content type is 415", %{conn: conn, endpoint: endpoint, token: token} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("authorization", "Bearer " <> encode_token(token))
        |> post(~p"/hooks/#{endpoint.public_id}", "ping")

      assert json_response(conn, 415)["error"] == "unsupported_media_type"
    end

    test "a body over the webhook cap is 413", %{conn: conn, endpoint: endpoint, token: token} do
      body = json_of_size(WebhookService.max_body_bytes() + 1)

      assert_error_sent(413, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> encode_token(token))
        |> post(~p"/hooks/#{endpoint.public_id}", body)
      end)
    end

    test "JSON nested past the decode depth is 400", %{
      conn: conn,
      endpoint: endpoint,
      token: token
    } do
      nested =
        Enum.reduce(1..(Limits.max_json_depth() + 2), "leaf", fn _i, acc -> %{"n" => acc} end)

      conn = post_webhook(conn, endpoint.public_id, token, nested)
      assert json_response(conn, 400)["error"] == "invalid"
      refute Repo.exists?(Execution)
    end
  end

  describe "rate limits" do
    test "exceeding the per-endpoint limit is 429", %{conn: conn, version: version} do
      token = WebhookEndpoint.generate_token()

      endpoint =
        webhook_endpoint(version, %{
          token: token,
          rate_limit_per_minute: 1,
          rate_limit_per_ip_per_minute: 10
        })

      first = post_webhook(conn, endpoint.public_id, token, %{"n" => 1})
      assert json_response(first, 202)

      second = post_webhook(build_conn(), endpoint.public_id, token, %{"n" => 2})
      assert json_response(second, 429)["error"] == "rate_limited"
      assert get_resp_header(second, "retry-after") == ["60"]
    end

    test "authentication failures are capped before endpoint lookup and HMAC", %{
      version: version
    } do
      previous_limits = Application.get_env(:pumble_automation, :limits, %{})
      on_exit(fn -> Application.put_env(:pumble_automation, :limits, previous_limits) end)

      Application.put_env(
        :pumble_automation,
        :limits,
        Map.put(previous_limits, :callback_failures_per_minute, 2)
      )

      first =
        post_webhook(
          build_conn(),
          WebhookEndpoint.generate_public_id(),
          WebhookEndpoint.generate_token(),
          %{"n" => 1}
        )

      second =
        post_webhook(
          build_conn(),
          WebhookEndpoint.generate_public_id(),
          WebhookEndpoint.generate_token(),
          %{"n" => 2}
        )

      assert json_response(first, 401) == %{"error" => "unauthorized"}
      assert json_response(second, 401) == %{"error" => "unauthorized"}

      token = WebhookEndpoint.generate_token()
      signing_secret = WebhookEndpoint.generate_signing_secret()

      endpoint =
        webhook_endpoint(version, %{
          token: token,
          require_signature: true,
          signing_secret: signing_secret,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
        })

      Repo.query!("UPDATE webhook_endpoints SET signing_secret = $1 WHERE id = $2", [
        :binary.copy(<<0>>, 31),
        Ecto.UUID.dump!(endpoint.id)
      ])

      limited =
        post_raw_webhook(
          build_conn(),
          endpoint.public_id,
          token,
          ~s({"n":3}),
          WebhookEndpoint.sign_body(signing_secret, ~s({"n":3}))
        )

      assert json_response(limited, 429) == %{"error" => "rate_limited"}
      assert get_resp_header(limited, "retry-after") == ["60"]
      refute Repo.exists?(Execution)
    end
  end

  describe "idempotency" do
    test "a repeated Idempotency-Key returns the same receipt and one execution", %{
      conn: conn,
      endpoint: endpoint,
      token: token
    } do
      headers = [{"idempotency-key", "hook-1"}]
      first = post_webhook(conn, endpoint.public_id, token, %{"once" => true}, headers)
      second = post_webhook(build_conn(), endpoint.public_id, token, %{"once" => true}, headers)

      assert json_response(first, 202) == json_response(second, 202)
      assert Repo.aggregate(ReceivedEvent, :count) == 1
      assert Repo.aggregate(Execution, :count) == 1

      assert [%Execution{trigger_snapshot: snapshot}] = Repo.all(Execution)
      refute Map.has_key?(snapshot["headers"], "idempotency-key")
      refute inspect(snapshot) =~ "hook-1"

      assert [%ReceivedEvent{data: receipt_data}] = Repo.all(ReceivedEvent)
      refute Map.has_key?(receipt_data["headers"], "idempotency-key")
      refute inspect(receipt_data) =~ "hook-1"
    end

    test "without Idempotency-Key each authenticated request is distinct", %{
      conn: conn,
      endpoint: endpoint,
      token: token
    } do
      post_webhook(conn, endpoint.public_id, token, %{"n" => 1})
      post_webhook(build_conn(), endpoint.public_id, token, %{"n" => 1})

      assert Repo.aggregate(ReceivedEvent, :count) == 2
      assert Repo.aggregate(Execution, :count) == 2
    end
  end

  describe "disabled and cross-tenant" do
    test "a disabled endpoint is terminal 404 after valid auth", %{
      conn: conn,
      version: version
    } do
      token = WebhookEndpoint.generate_token()
      endpoint = webhook_endpoint(version, %{token: token, enabled: false})

      conn = post_webhook(conn, endpoint.public_id, token, %{"x" => 1})
      assert json_response(conn, 404)["error"] == "not_found"
      refute Repo.exists?(Execution)
    end

    test "another tenant's token cannot use this public id", %{
      conn: conn,
      endpoint: endpoint
    } do
      %{installation: other, member: member} = InstallationsFixtures.install()
      scope = Scope.new(member)
      %{version: other_version} = activate_webhook!(scope, other.id)
      other_token = WebhookEndpoint.generate_token()
      _other_endpoint = webhook_endpoint(other_version, %{token: other_token})

      conn = post_webhook(conn, endpoint.public_id, other_token, %{"x" => 1})
      assert json_response(conn, 401)["error"] == "unauthorized"
      refute Repo.exists?(from e in Execution, where: e.installation_id == ^other.id)
    end
  end

  describe "secret stripping" do
    test "secret-looking keys never reach the trigger snapshot", %{
      conn: conn,
      endpoint: endpoint,
      token: token
    } do
      conn =
        post_webhook(conn, endpoint.public_id, token, %{
          "ok" => true,
          "token" => "should-not-store"
        })

      assert json_response(conn, 202)
      assert [%Execution{trigger_snapshot: snapshot}] = Repo.all(Execution)
      refute Map.has_key?(snapshot["body"], "token")
      assert snapshot["body"]["ok"] == true
    end
  end

  defp activate_webhook!(scope, installation_id) do
    workflow =
      drafted_workflow(installation_id, %{
        name: "Hook #{System.unique_integer([:positive])}",
        slug: "hook-#{System.unique_integer([:positive])}",
        draft_definition:
          Definition.encode(Definition.new(Trigger.new(:webhook, %{}), [delay_node()]))
      })

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    result
  end

  defp post_webhook(conn, public_id, token, body, extra_headers \\ []) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> encode_token(token))

    conn =
      Enum.reduce(extra_headers, conn, fn {key, value}, acc ->
        put_req_header(acc, key, value)
      end)

    post(conn, ~p"/hooks/#{public_id}", Jason.encode!(body))
  end

  defp post_raw_webhook(conn, public_id, token, raw_body, signature) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> encode_token(token))

    conn =
      if is_binary(signature) do
        put_req_header(conn, WebhookService.signature_header(), signature)
      else
        conn
      end

    post(conn, ~p"/hooks/#{public_id}", raw_body)
  end

  defp encode_token(token), do: Base.url_encode64(token, padding: false)
  defp endpoint_token, do: encode_token(WebhookEndpoint.generate_token())

  defp put_repeated_header(conn, name, values) do
    name = String.downcase(name)
    retained = Enum.reject(conn.req_headers, fn {key, _value} -> key == name end)
    repeated = Enum.map(values, &{name, &1})
    %{conn | req_headers: repeated ++ retained}
  end

  defp json_of_size(bytes) do
    envelope = ~s({"pad":""})
    padding = bytes - byte_size(envelope)
    ~s({"pad":"#{String.duplicate("x", padding)}"})
  end
end
