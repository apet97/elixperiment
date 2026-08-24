defmodule PumbleAutomation.Connections.UrlPolicy do
  @moduledoc """
  Parses a user-supplied URL and returns an approved, short-lived target.

  This is steps 1–6 of the Section 26 SSRF algorithm: render-safe parsing,
  scheme and port checks, IDNA normalisation, DNS through an injectable
  resolver, and classification of every A/AAAA result. Connecting to a
  validated IP is `P10-T02`. Redirects re-enter this function; nothing here
  is cached across calls.

  ## What an approved target is

  The struct carries the original hostname (ASCII / A-label, for SNI, the
  certificate, and the Host header), the scheme, the port, the validated IP
  set, and an expiry. The transport must not use a target after `expired?/2`.
  It must not replace the hostname with an IP: that would skip certificate
  verification for the name the user wrote.

  ## HTTPS by default

  A URL without a scheme is treated as HTTPS. HTTP is refused unless the
  caller passes `allow_http: true`, which is the explicit deployment/product
  decision Section 26 requires. There is no reading of `HTTP_PROXY`,
  `HTTPS_PROXY`, or `NO_PROXY`. A `:proxy` option is a permanent refusal:
  workflow calls do not honour OS or user proxy configuration.
  """

  alias PumbleAutomation.Connections.IpPolicy
  alias PumbleAutomation.Error

  @enforce_keys [:scheme, :hostname, :port, :addresses, :expires_at]
  defstruct [:scheme, :hostname, :port, :addresses, :expires_at]

  @type t :: %__MODULE__{
          scheme: String.t(),
          hostname: String.t(),
          port: pos_integer(),
          addresses: [:inet.ip_address()],
          expires_at: DateTime.t()
        }

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  @ttl_ms 10_000
  @max_host_length 253
  @max_label_length 63

  @blocked_names MapSet.new([
                   "localhost",
                   "localhost.localdomain",
                   "ip6-localhost",
                   "ip6-loopback",
                   "metadata",
                   "metadata.google.internal",
                   "metadata.goog",
                   "instance-data",
                   "kubernetes",
                   "kubernetes.default",
                   "kubernetes.default.svc",
                   "kubernetes.default.svc.cluster.local"
                 ])

  @puny_base 36
  @puny_tmin 1
  @puny_tmax 26
  @puny_skew 38
  @puny_damp 700
  @puny_initial_bias 72
  @puny_initial_n 128

  @doc "How long an approved target remains usable, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  Returns whether `target` should be discarded at `now`.

  Callers re-run `approve/2` for every attempt and every redirect; they do
  not refresh a pin in place.
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, now \\ DateTime.utc_now()) do
    DateTime.compare(now, expires_at) != :lt
  end

  @doc """
  The production DNS resolver: A and AAAA via the OS.

  One family succeeding is enough when the other is absent. An empty
  combined set is treated as NXDOMAIN. Tests inject a function of this
  same shape and never call this one.
  """
  @spec default_resolver(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, atom()}
  def default_resolver(hostname) when is_binary(hostname) do
    host = String.to_charlist(hostname)

    case {:inet.getaddrs(host, :inet), :inet.getaddrs(host, :inet6)} do
      {{:ok, v4}, {:ok, v6}} -> nonempty(v4 ++ v6)
      {{:ok, v4}, {:error, _}} -> nonempty(v4)
      {{:error, _}, {:ok, v6}} -> nonempty(v6)
      {{:error, reason}, {:error, _}} -> {:error, reason}
    end
  end

  @doc """
  Approves `url` for outbound workflow HTTP, or returns a typed error.

  Options:

    * `:resolver` — `(hostname -> {:ok, addresses} | {:error, reason})`
    * `:allow_http` — when true, `http://` is accepted (HTTPS remains default)
    * `:now` and `:ttl_ms` — control the pin expiry, for tests
    * `:proxy` — always refused
  """
  @spec approve(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def approve(url, opts \\ [])

  def approve(url, opts) when is_binary(url) and is_list(opts) do
    if Keyword.has_key?(opts, :proxy) do
      {:error,
       fail(:validation, :proxy_forbidden, "Outbound proxy configuration is not allowed.")}
    else
      do_approve(url, opts)
    end
  end

  def approve(_url, _opts) do
    {:error, fail(:validation, :url_invalid, "The URL is not valid.")}
  end

  defp do_approve(url, opts) do
    resolver = Keyword.get(opts, :resolver, &default_resolver/1)
    allow_http? = Keyword.get(opts, :allow_http, false)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ttl = opts |> Keyword.get(:ttl_ms, @ttl_ms) |> positive_ttl()

    with {:ok, url} <- normalize_input(url),
         :ok <- check_authority_chars(url),
         {:ok, uri} <- parse_uri(url),
         :ok <- check_scheme(uri.scheme, allow_http?),
         :ok <- check_userinfo(uri),
         :ok <- check_fragment(uri),
         {:ok, host} <- normalize_host(uri.host),
         {:ok, port} <- check_port(url, uri),
         {:ok, addresses} <- resolve_host(host, resolver) do
      {:ok,
       %__MODULE__{
         scheme: uri.scheme,
         hostname: hostname(host),
         port: port,
         addresses: addresses |> Enum.uniq() |> Enum.sort(),
         expires_at: DateTime.add(now, ttl, :millisecond)
       }}
    end
  end

  defp normalize_input(url) do
    trimmed = String.trim(url)

    cond do
      trimmed == "" ->
        {:error, fail(:validation, :url_invalid, "The URL is not valid.")}

      String.contains?(trimmed, ["\n", "\r", "\t", " "]) ->
        {:error, fail(:validation, :url_invalid, "The URL is not valid.")}

      true ->
        {:ok, apply_default_scheme(trimmed)}
    end
  end

  defp apply_default_scheme(url) do
    cond do
      String.contains?(url, "://") -> url
      String.starts_with?(url, "//") -> "https:" <> url
      String.match?(url, ~r/\A[A-Za-z][A-Za-z0-9+.\-]*:/) -> url
      true -> "https://" <> url
    end
  end

  defp check_authority_chars(url) do
    authority = extract_authority(url)

    cond do
      String.contains?(authority, "%") ->
        {:error, fail(:validation, :host_invalid, "The host is not valid.")}

      String.contains?(authority, [" ", "\\", "<", ">", "\"", "'"]) ->
        {:error, fail(:validation, :host_invalid, "The host is not valid.")}

      authority_control?(authority) ->
        {:error, fail(:validation, :host_invalid, "The host is not valid.")}

      true ->
        :ok
    end
  end

  defp parse_uri(url) do
    uri = url |> URI.parse() |> downcase_scheme()

    if is_binary(uri.host) and uri.host != "" do
      {:ok, uri}
    else
      {:error, fail(:validation, :host_invalid, "The URL needs a host.")}
    end
  end

  defp downcase_scheme(%URI{scheme: scheme} = uri) when is_binary(scheme) do
    %{uri | scheme: String.downcase(scheme)}
  end

  defp downcase_scheme(uri), do: uri

  defp check_scheme("https", _allow_http?), do: :ok

  defp check_scheme("http", true), do: :ok

  defp check_scheme("http", false) do
    {:error, fail(:validation, :http_not_allowed, "HTTP is not allowed; HTTPS is required.")}
  end

  defp check_scheme(_scheme, _allow_http?) do
    {:error, fail(:validation, :scheme_not_allowed, "The URL must use HTTPS.")}
  end

  defp check_userinfo(%URI{userinfo: nil}), do: :ok

  defp check_userinfo(%URI{}) do
    {:error, fail(:validation, :url_userinfo, "The URL must not carry a user name.")}
  end

  defp check_fragment(%URI{fragment: nil}), do: :ok

  defp check_fragment(%URI{}) do
    {:error, fail(:validation, :url_fragment, "The URL must not carry a fragment.")}
  end

  defp normalize_host(host) when is_binary(host) do
    case :unicode.characters_to_nfc_binary(host) do
      nfc when is_binary(nfc) ->
        stripped = String.trim_trailing(nfc, ".")

        cond do
          stripped == "" ->
            {:error, fail(:validation, :host_invalid, "The URL needs a host.")}

          String.contains?(stripped, [" ", "/", "\\", "?", "#", "@", "[", "]"]) ->
            {:error, fail(:validation, :host_invalid, "The host is not valid.")}

          true ->
            classify_host(stripped)
        end

      _other ->
        {:error, fail(:validation, :host_invalid, "The host is not valid.")}
    end
  end

  defp classify_host(host) do
    case IpPolicy.parse_literal(host) do
      {:canonical, ip} ->
        {:ok, {:ip, host, ip}}

      :non_canonical ->
        {:error,
         fail(:validation, :ip_literal_noncanonical, "The address is not a canonical IP.")}

      :error ->
        ascii_hostname(host)
    end
  end

  defp ascii_hostname(host) do
    labels = String.split(host, ".")

    with :ok <- check_label_count(labels),
         {:ok, encoded} <- encode_labels(labels),
         :ok <- check_host_length(encoded),
         :ok <- check_blocked_name(encoded) do
      {:ok, {:name, encoded}}
    end
  end

  defp check_label_count(labels) do
    if labels == [] or Enum.any?(labels, &(&1 == "")) do
      {:error, fail(:validation, :host_invalid, "The host is not valid.")}
    else
      :ok
    end
  end

  defp encode_labels(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, acc} ->
      case to_ascii_label(label) do
        {:ok, encoded} -> {:cont, {:ok, acc ++ [encoded]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.join(encoded, ".")}
      other -> other
    end
  end

  defp to_ascii_label(label) do
    cond do
      confused_label?(label) ->
        {:error,
         fail(:validation, :host_idna_confusion, "The host mixes incompatible characters.")}

      ascii_ldh?(label) ->
        {:ok, String.downcase(label)}

      not ascii?(label) ->
        ace = "xn--" <> punycode_encode(String.downcase(label))

        if byte_size(ace) > @max_label_length do
          {:error, fail(:validation, :host_invalid, "The host is too long.")}
        else
          {:ok, ace}
        end

      true ->
        {:error, fail(:validation, :host_invalid, "The host is not valid.")}
    end
  end

  # Homographs mix scripts inside one label (Cyrillic "е" plus Latin
  # "xample"). Latin with diacritics (`münchen`) is still one script.
  defp confused_label?(label) do
    scripts =
      label
      |> String.to_charlist()
      |> Enum.map(&letter_script/1)
      |> Enum.reject(&(&1 == :ignore))
      |> Enum.uniq()

    length(scripts) > 1
  end

  defp letter_script(cp) when cp in ?A..?Z or cp in ?a..?z, do: :latin
  defp letter_script(cp) when cp in 0x00C0..0x00D6, do: :latin
  defp letter_script(cp) when cp in 0x00D8..0x00F6, do: :latin
  defp letter_script(cp) when cp in 0x00F8..0x024F, do: :latin
  defp letter_script(cp) when cp in 0x1E00..0x1EFF, do: :latin
  defp letter_script(cp) when cp in 0x0370..0x03FF, do: :greek
  defp letter_script(cp) when cp in 0x0400..0x04FF, do: :cyrillic
  defp letter_script(cp) when cp in 0x0500..0x052F, do: :cyrillic
  defp letter_script(cp) when cp in 0x2DE0..0x2DFF, do: :cyrillic
  defp letter_script(cp) when cp in 0xA640..0xA69F, do: :cyrillic
  defp letter_script(cp) when cp > 127, do: :other
  defp letter_script(_cp), do: :ignore

  defp ascii?(string), do: string |> String.to_charlist() |> Enum.all?(&(&1 < 128))

  defp ascii_ldh?(label) do
    Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?\z/, label) and
      byte_size(label) <= @max_label_length
  end

  defp check_host_length(host) do
    if byte_size(host) > @max_host_length do
      {:error, fail(:validation, :host_invalid, "The host is too long.")}
    else
      :ok
    end
  end

  defp check_blocked_name(host) do
    if blocked_name?(host) do
      {:error,
       fail(:validation, :target_blocked, "That address is not allowed.", %{reason: :name})}
    else
      :ok
    end
  end

  defp blocked_name?(host) do
    host in @blocked_names or
      String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".metadata.google.internal")
  end

  defp check_port(url, uri) do
    authority = extract_authority(url)

    case port_token(authority) do
      nil -> validate_port(uri.port || default_port(uri.scheme))
      token -> parse_port_token(token)
    end
  end

  defp port_token(authority) do
    if String.starts_with?(authority, "[") do
      case String.split(authority, "]:", parts: 2) do
        [_, port] -> port
        _ -> nil
      end
    else
      hostport =
        case String.split(authority, "@") do
          [single] -> single
          [_userinfo, rest] -> rest
        end

      case String.split(hostport, ":", parts: 2) do
        [_host] -> nil
        [_host, port] -> port
      end
    end
  end

  defp parse_port_token(token) do
    case Integer.parse(token) do
      {port, ""} -> validate_port(port)
      _other -> {:error, fail(:validation, :port_invalid, "The port is not valid.")}
    end
  end

  defp validate_port(port) when is_integer(port) and port >= 1 and port <= 65_535 do
    {:ok, port}
  end

  defp validate_port(_port) do
    {:error, fail(:validation, :port_invalid, "The port is not valid.")}
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_scheme), do: nil

  defp resolve_host({:ip, _original, ip}, _resolver), do: validate_addresses([ip])

  defp resolve_host({:name, hostname}, resolver) do
    case resolver.(hostname) do
      {:ok, addresses} when is_list(addresses) -> validate_addresses(addresses)
      {:error, reason} -> dns_error(reason)
      _other -> dns_error(:invalid_resolver)
    end
  end

  defp validate_addresses(addresses) do
    valid = Enum.filter(addresses, &valid_ip?/1)

    if valid == [] do
      dns_error(:empty)
    else
      blocked =
        valid
        |> Enum.map(&{&1, IpPolicy.classify(&1)})
        |> Enum.find(fn
          {_ip, {:blocked, _reason}} -> true
          _other -> false
        end)

      case blocked do
        {_ip, {:blocked, reason}} ->
          {:error,
           fail(:validation, :target_blocked, "That address is not allowed.", %{reason: reason})}

        nil ->
          {:ok, valid}
      end
    end
  end

  defp valid_ip?({a, b, c, d})
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: true

  defp valid_ip?({a, b, c, d, e, f, g, h})
       when a in 0..0xFFFF and b in 0..0xFFFF and c in 0..0xFFFF and d in 0..0xFFFF and
              e in 0..0xFFFF and f in 0..0xFFFF and g in 0..0xFFFF and h in 0..0xFFFF,
       do: true

  defp valid_ip?(_ip), do: false

  defp hostname({:ip, original, _ip}), do: original
  defp hostname({:name, name}), do: name

  defp extract_authority(url) do
    case String.split(url, "://", parts: 2) do
      [_, rest] ->
        case :binary.split(rest, ["/", "?", "#"]) do
          [authority | _] -> authority
          _ -> rest
        end

      _ ->
        ""
    end
  end

  defp authority_control?(authority) do
    authority |> String.to_charlist() |> Enum.any?(&(&1 < 32 or &1 == 127))
  end

  defp nonempty([]), do: {:error, :nxdomain}
  defp nonempty(addrs), do: {:ok, Enum.uniq(addrs)}

  defp dns_error(_reason) do
    {:error, fail(:dependency, :dns_failed, "The host could not be resolved.")}
  end

  defp positive_ttl(ttl) when is_integer(ttl) and ttl > 0, do: ttl
  defp positive_ttl(_ttl), do: @ttl_ms

  defp fail(class, code, message, details \\ %{}) do
    Error.new(class, code, message: message, details: details)
  end

  # RFC 3492 Punycode. OTP has no `:idna` application; labels that survive
  # the mixed-script check are encoded here so DNS and SNI see A-labels.
  defp punycode_encode(label) do
    input = String.to_charlist(label)
    basic = Enum.filter(input, &(&1 < 128))

    output =
      if basic != [] and Enum.any?(input, &(&1 >= 128)) do
        basic ++ [?-]
      else
        basic
      end

    encode_loop(
      input,
      output,
      length(basic),
      @puny_initial_n,
      0,
      @puny_initial_bias,
      length(basic)
    )
  end

  defp encode_loop(input, output, h, _n, _delta, _bias, _b) when h >= length(input) do
    List.to_string(output)
  end

  defp encode_loop(input, output, h, n, delta, bias, b) do
    m = input |> Enum.filter(&(&1 >= n)) |> Enum.min()
    delta = delta + (m - n) * (h + 1)
    {output, h, delta, bias} = scan_input(input, output, h, m, delta, bias, b)
    encode_loop(input, output, h, m + 1, delta + 1, bias, b)
  end

  defp scan_input([], output, h, _n, delta, bias, _b), do: {output, h, delta, bias}

  defp scan_input([c | rest], output, h, n, delta, bias, b) do
    delta = if c < n, do: delta + 1, else: delta

    if c == n do
      encoded = output ++ encode_int(delta, bias, @puny_base)
      bias = adapt(delta, h + 1, h == b)
      scan_input(rest, encoded, h + 1, n, 0, bias, b)
    else
      scan_input(rest, output, h, n, delta, bias, b)
    end
  end

  defp encode_int(q, bias, k) do
    t = threshold(k, bias)

    if q < t do
      [puny_digit(q)]
    else
      [
        puny_digit(t + rem(q - t, @puny_base - t))
        | encode_int(div(q - t, @puny_base - t), bias, k + @puny_base)
      ]
    end
  end

  defp threshold(k, bias) when k <= bias, do: @puny_tmin
  defp threshold(k, bias) when k >= bias + @puny_tmax, do: @puny_tmax
  defp threshold(k, bias), do: k - bias

  defp adapt(delta, numpoints, firsttime?) do
    delta = if firsttime?, do: div(delta, @puny_damp), else: div(delta, 2)
    {delta, k} = adapt_loop(delta + div(delta, numpoints), 0)
    k + div((@puny_base - @puny_tmin + 1) * delta, delta + @puny_skew)
  end

  defp adapt_loop(delta, k) when delta > div((@puny_base - @puny_tmin) * @puny_tmax, 2) do
    adapt_loop(div(delta, @puny_base - @puny_tmin), k + @puny_base)
  end

  defp adapt_loop(delta, k), do: {delta, k}

  defp puny_digit(d) when d < 26, do: ?a + d
  defp puny_digit(d), do: ?0 + (d - 26)
end
