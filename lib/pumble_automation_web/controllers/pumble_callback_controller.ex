defmodule PumbleAutomationWeb.PumbleCallbackController do
  @moduledoc """
  The one endpoint Pumble posts callbacks to.

  By the time `dispatch/2` runs, two plugs have already done their work: the raw
  bytes were retained before any JSON parsing, and the signature over those
  bytes was verified. This action does the remaining four steps of plan
  Section 12.1 — classify, hand to the ingress boundary, answer, measure — and
  nothing else.

  ## The dispatch table

  | class | boundary call | response |
  |---|---|---|
  | Pumble event | `enqueue_event/1` | `200` text `ok` |
  | slash command, shortcut, view action | `record_interaction/2` | `200` JSON `{}` on start/duplicate; picker modal; not-found message |
  | approval button (`BLOCK_INTERACTION` with a bound token) | `ApprovalService.decide/1` | `200` JSON ack: decided, duplicate, or a safe stale message |
  | dynamic menu | bounded tenant-scoped lookup | exact options envelope, or `nack` |
  | unknown event name | none | `200` text `ok` |
  | anything else | none | `400` JSON `{"message": …}` |

  Two rows carry a decision worth stating:

  **An unknown event name is answered `200 ok`, not refused.** Events have no
  negative acknowledgement at all (`K-6`), and what a non-2xx does to redelivery
  is unproven server behaviour (`K-10`, `PR-02`). Refusing an event this
  application does not understand could therefore produce an unbounded retry of
  something it will never understand. It is acknowledged, counted, and dropped.
  A malformed *envelope*, by contrast, is still `400`: that is a request this
  application cannot even classify, and plan `P4-T03` requires it to be refused
  after signature validation.

  **A dynamic menu is a bounded read, never a trigger.** The fixed manifest
  action resolves only the sorted union of active aliases visible in either
  shortcut picker in the callback's tenant, returns at most 25 options, and
  creates neither a receipt nor an execution. The union is necessary because
  the options-load payload has no picker-origin field.
  The class has no acknowledgement helper: it answers with the exact options
  envelope, or with the same stable `nack` for an unknown action, tenant, or
  empty result (`K-4`).

  ## Nothing expensive runs here

  The action performs no external call, no workflow step, and no unbounded work
  of any kind. `PumbleAutomation.Ingress.Service` owns everything after
  classification, and plan Section 17.3 fixes what may happen before the
  acknowledgement: verification, minimal validation, the dedupe and execution
  inserts, an Oban insert, and building a small response. No call to Pumble.

  ## One response per request

  Each branch produces exactly one `t:PumbleAutomation.Pumble.Response.t/0` value
  and `send_response/2` sends it once. The SDK needs a `headersSent` guard in
  three helpers (`K-8`) because its handlers may call several of them; there is
  nothing to guard here, because a response is a value that is returned rather
  than a side effect that may be repeated.

  ## Latency

  Every request is measured and reported through telemetry. The deadline is
  three seconds (`K-7`) and the internal warning threshold is well below it, so
  the first sign of trouble is a warning in the logs rather than an ephemeral
  "app is not available" message in front of a user.
  """

  use PumbleAutomationWeb, :controller

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Ingress.ManualTrigger
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.Logging
  alias PumbleAutomation.Pumble.Classifier
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Pumble.Response

  @telemetry_event [:pumble_automation, :pumble, :callback]
  @default_latency_warning_ms 1500

  # Neither message names a class, a field, a module, or a reason. A refusal is
  # read by whoever sent the request, and this endpoint's callers are Pumble and
  # anyone who has guessed the path.
  @malformed_message "This callback could not be processed."
  @dynamic_menu_message "This add-on offers no dynamic menu options."

  @doc """
  Classifies one verified callback and sends its protocol-correct response.
  """
  def dispatch(conn, _params) do
    true = conn.private[:pumble_signature_verified]

    started_at = System.monotonic_time()
    {outcome, class, response} = handle(conn)
    conn = send_response(conn, response)

    measure(started_at, outcome, class, response)

    conn
  end

  @doc "The telemetry event prefix this controller emits under."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  The latency at which a callback is reported as slow, in milliseconds.

  Configured as `:latency_warning_ms` under `:pumble_callbacks`. It is an
  internal budget, deliberately far below Pumble's three-second deadline, so
  that it fires while there is still time to react.
  """
  @spec latency_warning_ms() :: pos_integer()
  def latency_warning_ms do
    :pumble_automation
    |> Application.get_env(:pumble_callbacks, [])
    |> Keyword.get(:latency_warning_ms, @default_latency_warning_ms)
  end

  defp handle(conn) do
    case Classifier.classify(conn.body_params) do
      {:ok, payload} ->
        accept(payload, conn)

      {:error, %Error{code: :unknown_event_type}} ->
        {:ignored, :event, Response.event_ack()}

      {:error, %Error{}} ->
        {:malformed, :unclassified, Response.nack(@malformed_message)}
    end
  end

  defp accept(%Payload.Event{} = event, conn) do
    case Service.enqueue_event(event, callback_context(conn)) do
      :accepted ->
        {:accepted, :event, Response.event_ack()}

      {:error, %Error{retryable?: true}} ->
        {:failed, :event, {:text, 500, ""}}

      {:error, %Error{}} ->
        {:accepted, :event, Response.event_ack()}
    end
  end

  defp accept(%Payload.DynamicMenu{} = menu, conn) do
    case Service.record_interaction(menu, callback_context(conn)) do
      {:ok, {:dynamic_menu, body}} ->
        {:accepted, :dynamic_menu, Response.response(body)}

      {:ok, _absent} ->
        {:unsupported, :dynamic_menu, Response.nack(@dynamic_menu_message)}

      {:error, %Error{retryable?: true}} ->
        {:failed, :dynamic_menu,
         {:json, 500, %{"message" => "This request could not be completed."}}}

      {:error, %Error{}} ->
        {:unsupported, :dynamic_menu, Response.nack(@dynamic_menu_message)}
    end
  end

  defp accept(%Payload.BlockInteraction{} = interaction, conn) do
    case ApprovalService.decide(interaction) do
      {:ok, :ignored} ->
        accept_manual(interaction, conn)

      {:ok, {_kind, message}} ->
        {:accepted, :block_interaction, Response.ack(message)}

      {:error, %Error{retryable?: true}} ->
        {:failed, :block_interaction,
         {:json, 500, %{"message" => "This request could not be completed."}}}

      {:error, %Error{}} ->
        {:accepted, :block_interaction, Response.ack(ApprovalService.stale_message())}
    end
  end

  defp accept(interaction, conn) do
    accept_manual(interaction, conn)
  end

  defp accept_manual(interaction, conn) do
    class = Payload.kind(interaction)

    case Service.record_interaction(interaction, callback_context(conn)) do
      {:ok, :started} ->
        {:accepted, class, Response.ack()}

      {:ok, :duplicate} ->
        {:accepted, class, Response.ack()}

      {:ok, :ignored} ->
        {:accepted, class, Response.ack()}

      {:ok, :not_found} ->
        {:accepted, class, Response.ack(ManualTrigger.not_found_message())}

      {:ok, {:picker, body}} ->
        {:accepted, class, Response.response(body)}

      {:error, %Error{retryable?: true}} ->
        {:failed, class, {:json, 500, %{"message" => "This request could not be completed."}}}

      {:error, %Error{code: :missing_body}} ->
        {:failed, class, Response.nack(@malformed_message)}

      {:error, %Error{}} ->
        {:accepted, class, Response.ack(ManualTrigger.not_found_message())}
    end
  end

  defp callback_context(conn) do
    %{
      raw_body: conn.private[:raw_body] || "",
      signature: signature_header(conn)
    }
  end

  defp signature_header(conn) do
    case get_req_header(conn, "x-pumble-request-signature") do
      [value] -> value
      _missing -> ""
    end
  end

  defp send_response(conn, {:text, status, body}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  defp send_response(conn, {:json, status, body}) do
    conn
    |> put_status(status)
    |> json(body)
  end

  defp measure(started_at, outcome, class, response) do
    duration = System.monotonic_time() - started_at
    metadata = %{class: class, outcome: outcome, status: status_of(response)}

    :telemetry.execute(@telemetry_event ++ [:stop], %{duration: duration}, metadata)

    report_if_slow(duration, metadata)
  end

  defp report_if_slow(duration, metadata) do
    milliseconds = System.convert_time_unit(duration, :native, :millisecond)
    threshold = latency_warning_ms()

    if milliseconds >= threshold do
      :telemetry.execute(
        @telemetry_event ++ [:slow],
        %{duration: duration, threshold_ms: threshold},
        metadata
      )

      Logging.event(:warning, "pumble.callback", %{
        operation: "pumble.callback",
        event_type: metadata.class,
        status: metadata.outcome,
        duration_ms: milliseconds,
        error_code: :slow
      })
    end

    :ok
  end

  defp status_of({:text, status, _body}), do: status
  defp status_of({:json, status, _body}), do: status
end
