defmodule PumbleAutomationWeb.InboundWebhookController do
  @moduledoc """
  The internet-facing POST for one tenant webhook endpoint.

  Authentication always requires a 256-bit bearer token, never a query string.
  Endpoints may additionally require the generic webhook raw-body HMAC in the
  fixed `x-webhook-signature` header. A 202 names the opaque receipt id and is
  sent only after the execution and job exist. Auth failures do not disclose
  whether the public id, bearer, or signature was wrong.
  """

  use PumbleAutomationWeb, :controller

  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.WebhookService

  @retry_message "The request could not be accepted."
  @resource_limit_codes [
    :queued_executions_limit,
    :total_workflows_limit,
    :active_workflows_limit,
    :schedules_limit,
    :lineage_loop,
    :lineage_depth_exceeded,
    :lineage_descendants_exceeded
  ]

  @doc "Accepts one JSON POST identified only by the opaque public id."
  def create(conn, %{"public_id" => public_id}) do
    case WebhookService.accept(public_id, request(conn)) do
      {:ok, receipt} ->
        conn
        |> put_status(:accepted)
        |> json(%{"id" => receipt.id})

      {:error, %Error{} = error} ->
        send_error(conn, error)
    end
  end

  defp request(conn) do
    %{
      raw_body: conn.private[:raw_body] || "",
      content_type: header(conn, "content-type"),
      authorization: credential_header(conn, "authorization"),
      token_header: credential_header(conn, WebhookService.token_header()),
      signature: credential_header(conn, WebhookService.signature_header()),
      idempotency_key: header(conn, "idempotency-key"),
      headers: header_map(conn),
      remote_ip: conn.remote_ip,
      body: json_body(conn),
      query_token?: query_credential?(conn)
    }
  end

  defp json_body(%Plug.Conn{body_params: params} = conn)
       when is_map(params) and not is_struct(params) do
    case Map.get(params, "_json") do
      nil -> Map.drop(params, extras(conn))
      other -> other
    end
  end

  defp json_body(%Plug.Conn{}), do: %{}

  defp extras(conn) do
    conn.path_params
    |> Map.merge(conn.query_params)
    |> Map.keys()
    |> Kernel.++(["public_id"])
  end

  defp query_credential?(conn) do
    Enum.any?(conn.query_params, fn {key, value} ->
      credential_key?(key) and is_binary(value) and value != ""
    end)
  end

  defp credential_key?(key) when is_binary(key) do
    Regex.match?(
      ~r/(token|secret|password|credential|authorization|bearer|api[_-]?key)/i,
      key
    )
  end

  defp credential_key?(_key), do: false

  defp header_map(conn) do
    Map.new(conn.req_headers, fn {key, value} -> {key, value} end)
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      _missing -> nil
    end
  end

  defp credential_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      [] -> nil
      _multiple -> :ambiguous
    end
  end

  defp send_error(conn, %Error{class: :permission, code: :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{"error" => "unauthorized"})
  end

  defp send_error(conn, %Error{class: :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "not_found"})
  end

  defp send_error(conn, %Error{class: :rate_limited} = error) do
    retry_after = Map.get(error.details, :retry_after_seconds, 60)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{"error" => "rate_limited"})
  end

  defp send_error(conn, %Error{code: :unsupported_media_type}) do
    conn
    |> put_status(:unsupported_media_type)
    |> json(%{"error" => "unsupported_media_type"})
  end

  defp send_error(conn, %Error{code: :payload_too_large}) do
    conn
    |> put_status(:payload_too_large)
    |> json(%{"error" => "payload_too_large"})
  end

  defp send_error(conn, %Error{class: :validation, code: code})
       when code in @resource_limit_codes do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => Atom.to_string(code)})
  end

  defp send_error(conn, %Error{class: :validation}) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "invalid"})
  end

  defp send_error(conn, %Error{class: :conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{"error" => "conflict"})
  end

  defp send_error(conn, %Error{retryable?: true}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{"error" => "unavailable", "message" => @retry_message})
  end

  defp send_error(conn, %Error{}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{"error" => "unavailable", "message" => @retry_message})
  end
end
