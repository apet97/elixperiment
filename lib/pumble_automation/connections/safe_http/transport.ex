defmodule PumbleAutomation.Connections.SafeHttp.Transport do
  @moduledoc """
  Mint adapter that opens one socket to an IP tuple.

  The hostname is never the connect address. It is used for SNI, certificate
  verification, and the HTTP Host header. There is no proxy, no redirect, and
  no second connect to the name after a pinned-IP failure.
  """

  alias Mint.HTTP
  alias Mint.HTTPError
  alias Mint.TransportError

  @type scheme :: :http | :https
  @type connect_opts :: keyword()
  @type exchange_opts :: [
          {:deadline, integer()}
          | {:max_body_bytes, pos_integer()}
          | {:max_header_bytes, pos_integer()}
        ]

  @type response :: %{
          status: 100..599,
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type error :: %{
          reason: term(),
          phase: :request | :response,
          request_written?: boolean()
        }

  @doc """
  Connects to `address` and uses `hostname` for TLS identity.

  `address` must be an IPv4 or IPv6 tuple. Passing a hostname here would
  re-open DNS, which is the rebinding window this transport exists to close.
  """
  @spec connect(scheme(), :inet.ip_address(), :inet.port_number(), String.t(), connect_opts()) ::
          {:ok, HTTP.t()} | {:error, term()}
  def connect(scheme, address, port, hostname, opts \\ [])

  def connect(scheme, address, port, hostname, opts)
      when scheme in [:http, :https] and is_tuple(address) and is_integer(port) and
             is_binary(hostname) and is_list(opts) do
    mint_opts = [
      hostname: hostname,
      protocols: [:http1],
      mode: :active,
      max_header_list_size: Keyword.get(opts, :max_header_bytes, 16_384),
      transport_opts: transport_opts(scheme, address, hostname, opts)
    ]

    # Mint accepts IP tuples at runtime, but Dialyzer's success typing only
    # admits a hostname binary. A dotted or colon IP string is parsed as that
    # address and does not trigger DNS, so the socket still lands on `address`.
    HTTP.connect(scheme, mint_host(address), port, mint_opts)
  end

  def connect(_scheme, _address, _port, _hostname, _opts) do
    {:error, :invalid_connect}
  end

  @doc """
  Sends one request, streams the response up to the caps, and closes.
  """
  @spec exchange(
          HTTP.t(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          iodata() | nil,
          exchange_opts()
        ) ::
          {:ok, response()} | {:error, error()}
  def exchange(conn, method, path, headers, body, opts) do
    deadline = Keyword.fetch!(opts, :deadline)
    max_body = Keyword.fetch!(opts, :max_body_bytes)
    max_header = Keyword.get(opts, :max_header_bytes, 16_384)

    case HTTP.request(conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        acc = empty_acc(ref, max_body, max_header)
        finish(await(conn, acc, deadline))

      {:error, conn, reason} ->
        close(conn)
        {:error, %{reason: reason, phase: :request, request_written?: true}}
    end
  end

  defp mint_host(address) when is_tuple(address) do
    address |> :inet.ntoa() |> List.to_string()
  end

  defp transport_opts(scheme, address, hostname, opts) do
    user = Keyword.get(opts, :transport_opts, [])
    timeout = Keyword.get(opts, :connect_timeout_ms, 5_000)

    [timeout: timeout] ++ family_opts(address) ++ tls_opts(scheme, hostname, user)
  end

  defp family_opts({_, _, _, _}), do: [inet4: true, inet6: false]
  defp family_opts({_, _, _, _, _, _, _, _}), do: [inet6: true, inet4: false]

  defp tls_opts(:http, _hostname, _user), do: []

  defp tls_opts(:https, hostname, user) do
    [
      verify: :verify_peer,
      depth: 3,
      versions: [:"tlsv1.2", :"tlsv1.3"],
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ] ++ trust_store(hostname, user)
  end

  # An explicit cacerts list is a private trust store (tests). OTP 26+ rejects a
  # self-signed leaf as `:selfsigned_peer` even when that leaf is the trust
  # anchor, so the verify fun allows that one class and still checks the name.
  defp trust_store(hostname, user) do
    cond do
      Keyword.has_key?(user, :cacerts) ->
        cacerts = Keyword.fetch!(user, :cacerts)

        [
          cacerts: cacerts,
          verify_fun: {&verify_custom_ca/3, hostname}
        ]

      Keyword.has_key?(user, :cacertfile) ->
        [cacertfile: Keyword.fetch!(user, :cacertfile)]

      true ->
        [cacerts: :public_key.cacerts_get()]
    end
  end

  defp verify_custom_ca(cert, {:bad_cert, :selfsigned_peer}, hostname) do
    verify_hostname(cert, hostname)
  end

  defp verify_custom_ca(_cert, {:bad_cert, reason}, _hostname) do
    {:fail, reason}
  end

  defp verify_custom_ca(_cert, {:extension, _extension}, hostname) do
    {:unknown, hostname}
  end

  defp verify_custom_ca(_cert, :valid, hostname) do
    {:valid, hostname}
  end

  defp verify_custom_ca(cert, :valid_peer, hostname) do
    verify_hostname(cert, hostname)
  end

  defp verify_hostname(cert, hostname) do
    ids = [dns_id: String.to_charlist(hostname)]

    if :public_key.pkix_verify_hostname(
         cert,
         ids,
         match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
       ) do
      {:valid, hostname}
    else
      {:fail, {:bad_cert, :hostname_check_failed}}
    end
  end

  defp empty_acc(ref, max_body, max_header) do
    %{
      ref: ref,
      status: nil,
      headers: [],
      body: [],
      body_bytes: 0,
      header_bytes: 0,
      max_body: max_body,
      max_header: max_header
    }
  end

  defp await(conn, acc, deadline) do
    remaining = remaining_ms(deadline)

    receive do
      message ->
        stream_message(conn, acc, deadline, message)
    after
      remaining ->
        close(conn)
        {:error, :timeout, conn}
    end
  end

  defp stream_message(conn, acc, deadline, message) do
    case HTTP.stream(conn, message) do
      :unknown ->
        await(conn, acc, deadline)

      {:ok, conn, responses} ->
        consume(conn, acc, deadline, responses)

      {:error, conn, error, responses} ->
        _ = apply_many(responses, acc)
        close(conn)
        {:error, error, conn}
    end
  end

  defp consume(conn, acc, deadline, responses) do
    case apply_many(responses, acc) do
      {:ok, %{done?: true} = acc} ->
        {:ok, acc, conn}

      {:ok, acc} ->
        await(conn, acc, deadline)

      {:error, reason} ->
        close(conn)
        {:error, reason, conn}
    end
  end

  defp apply_many(responses, acc) do
    Enum.reduce_while(responses, {:ok, acc}, fn response, {:ok, acc} ->
      case apply_response(response, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_response({:status, ref, status}, %{ref: ref} = acc) do
    {:ok, Map.put(acc, :status, status)}
  end

  defp apply_response({:headers, ref, headers}, %{ref: ref} = acc) do
    bytes = acc.header_bytes + header_bytes(headers)

    cond do
      bytes > acc.max_header ->
        {:error, :headers_too_large}

      compressed?(headers) ->
        {:error, :compressed}

      true ->
        {:ok, %{acc | headers: acc.headers ++ headers, header_bytes: bytes}}
    end
  end

  defp apply_response({:data, ref, chunk}, %{ref: ref} = acc) do
    size = acc.body_bytes + byte_size(chunk)

    if size > acc.max_body do
      {:error, :body_too_large}
    else
      {:ok, %{acc | body: [chunk | acc.body], body_bytes: size}}
    end
  end

  defp apply_response({:done, ref}, %{ref: ref} = acc) do
    {:ok, Map.put(acc, :done?, true)}
  end

  defp apply_response(_other, acc), do: {:ok, acc}

  defp header_bytes(headers) do
    Enum.reduce(headers, 0, fn {name, value}, acc ->
      acc + byte_size(name) + byte_size(value) + 4
    end)
  end

  defp compressed?(headers) do
    Enum.any?(headers, fn {name, value} ->
      compressed_header?(String.downcase(name), String.downcase(value))
    end)
  end

  defp compressed_header?("content-encoding", value), do: not identity_tokens?(value)
  defp compressed_header?("transfer-encoding", value), do: compressed_transfer?(value)
  defp compressed_header?(_name, _value), do: false

  defp compressed_transfer?(value) do
    value
    |> tokens()
    |> Enum.any?(&(&1 not in ["chunked", "identity"]))
  end

  defp identity_tokens?(value), do: Enum.all?(tokens(value), &(&1 == "identity"))

  defp tokens(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp finish({:ok, acc, conn}) do
    close(conn)

    {:ok,
     %{
       status: acc.status,
       headers: acc.headers,
       body: acc.body |> Enum.reverse() |> IO.iodata_to_binary()
     }}
  end

  defp finish({:error, :timeout, _conn}) do
    {:error, %{reason: :timeout, phase: :response, request_written?: true}}
  end

  defp finish({:error, :body_too_large, _conn}) do
    {:error, %{reason: :body_too_large, phase: :response, request_written?: true}}
  end

  defp finish({:error, :headers_too_large, _conn}) do
    {:error, %{reason: :headers_too_large, phase: :response, request_written?: true}}
  end

  defp finish({:error, :compressed, _conn}) do
    {:error, %{reason: :compressed, phase: :response, request_written?: true}}
  end

  defp finish({:error, %TransportError{} = error, _conn}) do
    {:error, %{reason: error, phase: :response, request_written?: true}}
  end

  defp finish({:error, %HTTPError{} = error, _conn}) do
    {:error, %{reason: error, phase: :response, request_written?: true}}
  end

  defp finish({:error, reason, _conn}) do
    {:error, %{reason: reason, phase: :response, request_written?: true}}
  end

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp close(conn) do
    _ = HTTP.close(conn)
    :ok
  end
end
