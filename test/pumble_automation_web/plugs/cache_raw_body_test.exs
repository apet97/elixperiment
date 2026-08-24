defmodule PumbleAutomationWeb.Plugs.CacheRawBodyTest do
  @moduledoc """
  The body reader, at the two levels it has to be right at.

  Most of these tests call `read_body/2` directly with a `Plug.Test` connection,
  because that is the only way to hand it bytes that are not valid UTF-8 or to
  make it read in more than one chunk. The limit tests go through the endpoint
  instead, because `413` and `400` are properties of the whole stack: the reader
  raises, and Plug turns the exception into a status.

  Not async: two tests narrow the configured chunk size to force a chunked read.
  """

  use PumbleAutomationWeb.ConnCase, async: false

  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomationWeb.Plugs.CacheRawBody

  @secret "test-signing-secret"
  @timestamp "1767225600000"

  defmodule FailingAdapter do
    @moduledoc "An adapter whose body read always fails, as a dropped connection does."

    def read_req_body(_payload, _opts), do: {:error, :timeout}
  end

  describe "which requests it touches" do
    test "a callback path keeps its raw bytes" do
      body = ~s({"a":1})
      conn = build_raw_conn("/pumble/callbacks", body)

      assert {:ok, ^body, conn} = CacheRawBody.read_body(conn, [])
      assert conn.private[:raw_body] == body
    end

    test "any other path reads normally and keeps nothing" do
      body = "a=1&b=2"
      conn = build_raw_conn("/oauth/callback", body)

      assert {:ok, ^body, conn} = CacheRawBody.read_body(conn, [])
      refute Map.has_key?(conn.private, :raw_body)
    end

    test "an ordinary route still serves its request", %{conn: conn} do
      assert html_response(get(conn, ~p"/"), 200)
    end
  end

  describe "byte fidelity" do
    test "a body that is not valid UTF-8 survives byte for byte" do
      body = <<0xFF, 0xFE, 0x00, 0x80, "text", 0x00>>
      conn = build_raw_conn("/pumble/callbacks", body)

      assert {:ok, read, conn} = CacheRawBody.read_body(conn, [])
      assert read == body
      assert conn.private[:raw_body] == body
      refute String.valid?(conn.private[:raw_body])
    end

    test "a body read in several chunks is reassembled in order" do
      narrow_reads(8)

      body = "0123456789abcdefghijklmnopqrstuvwxyz"
      conn = build_raw_conn("/pumble/callbacks", body)

      assert {:ok, ^body, conn} = CacheRawBody.read_body(conn, [])
      assert conn.private[:raw_body] == body
    end

    test "the chunked read produces the same bytes as a single read" do
      body = String.duplicate("chunk-", 100)

      single =
        "/pumble/callbacks" |> build_raw_conn(body) |> CacheRawBody.read_body([]) |> elem(1)

      narrow_reads(7)

      chunked =
        "/pumble/callbacks" |> build_raw_conn(body) |> CacheRawBody.read_body([]) |> elem(1)

      assert single == chunked
    end

    test "JSON that differs only in whitespace produces different bytes and signatures" do
      compact = ~s({"a":1,"b":2})
      spaced = ~s({"a": 1, "b": 2})

      assert Jason.decode!(compact) == Jason.decode!(spaced),
             "the two bodies must be the same document, or the test proves nothing"

      raw_compact = raw_bytes_of(compact)
      raw_spaced = raw_bytes_of(spaced)

      assert raw_compact == compact
      assert raw_spaced == spaced
      refute raw_compact == raw_spaced

      refute Signature.compute(@secret, @timestamp, raw_compact) ==
               Signature.compute(@secret, @timestamp, raw_spaced)
    end
  end

  describe "limits" do
    test "a body of exactly the limit is accepted", %{conn: conn} do
      body = json_of_size(CacheRawBody.max_body_bytes())
      assert byte_size(body) == CacheRawBody.max_body_bytes()

      conn = post_signed(conn, body)

      # The reader accepted the body and the controller received it: the padded
      # envelope is not a callback any class recognizes, so the answer is the
      # documented refusal for an unclassifiable body. A `413` here would mean
      # the size limit fired one byte early, which is what this test guards.
      assert conn.status == 400
      assert byte_size(conn.private[:raw_body]) == CacheRawBody.max_body_bytes()
    end

    test "one byte over the limit is refused with 413", %{conn: conn} do
      body = json_of_size(CacheRawBody.max_body_bytes() + 1)
      assert byte_size(body) == CacheRawBody.max_body_bytes() + 1

      assert_error_sent(413, fn -> post_signed(conn, body) end)
    end

    test "the limit is enforced while the body arrives, not after", %{conn: conn} do
      narrow_reads(1_024)

      assert_error_sent(413, fn ->
        post_signed(conn, json_of_size(CacheRawBody.max_body_bytes() + 512))
      end)
    end
  end

  describe "unreadable bodies" do
    test "a failed read raises a 400 rather than yielding a short body" do
      conn = %{build_raw_conn("/pumble/callbacks", "") | adapter: {FailingAdapter, :state}}

      error = assert_raise(Plug.BadRequestError, fn -> CacheRawBody.read_body(conn, []) end)

      assert Plug.Exception.status(error) == 400
    end
  end

  defp build_raw_conn(path, body) do
    :post
    |> Plug.Test.conn(path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp raw_bytes_of(body) do
    {:ok, _read, conn} = "/pumble/callbacks" |> build_raw_conn(body) |> CacheRawBody.read_body([])
    conn.private[:raw_body]
  end

  # A JSON document of an exact byte size, so the boundary test asserts on the
  # boundary rather than on whatever a generated string happened to weigh.
  defp json_of_size(bytes) do
    envelope = ~s({"pad":""})
    padding = bytes - byte_size(envelope)

    ~s({"pad":"#{String.duplicate("x", padding)}"})
  end

  defp post_signed(conn, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-pumble-request-timestamp", @timestamp)
    |> Plug.Conn.put_req_header(
      "x-pumble-request-signature",
      Signature.compute(@secret, @timestamp, body)
    )
    |> post(~p"/pumble/callbacks", body)
  end

  defp narrow_reads(bytes) do
    settings = Application.fetch_env!(:pumble_automation, :pumble_callbacks)
    on_exit(fn -> Application.put_env(:pumble_automation, :pumble_callbacks, settings) end)

    Application.put_env(
      :pumble_automation,
      :pumble_callbacks,
      Keyword.put(settings, :read_length, bytes)
    )
  end
end
