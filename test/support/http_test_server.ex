defmodule PumbleAutomation.HttpTestServer do
  @moduledoc """
  A local HTTP, HTTPS, or raw-TCP listener for SafeHttp transport tests.

  The process is started with `start_supervised!/1`. HTTP and HTTPS are Bandit
  servers on a chosen loopback address. `:tcp` accepts connections and holds
  them without speaking HTTP or TLS, which is how connect-phase timeouts are
  produced. Certificates are fixtures for `http.test.local`; they are not
  trusted outside these tests.
  """

  use GenServer

  @hostname "http.test.local"

  @cert_pem """
  -----BEGIN CERTIFICATE-----
  MIIDNTCCAh2gAwIBAgIUGFfAfAXxsP2KAYKatinIiFUt6QEwDQYJKoZIhvcNAQEL
  BQAwGjEYMBYGA1UEAwwPaHR0cC50ZXN0LmxvY2FsMB4XDTI2MDgxODE5MjcxM1oX
  DTM2MDgxNTE5MjcxM1owGjEYMBYGA1UEAwwPaHR0cC50ZXN0LmxvY2FsMIIBIjAN
  BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwNn64DqBmxnSv8+grsh+F8jHWnX4
  W8ELda6XvemcnB3fCKVkKcZJqiitrrUZ0etE4pIOb1XYRu5VyoUtqoQsSGDQ0fiX
  e9qh0FDGO1XzuO6k5kusdRjygdGsUvIq8q+brnmFhzgd4k2P9sfpLQ2NEJicPChR
  qKSovv5+w3PmFf07Wd3x26mDOTrcZUlHtUoGl130PY+65EwZSZIXru5PrmhzKL2v
  7as7LxWLoKo27oHxk/0YgXslQ4JFjhghOET9JfM6KK0h00qFW5Y2Fh4zVKL5ARE4
  t5RqkpOi1sD3JANK0RH45oblGqS+WwGSxzTlP6Eer4naLrxSNAPHsGnP+QIDAQAB
  o3MwcTAaBgNVHREEEzARgg9odHRwLnRlc3QubG9jYWwwDgYDVR0PAQH/BAQDAgKk
  MBMGA1UdJQQMMAoGCCsGAQUFBwMBMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYE
  FKcMBzTGqYurMc/4aVqrRqQqosnwMA0GCSqGSIb3DQEBCwUAA4IBAQAmkw5ZmVOb
  u1Ldffj/OxekEg+mf1LMTMJKFNgYHXEhaLvQWv2r6o8fSb042fd9HNHz4MdTAi1o
  DUTxWVubUhWe5IY3cLf1Lil4or11N5My35Zv9jK4G2lDxvsOoPWEVqkX6xA1SjZl
  GnRaUklELBc0U5Hu+nFIwjElYg4/ehI0YlF+MjLQ4zcmdg+Alu4GvNVI5AvrwPhb
  Areqk1a6xOmpgHhczFAQ2DGqOR54fxnmcHM7PX2Q8JizCC05lv6wcSmWEb9Du02m
  znWqQvKKm/n7MylvsqrFfP9SlEaap8I/rPIcG0CbQTh432uLvr3SMIbviScKErOA
  nbVocR8XXL0n
  -----END CERTIFICATE-----
  """

  @key_pem """
  -----BEGIN PRIVATE KEY-----
  MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDA2frgOoGbGdK/
  z6CuyH4XyMdadfhbwQt1rpe96ZycHd8IpWQpxkmqKK2utRnR60Tikg5vVdhG7lXK
  hS2qhCxIYNDR+Jd72qHQUMY7VfO47qTmS6x1GPKB0axS8iryr5uueYWHOB3iTY/2
  x+ktDY0QmJw8KFGopKi+/n7Dc+YV/TtZ3fHbqYM5OtxlSUe1SgaXXfQ9j7rkTBlJ
  kheu7k+uaHMova/tqzsvFYugqjbugfGT/RiBeyVDgkWOGCE4RP0l8zoorSHTSoVb
  ljYWHjNUovkBETi3lGqSk6LWwPckA0rREfjmhuUapL5bAZLHNOU/oR6vidouvFI0
  A8ewac/5AgMBAAECggEAFblYW+LrT6P4jBfg819taNN6tXN9jyRvXInW2RNUS3fH
  9Irg/h2ylaLwcbI/3thAUb9/NcZ3TwIxEteuvbsW2+5gB48XzWFjAfrfYba8djQX
  ykNzAVvWkY4jedKCyQTEJkLVKlbFcwUmtvdtCmCw59IxI0utazBlO+KiN/U50Xcb
  QHLcprUGXq8/YqLIxvIFLpekRqXS0xCubx+OJSdqD0TroMPLLeFTdGeP/YxDoz8r
  LYj0qJn/njswuKINsyah9+oTARr4ooFi5dkplHWNk35aRZWZ2tiE2G2qXP4a/cDI
  uWWtsjxoQLrsotIvuz8OZXAZ0dmeb75BmJMsnPHJAQKBgQD78fmfKHY1G7RDgGXd
  /6OZXAQFFfW6pUErmaqfxONYpgROnWZVSp5IUdKeAKPlXE34hqF+YO5EgBJDTCdV
  4nP051rPOpfbs4BD9GMTEtmZFarOPDD5GI0zdFnzXxoPtyK5v94hFXLABeXv3A9U
  mdAQ6w/RHDfiMMVe9HEw5KrbOQKBgQDD9IlGsxKr+kXe9lMk2elZHZH55PePNFPR
  lqj0XH2q8ioHQOSuM5UcsZF94DymgtSmRaaQ75TdAqjc3XAzr/bTV/6YWaIoGFV3
  0eXGmGy9TWooPWYeoNXzWC/YMIgGaeuPWCvqi4f7f8BNZ1rgsQiaIDkuTINAZs17
  iIFmeEzawQKBgQC32NAtqunvQSMeqsAq6hOoojOwvmCM7XAL79tJMPQxSRwVfdgh
  3wx3e3W0pIT0ppGjDCMmRHc59zbccuK1UkUJbhWe6IPN50Nu0xPE5Fly0xPL4LJf
  4uGOrZXB+SDcXOfzIaZm/+63XtZ2XF+3fXIOFml5Tx0cajhsXPWIFyTySQKBgA75
  UMQmSvb5WP2AtTnLrRkyOUVvSbuXtBAAA0kpCDFX7/495zuolWxr5UJJMFlJBhbu
  m5vXsvhwi5bVFQ3eFG5x+vKJZurJcT6Gu5hBbY3JrKMGjhcpEzBVPNK4Yqyay3VY
  t4Jkxy9gw8EmdLtWy+F7NONk1WLGeE1IURsTdkwBAoGBANR1+aUQdhN1D1b+EsDi
  z1XwsXT8TnId5Tb+FFs8U5xIG0dfxvhgGf/FZ3WUPdG4Z81/EKdtKuFTJmcJYD5f
  6tEz1o0Zg/8B/+lrOFmNMwngfdWqxZ9r8/fxAtqASR4PvdvVXnWinxJ2PnHIUaXO
  DpTz0iLhYw3Nso7oXvjxRIwa
  -----END PRIVATE KEY-----
  """

  defstruct [:mode, :ip, :port, :pid, :listen, :dir, :cacerts, :counter]

  @type t :: %__MODULE__{
          mode: :http | :https | :tcp,
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          pid: pid() | nil,
          listen: :gen_tcp.socket() | nil,
          dir: String.t() | nil,
          cacerts: [binary()],
          counter: :counters.counters_ref()
        }

  @doc "The hostname the bundled certificate is issued to."
  @spec hostname() :: String.t()
  def hostname, do: @hostname

  @doc "A gzip payload whose decompressed size is `plain_bytes`."
  @spec gzip_bomb(pos_integer()) :: binary()
  def gzip_bomb(plain_bytes) when is_integer(plain_bytes) and plain_bytes > 0 do
    :zlib.gzip(:binary.copy("A", plain_bytes))
  end

  @doc "Accepted TCP connections or dispatched HTTP requests since start."
  @spec request_count(pid()) :: non_neg_integer()
  def request_count(pid) do
    info(pid).request_count
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :id, :default)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Bound address, port, scheme, and trust material for the client."
  @spec info(pid()) :: map()
  def info(pid), do: GenServer.call(pid, :info)

  @impl true
  def init(opts) do
    mode = Keyword.get(opts, :mode, :http)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    handler = Keyword.get(opts, :handler, &default_handler/1)

    start_mode(mode, ip, handler)
  end

  @impl true
  def handle_call(:info, _from, state) do
    scheme =
      case state.mode do
        :https -> :https
        _other -> :http
      end

    {:reply,
     %{
       ip: state.ip,
       port: state.port,
       scheme: scheme,
       hostname: @hostname,
       cacerts: state.cacerts,
       certfile: if(state.dir, do: Path.join(state.dir, "cert.pem")),
       request_count: :counters.get(state.counter, 1)
     }, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_listener(state)
    if is_binary(state.dir), do: File.rm_rf(state.dir)
    :ok
  end

  defp start_mode(:tcp, ip, _handler) do
    counter = :counters.new(1, [:atomics])

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ip, ip},
        {:active, false},
        {:reuseaddr, true},
        {:backlog, 16} | tcp_family(ip)
      ])

    {:ok, port} = :inet.port(listen)
    acceptor = spawn(fn -> accept_loop(listen, counter) end)

    {:ok,
     %__MODULE__{
       mode: :tcp,
       ip: ip,
       port: port,
       pid: acceptor,
       listen: listen,
       dir: nil,
       cacerts: [],
       counter: counter
     }}
  end

  defp start_mode(mode, ip, handler) when mode in [:http, :https] do
    counter = :counters.new(1, [:atomics])
    {dir, tls_files, cacerts} = maybe_tls_files(mode)

    plug = fn conn, _opts ->
      :counters.add(counter, 1, 1)
      dispatch(conn, handler)
    end

    bandit_opts =
      [
        plug: plug,
        scheme: mode,
        port: 0,
        ip: ip,
        startup_log: false,
        http_2_options: [enabled: false]
      ] ++ tls_bandit_opts(tls_files) ++ family_opt(ip)

    case Bandit.start_link(bandit_opts) do
      {:ok, pid} ->
        {:ok, {bound_ip, port}} = ThousandIsland.listener_info(pid)

        {:ok,
         %__MODULE__{
           mode: mode,
           ip: bound_ip,
           port: port,
           pid: pid,
           listen: nil,
           dir: dir,
           cacerts: cacerts,
           counter: counter
         }}

      {:error, reason} ->
        if is_binary(dir), do: File.rm_rf(dir)
        {:stop, reason}
    end
  end

  defp tls_bandit_opts(nil), do: []

  defp tls_bandit_opts(%{certfile: certfile, keyfile: keyfile}) do
    [certfile: certfile, keyfile: keyfile]
  end

  defp maybe_tls_files(:http), do: {nil, nil, []}

  defp maybe_tls_files(:https) do
    dir = Path.join(System.tmp_dir!(), "pumble-http-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    certfile = Path.join(dir, "cert.pem")
    keyfile = Path.join(dir, "key.pem")
    File.write!(certfile, @cert_pem)
    File.write!(keyfile, @key_pem)

    cacerts =
      for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(@cert_pem), do: der

    {dir, %{certfile: certfile, keyfile: keyfile}, cacerts}
  end

  defp family_opt({_, _, _, _}), do: []
  defp family_opt({_, _, _, _, _, _, _, _}), do: [:inet6]

  defp tcp_family({_, _, _, _}), do: [:inet]
  defp tcp_family({_, _, _, _, _, _, _, _}), do: [:inet6]

  defp dispatch(conn, handler), do: handler.(conn)

  defp default_handler(conn) do
    body = conn.method <> " " <> conn.request_path

    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, body)
  end

  defp accept_loop(listen, counter) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        :counters.add(counter, 1, 1)
        spawn(fn -> hold_socket(socket) end)
        accept_loop(listen, counter)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen, counter)
    end
  end

  defp hold_socket(socket) do
    receive do
      :release -> :gen_tcp.close(socket)
    after
      60_000 -> :gen_tcp.close(socket)
    end
  end

  defp stop_listener(%__MODULE__{mode: :tcp, listen: listen}) when listen != nil do
    :gen_tcp.close(listen)
    :ok
  end

  defp stop_listener(%__MODULE__{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    :ok
  end

  defp stop_listener(_state), do: :ok
end
