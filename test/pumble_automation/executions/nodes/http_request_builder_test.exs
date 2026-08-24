defmodule PumbleAutomation.Executions.Nodes.HttpRequestBuilderTest do
  @moduledoc """
  HTTP action request builder: contracted methods and bodies, encoded query,
  JSON escaping, blocked headers, secret redaction, prefix escape, size
  bounds, and dry-run with no network and no plaintext secrets.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.InstallationsFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Connections.ResolvedConnection
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Nodes.HttpRequest
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Templates

  @public {1, 1, 1, 1}
  @planted "s3cret-value-must-not-leak"

  describe "method and body combinations" do
    test "GET, HEAD, and DELETE build with no body" do
      for method <- ["get", "head", "delete"] do
        assert {:ok, request} = build(%{"method" => method, "url" => "https://example.test/hook"})
        assert request.method == String.upcase(method)
        assert request.body == nil
        refute Map.has_key?(request.summary, "content_type")
        assert request.path == "/hook"
      end
    end

    test "POST, PUT, and PATCH accept json, text, and form bodies" do
      cases = [
        {"json", ~s({"q": {{ trigger.data.q }}}), "application/json"},
        {"text", "hello {{ trigger.data.q }}", "text/plain; charset=utf-8"},
        {"form", "q={{ trigger.data.q }}", "application/x-www-form-urlencoded"}
      ]

      for method <- ["post", "put", "patch"], {mode, body, content_type} <- cases do
        config =
          compiled(method: :post, url: "https://example.test/hook", body: body)
          |> Map.put("method", method)
          |> Map.put("body_mode", mode)

        assert {:ok, request} = build(config, %{"q" => "hello world"})
        assert request.method == String.upcase(method)
        assert request.body_mode in [:json, :text, :form]
        assert request.content_type == content_type
        assert {"content-type", content_type} in request.headers
        assert request.body != nil
        assert request.summary["body_bytes"] == byte_size(request.body)
      end
    end

    test "GET and DELETE refuse a body before a destination is approved" do
      for method <- ["get", "delete"] do
        assert {:error, %Error{code: :http_body_not_allowed, class: :validation}} =
                 build(%{
                   "method" => method,
                   "url" => "https://example.test/hook",
                   "body" => "x"
                 })
      end
    end
  end

  describe "query encoding" do
    test "spaces and reserved characters in a templated query are percent-encoded" do
      config = compiled(method: :get, url: "https://example.test/search?q={{ trigger.data.q }}")

      assert {:ok, request} = build(config, %{"q" => "hello world"})
      assert request.path == "/search?q=hello%20world"
      assert request.url == "https://example.test/search?q=hello%20world"
      assert request.target.hostname == "example.test"
    end

    test "a query map is encoded stably and merged onto the URL" do
      assert {:ok, request} =
               build(%{
                 "method" => "get",
                 "url" => "https://example.test/search?keep=1",
                 "query" => %{"q" => "hello world&x=1", "z" => "9"}
               })

      assert request.path == "/search?keep=1&q=hello%20world%26x%3D1&z=9"
    end
  end

  describe "JSON escaping" do
    test "interpolated JSON values are escaped before the body is encoded" do
      config =
        compiled(
          method: :post,
          url: "https://example.test/hook",
          body: ~s({"q": {{ trigger.data.q }}})
        )
        |> Map.put("body_mode", "json")

      assert {:ok, request} = build(config, %{"q" => ~s(hello "world")})
      assert Jason.decode!(request.body) == %{"q" => ~s(hello "world")}
      assert request.content_type == "application/json"
    end
  end

  describe "header blocklist" do
    test "hop-by-hop and framing headers never reach the transport request" do
      for name <- ["Host", "Content-Length", "Transfer-Encoding", "Connection", "Upgrade"] do
        assert {:error, %Error{code: :http_header_blocked, class: :validation}} =
                 build(%{
                   "method" => "get",
                   "url" => "https://example.test/hook",
                   "headers" => %{name => "x"}
                 })
      end
    end

    test "authorization without a secret is refused" do
      assert {:error, %Error{code: :http_header_needs_secret}} =
               build(%{
                 "method" => "get",
                 "url" => "https://example.test/hook",
                 "headers" => %{"Authorization" => "Bearer literal"}
               })
    end
  end

  describe "secret redaction" do
    test "plaintext is substituted into the wire body and omitted from diagnostics" do
      config =
        compiled(
          method: :post,
          url: "https://example.test/hook",
          body: "token={{ secret.API_TOKEN }}"
        )
        |> Map.put("body_mode", "text")

      assert {:ok, request} =
               build(config, %{}, secrets: %{"API_TOKEN" => @planted})

      assert request.body == "token=" <> @planted
      refute inspect(request) =~ @planted
      refute inspect(request.summary) =~ @planted
      refute Map.has_key?(request.summary, "body")
      assert request.summary["body_bytes"] == byte_size(request.body)
    end

    test "a JSON secret is escaped and still omitted from inspect" do
      config =
        compiled(
          method: :post,
          url: "https://example.test/hook",
          body: ~s({"token": {{ secret.API_TOKEN }}})
        )
        |> Map.put("body_mode", "json")

      assert {:ok, request} =
               build(config, %{}, secrets: %{"API_TOKEN" => ~s(p@ss"word)})

      assert Jason.decode!(request.body) == %{"token" => ~s(p@ss"word)}
      refute inspect(request) =~ ~s(p@ss"word)
    end

    test "a missing secret is permanent and skips URL policy" do
      config =
        compiled(
          method: :post,
          url: "https://example.test/hook",
          body: "token={{ secret.API_TOKEN }}"
        )
        |> Map.put("body_mode", "text")

      assert {:error, %Error{class: :not_found, code: :resource_not_found}} =
               build(config, %{}, secrets: %{}, dns_resolver: fn _ -> flunk("dns") end)
    end

    test "a stored secret is read only at the last moment" do
      %{installation: installation, member: member} = install()
      scope = Scope.new(member)

      secret =
        ConnectionsFixtures.secret(scope, %{name: "API_TOKEN", value: @planted})

      config =
        compiled(
          method: :post,
          url: "https://example.test/hook",
          body: "token={{ secret.API_TOKEN }}"
        )
        |> Map.put("body_mode", "text")

      assert {:ok, request} =
               build(config, %{}, installation_id: installation.id)

      assert request.body == "token=" <> @planted
      refute inspect(request) =~ @planted
      assert secret.value == nil
    end
  end

  describe "base-path escape" do
    test "a node path cannot climb out of the connection prefix" do
      connection = resolved()

      for escape <- ["../admin", "tickets/../../secret", "https://evil.test/x"] do
        assert {:error, %Error{class: :validation}} =
                 build(
                   %{
                     "method" => "get",
                     "url" => "https://api.example.test/v1",
                     "path" => escape
                   },
                   %{},
                   connection: connection
                 ),
               "#{escape} was accepted"
      end
    end

    test "a rendered URL on another origin is refused" do
      assert {:error, %Error{code: :origin_not_allowed}} =
               build(
                 %{
                   "method" => "get",
                   "url" => "https://evil.test/v1/tickets"
                 },
                 %{},
                 connection: resolved()
               )
    end

    test "a path under the prefix is joined to the connection origin" do
      assert {:ok, request} =
               build(
                 %{
                   "method" => "get",
                   "url" => "https://api.example.test/v1/tickets"
                 },
                 %{},
                 connection: resolved()
               )

      assert request.url == "https://api.example.test/v1/tickets"
      assert request.path == "/v1/tickets"
    end
  end

  describe "size boundaries" do
    test "a body over the template source cap is refused before policy" do
      over = String.duplicate("a", 16 * 1024 + 1)

      assert {:error, %Error{class: :validation, code: :template_too_large}} =
               build(
                 %{
                   "method" => "post",
                   "url" => "https://example.test/hook",
                   "body" => over,
                   "body_mode" => "text"
                 },
                 %{},
                 dns_resolver: fn _ -> flunk("dns") end
               )
    end

    test "a header value over the connection cap is refused" do
      value = String.duplicate("x", 1025)

      assert {:error, %Error{class: :validation, code: :value_too_long}} =
               build(%{
                 "method" => "get",
                 "url" => "https://example.test/hook",
                 "headers" => %{"x-note" => value}
               })
    end

    test "too many headers are refused" do
      headers =
        Map.new(1..21, fn index ->
          {"x-custom-#{index}", "v"}
        end)

      assert {:error, %Error{class: :validation}} =
               build(%{
                 "method" => "get",
                 "url" => "https://example.test/hook",
                 "headers" => headers
               })
    end

    test "transport-added headers are included in the final header cap" do
      headers = Map.new(1..20, fn index -> {"x-custom-#{index}", "v"} end)

      assert {:error, %Error{class: :validation, code: :http_header_invalid}} =
               build(
                 %{
                   "method" => "post",
                   "url" => "https://api.example.test/v1/hook",
                   "body" => "{}",
                   "body_mode" => "json"
                 },
                 %{},
                 connection: resolved(%{headers: headers})
               )
    end
  end

  describe "dry-run" do
    test "renders a redacted summary without resolving secrets or approving DNS" do
      config =
        compiled(
          method: :post,
          url: "https://example.test/hook",
          body: "token={{ secret.API_TOKEN }}"
        )
        |> Map.put("body_mode", "text")

      assert {:ok, request} =
               build(config, %{}, run_mode: "dry_run", dns_resolver: fn _ -> flunk("dns") end)

      assert request.target == nil
      assert request.summary["dry_run"] == true
      assert request.body == "token=" <> Templates.secret_placeholder("API_TOKEN")
      refute request.body =~ @planted
      refute inspect(request) =~ @planted
    end

    test "a stable effect key is copied onto a configured idempotency header" do
      assert {:ok, request} =
               build(
                 %{
                   "method" => "post",
                   "url" => "https://example.test/hook",
                   "body" => "{}",
                   "body_mode" => "json",
                   "idempotency_header" => "Idempotency-Key"
                 },
                 %{},
                 run_mode: "dry_run",
                 effect_key: "inst/exec/node"
               )

      assert {"idempotency-key", "inst/exec/node"} in request.headers
      assert request.summary["idempotency_header"] == "idempotency-key"
      assert request.summary["effect_key"] == "inst/exec/node"
      assert HttpRequest.transport_request(request).method == "POST"
    end
  end

  describe "templated host" do
    test "a host change is revalidated by URL policy" do
      config = compiled(method: :get, url: "https://{{ trigger.data.host }}/hook")

      assert {:ok, request} = build(config, %{"host" => "example.test"})
      assert request.target.hostname == "example.test"

      assert {:error, %Error{class: :validation}} =
               build(config, %{"host" => "localhost"})
    end
  end

  defp build(config, data \\ %{}, opts \\ []) do
    {build_opts, input_opts} =
      Keyword.split(opts, [
        :connection,
        :dns_resolver,
        :allow_http,
        :now,
        :secrets,
        :secrets_by_id
      ])

    build_opts = Keyword.put_new(build_opts, :dns_resolver, public_dns())
    HttpRequest.build(input(config, data, input_opts), build_opts)
  end

  defp input(config, data, opts) do
    %{
      compiled_node: %{
        type: :http_action,
        config: config,
        edges: %{"next" => "end"},
        requires: %{
          "connection_ids" => List.wrap(config["connection_id"]),
          "operations" => [],
          "scopes" => [],
          "secret_names" => []
        }
      },
      context: %{"execution" => %{"id" => "run-1", "run_mode" => "live"}, "steps" => %{}},
      trigger_snapshot: %{"data" => data},
      installation_id: Keyword.get(opts, :installation_id, Ecto.UUID.generate()),
      run_mode: Keyword.get(opts, :run_mode, "live"),
      effect_key: Keyword.get(opts, :effect_key, "inst/exec/node"),
      attempt: %{id: Ecto.UUID.generate(), number: 1}
    }
  end

  defp compiled(attrs) do
    node =
      Node.new(:http_action, Enum.into(attrs, %{method: :post, url: "https://example.test/hook"}))

    {:ok, compiled} = Compiler.compile(definition([node]))
    compiled.nodes[node.id].config
  end

  defp resolved(attrs \\ %{}) do
    struct!(
      ResolvedConnection,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          installation_id: Ecto.UUID.generate(),
          name: "Tickets",
          base_origin: "https://api.example.test",
          base_path_prefix: "/v1",
          policy_version: 1,
          headers: %{},
          secret_headers: []
        },
        attrs
      )
    )
  end

  defp public_dns, do: fn _host -> {:ok, [@public]} end
end
