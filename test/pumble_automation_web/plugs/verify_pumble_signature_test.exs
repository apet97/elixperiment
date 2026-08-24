defmodule PumbleAutomationWeb.Plugs.VerifyPumbleSignatureTest do
  @moduledoc """
  The callback route, exercised through the real endpoint and the real router.

  Every request here goes through `POST /pumble/callbacks`, so each test also
  asserts that the route is behind both plugs: the raw bytes exist because the
  body reader ran, and the request is refused unless the signature over those
  bytes is right.

  Not async: two tests change application configuration, one to remove the
  signing secret and one to lower the log level.
  """

  use PumbleAutomationWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomationWeb.Plugs.VerifyPumbleSignature

  @secret "test-signing-secret"

  setup do
    fixture = PumbleFake.fixture("signatures/valid.json")

    # The fixture proves the scheme under its own fake secret; the route runs
    # under the secret `config/test.exs` sets, so the body is re-signed with it.
    %{
      body: fixture["body"],
      timestamp: fixture["timestamp"],
      signature: Signature.compute(@secret, fixture["timestamp"], fixture["body"])
    }
  end

  describe "an authentic callback" do
    test "reaches the callback action", context do
      conn = post_callback(context)

      # The stored fixture body is a signature fixture, not a callback envelope,
      # so the action answers the documented refusal for a body it cannot
      # classify. What matters here is that it got that far: an authentic
      # request is answered by the controller, not by the plug's generic 401.
      assert json_response(conn, 400) == %{"message" => "This callback could not be processed."}
      assert conn.private[:pumble_signature_verified]
    end

    test "the verified bytes are the bytes that were sent", context do
      conn = post_callback(context)

      assert conn.private[:raw_body] == context.body
    end

    test "the stored valid fixture verifies under its own secret", %{body: body} do
      fixture = PumbleFake.fixture("signatures/valid.json")

      assert Signature.valid?(
               fixture["signing_secret"],
               fixture["timestamp"],
               body,
               fixture["signature"]
             )
    end
  end

  describe "a callback that is not authentic" do
    test "a wrong signature is refused", context do
      fixture = PumbleFake.fixture("signatures/invalid.json")

      conn = post_callback(%{context | signature: fixture["signature"]})

      assert_generic_401(conn)
    end

    test "a missing signature header is refused", context do
      conn = post_callback(context, drop: ["x-pumble-request-signature"])

      assert_generic_401(conn)
    end

    test "a missing timestamp header is refused", context do
      conn = post_callback(context, drop: ["x-pumble-request-timestamp"])

      assert_generic_401(conn)
    end

    test "both headers missing is refused", context do
      conn =
        post_callback(context,
          drop: ["x-pumble-request-signature", "x-pumble-request-timestamp"]
        )

      assert_generic_401(conn)
    end

    test "a malformed or wrong-length signature is refused", context do
      for candidate <- [
            "",
            "not-hex",
            String.slice(context.signature, 0, 10),
            "zz" <> context.signature
          ] do
        conn = post_callback(%{context | signature: candidate})

        assert_generic_401(conn)
      end
    end

    test "a repeated signature header is refused", context do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-pumble-request-timestamp", context.timestamp)
        |> then(fn conn ->
          %{
            conn
            | req_headers:
                conn.req_headers ++
                  [
                    {"x-pumble-request-signature", context.signature},
                    {"x-pumble-request-signature", context.signature}
                  ]
          }
        end)
        |> post(~p"/pumble/callbacks", context.body)

      assert_generic_401(conn)
    end

    test "a body changed only in whitespace is refused", context do
      spaced = String.replace(context.body, ",", ", ")

      assert Jason.decode!(spaced) == Jason.decode!(context.body)

      conn = post_callback(%{context | body: spaced})

      assert_generic_401(conn)
    end

    test "a changed timestamp is refused", context do
      conn = post_callback(%{context | timestamp: context.timestamp <> "9"})

      assert_generic_401(conn)
    end

    test "a signature for another body is refused", context do
      other = Signature.compute(@secret, context.timestamp, ~s({"type":"OTHER"}))

      conn = post_callback(%{context | signature: other})

      assert_generic_401(conn)
    end

    test "a content type this application does not parse leaves no raw body and is refused",
         context do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
        |> Plug.Conn.put_req_header("x-pumble-request-timestamp", context.timestamp)
        |> Plug.Conn.put_req_header("x-pumble-request-signature", context.signature)
        |> post(~p"/pumble/callbacks", context.body)

      assert_generic_401(conn)
      refute conn.private[:pumble_signature_verified]
    end
  end

  describe "no bypass" do
    test "an absent signing secret refuses every callback rather than accepting one", context do
      pumble = Application.fetch_env!(:pumble_automation, :pumble)
      on_exit(fn -> Application.put_env(:pumble_automation, :pumble, pumble) end)

      Application.put_env(
        :pumble_automation,
        :pumble,
        Keyword.delete(pumble, :signing_secret)
      )

      assert_generic_401(post_callback(context))
    end
  end

  describe "redaction" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      :ok
    end

    test "neither signature header nor the callback body reaches a log line", context do
      log =
        capture_log(fn ->
          assert post_callback(context).status == 400

          assert_generic_401(
            post_callback(%{context | signature: String.reverse(context.signature)})
          )
        end)

      refute log =~ context.signature
      refute log =~ context.timestamp
      refute log =~ "U_FAKE001"
      refute log =~ @secret
    end

    test "the header names are the documented ones" do
      assert VerifyPumbleSignature.signature_header() == "x-pumble-request-signature"
      assert VerifyPumbleSignature.timestamp_header() == "x-pumble-request-timestamp"
    end
  end

  defp post_callback(context, opts \\ []) do
    drop = Keyword.get(opts, :drop, [])

    headers =
      [
        {"content-type", "application/json"},
        {"x-pumble-request-timestamp", context.timestamp},
        {"x-pumble-request-signature", context.signature}
      ]
      |> Enum.reject(fn {name, _value} -> name in drop end)

    Enum.reduce(headers, build_conn(), fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
    |> post(~p"/pumble/callbacks", context.body)
  end

  # One status, one body, no detail. A caller must not be able to tell a missing
  # header from a wrong signature from an unconfigured secret.
  defp assert_generic_401(conn) do
    assert conn.status == 401
    assert conn.resp_body == "unauthorized"
    assert conn.halted
    refute conn.private[:pumble_signature_verified]
  end
end
