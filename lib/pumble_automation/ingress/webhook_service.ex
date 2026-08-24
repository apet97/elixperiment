defmodule PumbleAutomation.Ingress.WebhookService do
  @moduledoc """
  Accepts one authenticated inbound webhook delivery.

  The public id in the URL names a single tenant endpoint. The bearer token
  authorizes only that endpoint. The caller cannot choose a workflow or
  version; the stored binding is used. A 202 is returned only after a
  receipt and an execution-plus-job exist.

  Endpoints configured with `require_signature` additionally authenticate the
  fixed `x-webhook-signature` header over the exact raw request bytes. This is
  the generic inbound-webhook credential and is unrelated to Pumble callback
  signing.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Lineage
  alias PumbleAutomation.Ingress.Deduplication
  alias PumbleAutomation.Ingress.RateLimiter
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Limits, as: Catalog
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.Limits

  @telemetry_event [:pumble_automation, :ingress, :webhook]
  @signature_header "x-webhook-signature"
  @allowed_headers ~w(content-type user-agent x-request-id)
  @token_bytes 32
  @max_json_depth Limits.max_json_depth()
  @max_map_size Limits.max_map_size()
  @max_list_length Limits.max_list_length()
  @max_string_length Limits.max_string_length()

  @typedoc "Transport facts the controller already extracted from the connection."
  @type request :: %{
          optional(:raw_body) => binary(),
          optional(:content_type) => String.t() | nil,
          optional(:authorization) => String.t() | nil | :ambiguous,
          optional(:token_header) => String.t() | nil | :ambiguous,
          optional(:signature) => String.t() | nil | :ambiguous,
          optional(:idempotency_key) => String.t() | nil,
          optional(:headers) => map(),
          optional(:remote_ip) => term(),
          optional(:body) => term(),
          optional(:query_token?) => boolean()
        }

  @doc "Accepts one POST to an opaque public endpoint id."
  @spec accept(String.t(), request()) :: {:ok, ReceivedEvent.t()} | {:error, Error.t()}
  def accept(public_id, request) when is_binary(public_id) and is_map(request) do
    with :ok <- check_auth_failure_rate(request),
         {:ok, endpoint, raw_body} <- authenticate_request(public_id, request),
         :ok <- check_rate(endpoint, request),
         {:ok, payload} <- bound_payload(request) do
      ingest(endpoint, request, raw_body, payload)
    end
  end

  @doc "Creates the rate-limit table if this node does not already hold it."
  @spec ensure_rate_table() :: :ok
  def ensure_rate_table do
    case RateLimiter.ensure() do
      :ok -> :ok
      :error -> :ok
    end
  end

  @doc "Empties the rate-limit table. Tests only."
  @spec reset_rate_table() :: :ok
  def reset_rate_table, do: RateLimiter.reset()

  @doc "The configured opaque path prefix for inbound webhooks."
  @spec path_prefix() :: String.t()
  def path_prefix do
    settings() |> Keyword.get(:path_prefix, "/hooks")
  end

  @doc "The configured body cap, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes do
    Catalog.get(:generic_webhook_body_bytes)
  end

  @doc "The one non-Authorization header that may carry the bearer token."
  @spec token_header() :: String.t()
  def token_header do
    settings() |> Keyword.get(:token_header, "x-webhook-token")
  end

  @doc "The fixed header carrying a generic webhook raw-body HMAC."
  @spec signature_header() :: String.t()
  def signature_header, do: @signature_header

  @doc "Telemetry prefix for webhook ingest and abuse signals."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp ingest(endpoint, request, raw_body, payload) do
    with {:ok, kind, receipt} <- record_receipt(endpoint, request, raw_body, payload) do
      finish(kind, receipt, endpoint, payload, request)
    end
  end

  defp finish(
         _kind,
         %ReceivedEvent{processing_state: "processed"} = receipt,
         endpoint,
         _payload,
         _request
       ) do
    touch(endpoint)
    {:ok, receipt}
  end

  defp finish(_kind, receipt, endpoint, payload, request) do
    snapshot = webhook_snapshot(endpoint, receipt, payload)

    case Engine.create(
           endpoint.installation_id,
           webhook_create_attrs(endpoint, receipt, snapshot, request)
         ) do
      {:ok, _execution} ->
        with :ok <- mark_processed(receipt) do
          touch(endpoint)
          {:ok, receipt}
        end

      {:error, %Error{code: code} = error} when code in [:not_active, :version_mismatch] ->
        {:error, error}

      {:error, %Error{code: :not_found}} ->
        {:error, unauthorized()}

      {:error, %Error{class: class} = error} when class in [:validation, :rate_limited] ->
        {:error, error}

      {:error, error} ->
        {:error, retry_later(error)}
    end
  end

  defp record_receipt(endpoint, request, raw_body, payload) do
    Deduplication.record(%{
      installation_id: endpoint.installation_id,
      class: "webhook",
      type: "webhook",
      provider: "webhook",
      endpoint_id: endpoint.id,
      idempotency_key: optional_text(attr(request, :idempotency_key)),
      raw_body: raw_body,
      received_at: DateTime.utc_now(),
      data: webhook_snapshot(endpoint, nil, payload)
    })
  end

  defp webhook_snapshot(endpoint, receipt, payload) do
    %{
      "type" => "webhook",
      "endpoint_public_id" => endpoint.public_id,
      "workflow_id" => endpoint.workflow_id,
      "workflow_version_id" => endpoint.workflow_version_id,
      "body" => payload.body,
      "headers" => payload.headers
    }
    |> put_present("received_event_id", receipt && receipt.id)
  end

  defp webhook_create_attrs(endpoint, receipt, snapshot, request) do
    attrs = %{
      workflow_version_id: endpoint.workflow_version_id,
      execution_key: "hook:" <> receipt.id,
      received_event_id: receipt.id,
      trigger_snapshot: snapshot,
      run_mode: "live",
      lineage_source: :webhook
    }

    case Lineage.parent_from_headers(attr(request, :headers), endpoint.installation_id) do
      {:ok, parent_id} -> Map.put(attrs, :parent_execution_id, parent_id)
      :absent -> attrs
    end
  end

  defp authenticate(public_id, token) do
    endpoint = Repo.one(WebhookEndpoint.by_public_id_for_auth(public_id))
    allowed? = token_matches?(endpoint, token)

    if allowed? do
      {:ok, endpoint}
    else
      emit_abuse(:auth_failed)
      {:error, unauthorized()}
    end
  end

  defp authenticate_request(public_id, request) do
    result =
      with :ok <- refuse_ambiguous_credentials(request),
           :ok <- refuse_query_credentials(request),
           :ok <- require_json(request),
           {:ok, raw_body} <- require_body(request),
           :ok <- require_size(raw_body),
           {:ok, token} <- presented_token(request),
           {:ok, endpoint} <- authenticate(public_id, token),
           :ok <- require_enabled(endpoint),
           :ok <- require_signature(endpoint, request, raw_body) do
        {:ok, endpoint, raw_body}
      end

    case result do
      {:error, %Error{class: :permission, code: :unauthorized}} = error ->
        RateLimiter.hit(auth_failure_key(request))
        error

      other ->
        other
    end
  end

  defp token_matches?(nil, token) do
    digest = WebhookEndpoint.digest(token)
    dummy = WebhookEndpoint.digest("webhook-auth-dummy")
    _ = Plug.Crypto.secure_compare(dummy, digest)
    false
  end

  defp token_matches?(%WebhookEndpoint{} = endpoint, token) do
    WebhookEndpoint.authenticates?(endpoint, token)
  end

  defp require_enabled(%WebhookEndpoint{} = endpoint) do
    if WebhookEndpoint.enabled?(endpoint) do
      :ok
    else
      {:error,
       Error.new(:not_found, :endpoint_disabled, message: "That resource does not exist.")}
    end
  end

  defp require_signature(%WebhookEndpoint{} = endpoint, request, raw_body) do
    if WebhookEndpoint.signature_valid?(endpoint, attr(request, :signature), raw_body) do
      :ok
    else
      emit_abuse(:auth_failed)
      {:error, unauthorized()}
    end
  end

  defp refuse_ambiguous_credentials(request) do
    if Enum.any?([:authorization, :token_header, :signature], &(attr(request, &1) == :ambiguous)) do
      emit_abuse(:auth_failed)
      {:error, unauthorized()}
    else
      :ok
    end
  end

  defp check_auth_failure_rate(request) do
    key = auth_failure_key(request)
    limit = Catalog.get(:callback_failures_per_minute)

    if RateLimiter.limited?(key, limit: limit) do
      Catalog.record_hit(:webhook_auth_failure)
      emit_abuse(:rate_limited)

      {:error,
       Error.new(:rate_limited, :webhook_auth_rate_limited,
         message: "Too many authentication failures were received.",
         details: %{retry_after_seconds: 60}
       )}
    else
      :ok
    end
  end

  defp auth_failure_key(request) do
    {:webhook_auth_failure, RateLimiter.ip_digest(attr(request, :remote_ip))}
  end

  defp refuse_query_credentials(request) do
    if attr(request, :query_token?) == true do
      emit_abuse(:query_credential)
      {:error, unauthorized()}
    else
      :ok
    end
  end

  defp require_json(request) do
    case media_type(attr(request, :content_type)) do
      "application/json" ->
        :ok

      _other ->
        {:error,
         Error.new(:validation, :unsupported_media_type,
           message: "Send JSON with Content-Type application/json."
         )}
    end
  end

  defp require_body(request) do
    case attr(request, :raw_body) do
      raw when is_binary(raw) and raw != "" ->
        {:ok, raw}

      _missing ->
        {:error,
         Error.new(:validation, :missing_body, message: "A JSON object body is required.")}
    end
  end

  defp require_size(raw_body) do
    if byte_size(raw_body) <= max_body_bytes() do
      :ok
    else
      {:error,
       Error.new(:validation, :payload_too_large, message: "The request body is too large.")}
    end
  end

  defp presented_token(request) do
    bearer = bearer_token(attr(request, :authorization))
    header = optional_text(attr(request, :token_header))

    cond do
      is_binary(bearer) and is_binary(header) and bearer != header ->
        {:error, unauthorized()}

      is_binary(bearer) ->
        decode_token(bearer)

      is_binary(header) ->
        decode_token(header)

      true ->
        {:error, unauthorized()}
    end
  end

  defp bearer_token(value) when is_binary(value) do
    case String.split(String.trim(value), " ", parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer", do: String.trim(token), else: nil

      _other ->
        nil
    end
  end

  defp bearer_token(_value), do: nil

  defp decode_token(presented) when is_binary(presented) do
    cond do
      byte_size(presented) == @token_bytes ->
        {:ok, presented}

      decoded = url_decode(presented) ->
        {:ok, decoded}

      true ->
        {:ok, presented}
    end
  end

  defp url_decode(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} when byte_size(bytes) == @token_bytes -> bytes
      _failed -> nil
    end
  end

  defp check_rate(endpoint, request) do
    digest = RateLimiter.ip_digest(attr(request, :remote_ip))

    with :ok <-
           RateLimiter.check({:webhook_endpoint, endpoint.id},
             limit: endpoint.rate_limit_per_minute,
             source: :webhook_endpoint,
             installation_id: endpoint.installation_id,
             code: :endpoint_rate_limited
           ),
         :ok <-
           RateLimiter.check({:webhook_ip, endpoint.id, digest},
             limit: endpoint.rate_limit_per_ip_per_minute,
             source: :webhook_ip,
             installation_id: endpoint.installation_id,
             code: :ip_rate_limited
           ) do
      :ok
    else
      {:error, %Error{} = error} ->
        emit_abuse(:rate_limited)
        {:error, error}
    end
  end

  defp bound_payload(request) do
    with {:ok, body} <- json_object(attr(request, :body)),
         {:ok, bounded} <- bound_json(body, 0),
         {:ok, bounded} <- cap_encoded(bounded) do
      {:ok, %{body: bounded, headers: allowed_headers(attr(request, :headers))}}
    end
  end

  defp json_object(body) when is_map(body) and not is_struct(body), do: {:ok, body}

  defp json_object(_body) do
    {:error, Error.new(:validation, :invalid_json, message: "A JSON object body is required.")}
  end

  defp cap_encoded(map) do
    case Jason.encode(map) do
      {:ok, json} when byte_size(json) <= 48_000 ->
        {:ok, map}

      {:ok, _json} ->
        {:ok, %{"_truncated" => true}}

      {:error, _reason} ->
        {:error,
         Error.new(:validation, :invalid_json, message: "The JSON document is not accepted.")}
    end
  end

  defp bound_json(_value, depth) when depth > @max_json_depth do
    {:error, Error.new(:validation, :payload_too_deep, message: "The JSON document is too deep.")}
  end

  defp bound_json(map, depth) when is_map(map) and not is_struct(map) do
    if map_size(map) > @max_map_size do
      {:error,
       Error.new(:validation, :too_many_keys, message: "The JSON object has too many keys.")}
    else
      bound_map(Enum.to_list(map), depth, %{})
    end
  end

  defp bound_json(list, depth) when is_list(list) do
    if length(list) > @max_list_length do
      {:error, Error.new(:validation, :too_many_items, message: "The JSON list is too long.")}
    else
      bound_list(list, depth, [])
    end
  end

  defp bound_json(value, _depth) when is_binary(value) do
    if byte_size(value) <= @max_string_length do
      {:ok, value}
    else
      {:error, Error.new(:validation, :string_too_long, message: "A JSON string is too long.")}
    end
  end

  defp bound_json(value, _depth)
       when is_number(value) or is_boolean(value) or is_nil(value) do
    {:ok, value}
  end

  defp bound_json(_value, _depth) do
    {:error, Error.new(:validation, :invalid_json, message: "The JSON document is not accepted.")}
  end

  defp bound_map([], _depth, acc), do: {:ok, acc}

  defp bound_map([{key, value} | rest], depth, acc) do
    cond do
      not is_binary(key) ->
        {:error, Error.new(:validation, :invalid_json, message: "JSON keys must be strings.")}

      secret_field?(key) ->
        bound_map(rest, depth, acc)

      true ->
        case bound_json(value, depth + 1) do
          {:ok, bounded} -> bound_map(rest, depth, Map.put(acc, key, bounded))
          {:error, error} -> {:error, error}
        end
    end
  end

  defp bound_list([], _depth, acc), do: {:ok, Enum.reverse(acc)}

  defp bound_list([value | rest], depth, acc) do
    case bound_json(value, depth + 1) do
      {:ok, bounded} -> bound_list(rest, depth, [bounded | acc])
      {:error, error} -> {:error, error}
    end
  end

  defp allowed_headers(headers) when is_map(headers) do
    headers
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      name = header_name(key)

      if name in @allowed_headers and is_binary(value) do
        Map.put(acc, name, String.slice(value, 0, 256))
      else
        acc
      end
    end)
  end

  defp allowed_headers(_headers), do: %{}

  defp header_name(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp header_name(key) when is_binary(key), do: String.downcase(key)
  defp header_name(_key), do: ""

  defp secret_field?(key), do: Regex.match?(Error.secret_key_pattern(), key)

  defp mark_processed(receipt) do
    data =
      receipt.data
      |> Map.put("execution_count", 1)
      |> Map.put("dispatch_cursor", 1)

    case receipt
         |> ReceivedEvent.changeset(%{processing_state: "processed", data: data})
         |> Repo.update() do
      {:ok, _updated} ->
        :ok

      {:error, _changeset} ->
        {:error,
         Error.new(:internal, :receipt_update_failed,
           retryable?: true,
           message: "The receipt could not be marked processed."
         )}
    end
  end

  defp touch(%WebhookEndpoint{} = endpoint) do
    endpoint
    |> Ecto.Changeset.change(%{last_used_at: DateTime.utc_now()})
    |> Repo.update()

    :ok
  end

  defp unauthorized do
    Error.new(:permission, :unauthorized, message: "Unauthorized.")
  end

  defp retry_later(%Error{} = error) do
    Error.new(error.class, error.code,
      message: error.message,
      retryable?: true,
      details: error.details,
      cause: error.cause
    )
  end

  defp emit_abuse(reason) do
    :telemetry.execute(@telemetry_event ++ [:abuse], %{count: 1}, %{reason: reason})
    :ok
  end

  defp media_type(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp media_type(_value), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp attr(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp optional_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp optional_text(_value), do: nil

  defp settings do
    Application.get_env(:pumble_automation, :inbound_webhooks, [])
  end
end
