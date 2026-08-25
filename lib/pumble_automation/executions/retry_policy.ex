defmodule PumbleAutomation.Executions.RetryPolicy do
  @moduledoc """
  Bounded retry, exhaustion, and uncertain-pause decisions for a step.

  The node runner classifies what happened. This module decides whether that
  classification may repeat, must stop, or must wait for an operator. Oban is
  not the authority: it only retries a job that failed before a claim
  committed. After a claim, the engine records the attempt and, when a retry
  is allowed, inserts the next job with backoff.

  ## What repeats, and what does not

  Confirmed provider rejection never retries. Infrastructure failure before
  an effect may retry. An unknown remote outcome retries only when
  `PumbleAutomation.Pumble.Client.retry_safety/1` says repeating the call
  cannot duplicate work; otherwise the execution pauses.

  Default attempts are five. Backoff follows the documented error-class policy
  with full jitter.
  A valid `Retry-After` replaces that delay, clamped to the same bounds the
  Pumble error classifier already uses.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.NodeRegistry
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.Pumble.Client.Error, as: ClientError

  # Seconds to wait after attempts 1..5 before the next try. Attempt 5 is the
  # last: a failure there exhausts and the fifth delay is unused.
  @schedule [1, 5, 30, 120, 600]

  @retry_classes ~w(rate_limited transient_transport remote_transient internal)
  @uncertain_classes ~w(ambiguous_transport side_effect_uncertain)
  @cancel_classes ~w(cancelled)
  @permanent_classes ~w(
    validation authentication authorization missing_scope installation_revoked
    not_found conflict remote_permanent resource_limit internal_invariant
  )

  @type disposition :: :retry | :fail | :pause_uncertain | :cancel

  @type decision :: %{
          disposition: disposition(),
          outcome: Outcome.t(),
          retry_at: DateTime.t() | nil,
          delay_seconds: non_neg_integer() | nil
        }

  @doc "Error classes plus the classifier extras this policy names."
  @spec classes() :: [String.t()]
  def classes do
    Enum.sort(@retry_classes ++ @uncertain_classes ++ @cancel_classes ++ @permanent_classes)
  end

  @doc "How many times one step may run before exhaustion."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: Limits.get(:retries)

  @doc "Backoff ceilings, in seconds, after attempts 1..5."
  @spec schedule() :: [pos_integer()]
  def schedule, do: @schedule

  @doc "The resource-policy ceiling for a provider Retry-After hint, in seconds."
  @spec max_retry_after() :: pos_integer()
  def max_retry_after, do: 900

  @doc """
  Whether repeating `node` can duplicate an effect.

  Pumble operations are classified by `Client.retry_safety/1`. Several
  operations on one step take the strictest answer. HTTP GET and HEAD are
  read-only. Other HTTP methods are not idempotent unless the node names a
  remote idempotency header.
  """
  @spec retry_safety(map()) :: Client.retry_safety()
  def retry_safety(%{compiled_node: node}) when is_map(node), do: retry_safety(node)
  def retry_safety(%{type: type} = node) when is_map(node), do: safety_for(type, node)
  def retry_safety(_node), do: :not_idempotent

  @doc """
  Maps an error class, retry safety, and attempt onto one disposition.

  Unknown classes fail closed. Exhausted retryable classes fail rather than
  looping.
  """
  @spec decide(map()) :: disposition()
  def decide(input) when is_map(input) do
    class = class_name(attr(input, :error_class))
    safety = attr(input, :retry_safety) || :not_idempotent
    attempt = attr(input, :attempt_number) || 1

    class
    |> bucket()
    |> bound_attempts(safety, attempt)
  end

  @doc """
  Rewrites a runner outcome into the durable disposition the engine applies.

  `:success`, waits, `:cancelled`, `:permanent_error`, and `:uncertain` pass
  through. `:retryable_error` may stay a retry, become a pause, or become a
  permanent failure on exhaustion. A retry always carries `resume_at`.
  """
  @spec apply(Outcome.t(), map(), keyword()) :: {:ok, Outcome.t()}
  def apply(%Outcome{} = outcome, snapshot, opts \\ []) when is_map(snapshot) do
    case outcome.kind do
      :retryable_error -> {:ok, apply_retryable(outcome, snapshot, opts)}
      _other -> {:ok, outcome}
    end
  end

  @doc """
  Seconds to wait after `attempt_number` failed, with full jitter.

  Options: `:jitter` (a function of the ceiling), `:retry_after` (integer
  seconds or a header value). A valid Retry-After replaces the schedule,
  clamped by `ClientError.parse_retry_after/1`.
  """
  @spec backoff_seconds(pos_integer(), keyword()) :: non_neg_integer()
  def backoff_seconds(attempt_number, opts \\ [])
      when is_integer(attempt_number) and attempt_number >= 1 do
    case parse_retry_after(Keyword.get(opts, :retry_after)) do
      seconds when is_integer(seconds) ->
        seconds

      nil ->
        ceiling = backoff_ceiling(attempt_number)
        jitter = Keyword.get(opts, :jitter, &full_jitter/1)
        jitter.(ceiling)
    end
  end

  @doc "The unjittered ceiling for `attempt_number`, in seconds."
  @spec backoff_ceiling(pos_integer()) :: non_neg_integer()
  def backoff_ceiling(attempt_number) when is_integer(attempt_number) and attempt_number >= 1 do
    Enum.at(@schedule, attempt_number - 1) || List.last(@schedule)
  end

  @doc "Parses and clamps a Retry-After hint using the Pumble classifier bounds."
  @spec parse_retry_after(term()) :: pos_integer() | nil
  def parse_retry_after(value) when is_integer(value) and value >= 0 do
    ClientError.parse_retry_after(Integer.to_string(value))
  end

  def parse_retry_after(value), do: ClientError.parse_retry_after(value)

  @doc "Sanitized attempt diagnostics, including retry and uncertainty facts."
  @spec diagnostics(Outcome.t(), map()) :: map()
  def diagnostics(%Outcome{} = outcome, snapshot) when is_map(snapshot) do
    operation = operation_summary(snapshot)

    scalar_output(outcome.output)
    |> Map.merge(%{
      "kind" => Atom.to_string(outcome.kind),
      "message" => outcome.message,
      "error_class" => outcome.error_class,
      "effect_key" => Map.get(snapshot, :effect_key),
      "attempt" => Map.get(snapshot, :attempt_number),
      "operation" => operation,
      "request_summary" => operation,
      "retry_at" => encode_time(outcome.resume_at),
      "guidance" => guidance(outcome)
    })
    |> Map.merge(dispatch_facts(outcome))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Error.sanitize()
  end

  @doc "Turns a domain error that escaped the runner into a persistable outcome."
  @spec outcome_for_error(Error.t()) :: Outcome.t()
  def outcome_for_error(%Error{} = error) do
    {kind, class} =
      cond do
        error.code == :unknown_node_type ->
          {:permanent_error, "internal_invariant"}

        error.retryable? ->
          {:retryable_error, class_name(error.class)}

        true ->
          {:permanent_error, class_name(error.class)}
      end

    {:ok, outcome} =
      Outcome.new(%{
        kind: kind,
        error_class: class,
        message: error.message
      })

    outcome
  end

  @doc "Classifies a raised exception as an internal retryable outcome."
  @spec wrap_exception(Exception.t()) :: Outcome.t()
  def wrap_exception(exception) do
    wrap_internal(%{"exception" => inspect(exception.__struct__)})
  end

  @doc "Classifies a throw or exit as an internal retryable outcome."
  @spec wrap_throw(atom(), term()) :: Outcome.t()
  def wrap_throw(kind, _reason) do
    wrap_internal(%{"kind" => inspect(kind)})
  end

  defp apply_retryable(outcome, snapshot, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    attempt = Map.get(snapshot, :attempt_number) || 1
    safety = retry_safety(snapshot)
    retry_after = retry_after_from(outcome, opts)

    disposition =
      decide(%{
        error_class: outcome.error_class,
        retry_safety: safety,
        attempt_number: attempt
      })

    case disposition do
      :retry ->
        delay = backoff_seconds(attempt, Keyword.merge(opts, retry_after: retry_after))
        %{outcome | resume_at: DateTime.add(now, delay, :second)}

      :pause_uncertain ->
        %{outcome | kind: :uncertain, resume_at: nil}

      :cancel ->
        %{outcome | kind: :cancelled, resume_at: nil}

      :fail ->
        %{
          outcome
          | kind: :permanent_error,
            resume_at: nil,
            message: exhaustion_message(outcome, attempt)
        }
    end
  end

  defp exhaustion_message(outcome, attempt) when is_integer(attempt) do
    if attempt >= max_attempts() do
      "The step was retried the maximum number of times."
    else
      outcome.message
    end
  end

  defp exhaustion_message(outcome, _attempt), do: outcome.message

  defp retry_after_from(outcome, opts) do
    Keyword.get(opts, :retry_after) ||
      output_retry_after(outcome.output)
  end

  defp output_retry_after(%{"retry_after" => value}), do: value
  defp output_retry_after(%{retry_after: value}), do: value
  defp output_retry_after(_output), do: nil

  defp full_jitter(ceiling) when is_integer(ceiling) and ceiling <= 0, do: 0
  defp full_jitter(ceiling) when is_integer(ceiling), do: :rand.uniform(ceiling + 1) - 1

  defp safety_for(type, node) do
    case operations(node) do
      [] ->
        http_or_registry(type, node)

      operations ->
        operations
        |> Enum.map(&Client.retry_safety/1)
        |> strictest()
    end
  end

  defp http_or_registry(:http_action, node), do: http_safety(node)
  defp http_or_registry(type, _node), do: registry_safety(type)

  defp http_safety(node) do
    config = config(node)
    method = http_method(config)

    cond do
      method in ["get", "head"] ->
        :read_only

      http_idempotent_contract?(config) ->
        :idempotent_effect

      true ->
        :not_idempotent
    end
  end

  defp http_method(config) do
    case Map.get(config, "method") do
      value when is_atom(value) -> value |> Atom.to_string() |> String.downcase()
      value when is_binary(value) -> String.downcase(value)
      _other -> nil
    end
  end

  defp http_idempotent_contract?(config) do
    header = Map.get(config, "idempotency_header")
    is_binary(header) and header != ""
  end

  defp registry_safety(type) do
    case NodeRegistry.spec(type) do
      {:ok, spec} -> spec.retry_safety
      {:error, _reason} -> :not_idempotent
    end
  end

  defp operations(node) do
    requires = Map.get(node, :requires) || Map.get(node, "requires") || %{}
    names = Map.get(requires, "operations") || []

    if names == [] do
      operations_from_action(node)
    else
      Enum.flat_map(List.wrap(names), &existing_operation/1)
    end
  end

  defp operations_from_action(node) do
    case config(node) |> Map.get("action") do
      "send_message" -> [:post_message]
      "reply_message" -> [:reply]
      "direct_message" -> [:get_direct_channel, :create_direct_channel, :send_direct_message]
      "add_reaction" -> [:add_reaction]
      "remove_reaction" -> [:remove_reaction]
      _other -> []
    end
  end

  defp existing_operation(name) when is_atom(name), do: [name]

  defp existing_operation(name) when is_binary(name) do
    case Enum.find(Client.operations(), &(Atom.to_string(&1) == name)) do
      nil -> []
      operation -> [operation]
    end
  end

  defp existing_operation(_name), do: []

  defp strictest(safeties) do
    cond do
      :not_idempotent in safeties -> :not_idempotent
      :idempotent_effect in safeties -> :idempotent_effect
      true -> :read_only
    end
  end

  defp config(%{config: config}) when is_map(config), do: config
  defp config(_node), do: %{}

  defp operation_summary(snapshot) do
    node = Map.get(snapshot, :compiled_node) || %{}
    type = Map.get(node, :type)

    case type do
      :pumble_action ->
        "pumble #{config(node) |> Map.get("action") || "action"}"

      :http_action ->
        method = config(node) |> Map.get("method") || "http"
        host = http_host(config(node) |> Map.get("url"))
        Enum.join(Enum.reject(["http", to_string(method), host], &(&1 in [nil, ""])), " ")

      type when is_atom(type) ->
        Atom.to_string(type)

      _other ->
        nil
    end
  end

  defp http_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> nil
    end
  end

  defp http_host(_url), do: nil

  defp dispatch_facts(%Outcome{} = outcome) do
    case dispatch_evidence(outcome) do
      :confirmed ->
        %{
          "dispatch_state" => "confirmed",
          "dispatched" => true,
          "bytes_may_have_left" => true
        }
        |> put_duplicate_risk(outcome)

      :not_sent ->
        %{
          "dispatch_state" => "not_sent",
          "dispatched" => false,
          "bytes_may_have_left" => false
        }
        |> put_duplicate_risk(outcome)

      :possibly_sent ->
        %{
          "dispatch_state" => "possibly_sent",
          "bytes_may_have_left" => true
        }
        |> put_duplicate_risk(outcome)

      :unknown ->
        %{"dispatch_state" => "unknown"}
        |> put_duplicate_risk(outcome)
    end
  end

  defp dispatch_evidence(%Outcome{output: %{"status" => status}}) when is_integer(status),
    do: :confirmed

  defp dispatch_evidence(%Outcome{output: %{"remote_status" => status}})
       when is_integer(status),
       do: :confirmed

  defp dispatch_evidence(%Outcome{remote_reference: reference})
       when is_binary(reference) and reference != "",
       do: :confirmed

  defp dispatch_evidence(%Outcome{output: %{"request_written" => true}}),
    do: :possibly_sent

  defp dispatch_evidence(%Outcome{output: %{"request_written" => false}}),
    do: :not_sent

  defp dispatch_evidence(%Outcome{}), do: :unknown

  defp put_duplicate_risk(facts, %Outcome{kind: kind, error_class: class, output: output}) do
    if output["duplicate_risk"] == true or kind == :uncertain or
         class_name(class) in @uncertain_classes do
      Map.put(facts, "duplicate_risk", true)
    else
      facts
    end
  end

  defp guidance(%Outcome{kind: :uncertain}) do
    "An operator must resolve this step. Automatic retry is disabled."
  end

  defp guidance(%Outcome{kind: :retryable_error, resume_at: %DateTime{}}) do
    "The step will retry automatically."
  end

  defp guidance(%Outcome{kind: :permanent_error}) do
    "The step will not retry."
  end

  defp guidance(_outcome), do: nil

  defp encode_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp encode_time(_time), do: nil

  defp scalar_output(output) when is_map(output) and not is_struct(output) do
    output
    |> Enum.filter(fn {_key, value} ->
      is_binary(value) or is_number(value) or is_boolean(value)
    end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp scalar_output(_output), do: %{}

  defp wrap_internal(output) do
    {:ok, outcome} =
      Outcome.new(%{
        kind: :retryable_error,
        error_class: "internal",
        message: "The step failed internally.",
        output: output
      })

    outcome
  end

  defp bucket(class) when class in @cancel_classes, do: :cancel
  defp bucket(class) when class in @permanent_classes, do: :fail
  defp bucket(class) when class in @uncertain_classes, do: :uncertain
  defp bucket(class) when class in @retry_classes, do: :retry
  defp bucket(_class), do: :fail

  defp bound_attempts(:uncertain, :not_idempotent, _attempt), do: :pause_uncertain
  defp bound_attempts(:uncertain, _safety, attempt), do: bound_retry(attempt)
  defp bound_attempts(:retry, _safety, attempt), do: bound_retry(attempt)
  defp bound_attempts(other, _safety, _attempt), do: other

  defp bound_retry(attempt) when is_integer(attempt) do
    if attempt >= max_attempts(), do: :fail, else: :retry
  end

  defp bound_retry(_attempt), do: :retry

  defp class_name(nil), do: "internal"
  defp class_name(class) when is_atom(class), do: Atom.to_string(class)
  defp class_name(class) when is_binary(class), do: class
  defp class_name(_class), do: "internal_invariant"

  defp attr(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
