defmodule PumbleAutomation.Executions.DryRun do
  @moduledoc """
  A side-effect-free preview of a compiled workflow.

  `run/2` walks the same compiled graph live execution uses, evaluates pure
  nodes, and asks effectful nodes for a redacted would-send summary. It does
  not decrypt secrets, call Pumble, call external HTTP, insert jobs, or
  mutate an active workflow. Sample trigger data stays in memory for the
  call and is not persisted.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Context
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Templates

  @approval_edges ~w(approved rejected timed_out)
  @would_send_keys ~w(
    operation adapter method url header_names body_bytes text_bytes blocks_count
    channel_id user_id message_id thread_root_id reaction skin_tone as
    connection_id wait_seconds timeout_seconds simulated_edge dry_run
  )

  @type result :: %{
          status: String.t(),
          compiler_version: String.t(),
          required_scopes: [String.t()],
          definition_hash: String.t() | nil,
          trace: [map()]
        }

  @doc """
  Previews `source` against sample trigger data.

  `source` is a `%CompiledWorkflow{}` or the encoded document live execution
  decodes. `attrs` may name:

    * `:sample` — the trigger snapshot (default `%{}`)
    * `:workspace` / `:actor` — optional `id` values for the resolution tree
    * `:approval_edge` — `"approved"`, `"rejected"`, or `"timed_out"` when
      simulating an approval boundary (default `"approved"`)
    * `:installation_id` — unused for credentials; present only so runner
      input matches the live shape
  """
  @spec run(CompiledWorkflow.t() | map(), map()) :: {:ok, result()} | {:error, Error.t()}
  def run(source, attrs \\ %{})

  def run(source, attrs) when is_map(attrs) do
    with {:ok, compiled} <- load(source),
         {:ok, request} <- parse(attrs),
         :ok <- check_compiler(compiled) do
      preview(compiled, request)
    end
  end

  defp load(%CompiledWorkflow{} = compiled) do
    compiled |> CompiledWorkflow.encode() |> CompiledWorkflow.decode()
  end

  defp load(document) when is_map(document), do: CompiledWorkflow.decode(document)

  defp parse(attrs) do
    with {:ok, sample} <- parse_sample(attrs),
         {:ok, approval_edge} <- parse_approval_edge(attrs) do
      {:ok,
       %{
         sample: sample,
         workspace: identity(attr(attrs, :workspace)),
         actor: identity(attr(attrs, :actor)),
         approval_edge: approval_edge,
         installation_id: installation_id(attrs),
         preview_id: Ecto.UUID.generate()
       }}
    end
  end

  defp parse_sample(attrs) do
    sample = attr(attrs, :sample) || %{}

    cond do
      not is_map(sample) or is_struct(sample) ->
        {:error, invalid_sample("Sample trigger data must be an object.")}

      not Execution.json_within?(sample, Execution.max_context_bytes()) ->
        {:error, invalid_sample("Sample trigger data is too large.")}

      true ->
        {:ok, Error.sanitize(sample)}
    end
  end

  defp parse_approval_edge(attrs) do
    case attr(attrs, :approval_edge) || "approved" do
      edge when edge in @approval_edges ->
        {:ok, edge}

      _other ->
        {:error,
         Error.new(:validation, :invalid_approval_edge,
           message: "An approval preview must name approved, rejected, or timed_out."
         )}
    end
  end

  defp check_compiler(%CompiledWorkflow{compiler_version: version}) do
    if version == CompiledWorkflow.compiler_version() do
      :ok
    else
      {:error,
       Error.new(:conflict, :unsupported_compiler_version,
         message: "This workflow was compiled by a version that is no longer supported."
       )}
    end
  end

  defp preview(compiled, request) do
    state = %{
      compiled: compiled,
      request: request,
      context: initial_context(request),
      trace: [],
      status: "completed"
    }

    finish(visit(compiled.entry_node_id, state))
  end

  defp visit(node_id, state) do
    cond do
      node_id == CompiledWorkflow.end_target() ->
        state

      length(state.trace) >= path_cap(state.compiled) ->
        overflow(state)

      true ->
        evaluate_node(node_id, state)
    end
  end

  defp evaluate_node(node_id, state) do
    case Map.fetch(state.compiled.nodes, node_id) do
      {:ok, node} ->
        run_node(node_id, node, state)

      :error ->
        %{state | status: "failed", trace: state.trace ++ [missing_node(node_id)]}
    end
  end

  defp run_node(node_id, node, state) do
    input = runner_input(node_id, node, state)

    case NodeRunner.run(input) do
      {:ok, %Outcome{} = outcome} ->
        record_and_advance(node_id, node, outcome, state)

      {:error, %Error{} = error} ->
        %{state | status: "failed", trace: state.trace ++ [internal_step(node_id, node, error)]}
    end
  end

  defp record_and_advance(node_id, node, outcome, state) do
    step = trace_step(node_id, node, outcome, state)
    state = %{state | trace: state.trace ++ [step]}

    case merge_output(state.context, node_id, outcome) do
      {:ok, context} ->
        advance(node, outcome, %{state | context: context})

      {:error, :context_overflow} ->
        overflow(%{state | status: "failed"})
    end
  end

  defp advance(node, %Outcome{kind: :success} = outcome, state) do
    follow(node.edges, outcome.edge, state)
  end

  defp advance(node, %Outcome{kind: :wait_delay}, state) do
    follow(node.edges, Outcome.linear(), state)
  end

  defp advance(node, %Outcome{kind: :wait_approval}, state) do
    follow(node.edges, state.request.approval_edge, state)
  end

  defp advance(_node, %Outcome{kind: :permanent_error} = outcome, state) do
    %{state | status: status_for(outcome)}
  end

  defp advance(_node, _outcome, state), do: %{state | status: "failed"}

  defp follow(edges, label, state) do
    case Outcome.follow(edges, label) do
      {:ok, :end} ->
        state

      {:ok, {:continue, next_id}} ->
        visit(next_id, state)

      {:error, %Error{}} ->
        %{state | status: "failed"}
    end
  end

  defp merge_output(context, node_id, %Outcome{kind: kind, output: output})
       when kind in [:success, :wait_delay, :wait_approval] do
    steps = Map.get(context, "steps") || %{}

    if Map.has_key?(steps, node_id) do
      {:ok, context}
    else
      merged = Map.put(context, "steps", Map.put(steps, node_id, %{"output" => output}))

      if Execution.json_within?(merged, Execution.max_context_bytes()) and
           Execution.sanitized_map?(merged) do
        {:ok, merged}
      else
        {:error, :context_overflow}
      end
    end
  end

  defp merge_output(context, _node_id, _outcome), do: {:ok, context}

  defp finish(state) do
    {:ok,
     %{
       status: state.status,
       compiler_version: state.compiled.compiler_version,
       required_scopes: state.compiled.required_scopes,
       definition_hash: state.compiled.definition_hash,
       trace: state.trace
     }}
  end

  defp runner_input(node_id, node, state) do
    %{
      compiled_node: node,
      context: state.context,
      trigger_snapshot: state.request.sample,
      installation_id: state.request.installation_id,
      run_mode: "dry_run",
      effect_key: "dry-run/#{state.request.preview_id}/#{node_id}",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: %{}
    }
  end

  defp initial_context(request) do
    %{
      "execution" => %{"id" => request.preview_id, "run_mode" => "dry_run"},
      "workspace" => request.workspace,
      "actor" => request.actor,
      "steps" => %{}
    }
  end

  defp trace_step(node_id, node, outcome, state) do
    tree =
      Context.tree(%{context: state.context, trigger_snapshot: state.request.sample})

    %{
      "node_id" => node_id,
      "type" => type_name(node.type),
      "kind" => Atom.to_string(outcome.kind),
      "edge" => edge_for(node, outcome, state),
      "branch" => branch_for(node, outcome, state),
      "references" => references(node.config, tree),
      "issues" => issues(outcome),
      "would_send" => would_send(node, outcome, state),
      "output" => Error.sanitize(outcome.output)
    }
  end

  defp edge_for(_node, %Outcome{kind: :wait_approval}, state), do: state.request.approval_edge
  defp edge_for(_node, %Outcome{edge: edge}, _state), do: edge

  defp branch_for(%{type: :condition}, %Outcome{edge: edge}, _state), do: edge
  defp branch_for(%{type: :approval}, _outcome, state), do: state.request.approval_edge
  defp branch_for(_node, _outcome, _state), do: nil

  defp would_send(%{type: type}, outcome, state)
       when type in [:pumble_action, :http_action, :delay, :approval] do
    outcome.output
    |> Map.take(@would_send_keys)
    |> put_present("simulated_edge", simulated_edge(type, state))
    |> Error.sanitize()
    |> empty_to_nil()
  end

  defp would_send(_node, _outcome, _state), do: nil

  defp simulated_edge(:approval, state), do: state.request.approval_edge
  defp simulated_edge(_type, _state), do: nil

  defp issues(%Outcome{kind: :permanent_error} = outcome) do
    [
      %{
        "code" => outcome.error_class || "validation",
        "severity" => "error",
        "message" => outcome.message || "This step could not be previewed."
      }
      |> put_present("field", outcome.output["field"])
      |> put_present("path", outcome.output["path"])
    ]
  end

  defp issues(_outcome), do: []

  defp references(config, tree) do
    config
    |> collect_paths(tree)
    |> Enum.uniq()
  end

  defp collect_paths(value, tree) when is_map(value) and not is_struct(value) do
    case Templates.render(value, tree) do
      {:ok, %{used_paths: paths}} -> paths
      {:error, _error} -> Enum.flat_map(Map.values(value), &collect_paths(&1, tree))
    end
  end

  defp collect_paths(value, tree) when is_list(value) do
    Enum.flat_map(value, &collect_paths(&1, tree))
  end

  defp collect_paths(value, tree) when is_binary(value) do
    case Templates.render(value, tree) do
      {:ok, %{used_paths: paths}} -> paths
      {:error, _error} -> []
    end
  end

  defp collect_paths(_value, _tree), do: []

  defp status_for(%Outcome{error_class: class}) when class in ["validation", "resource_limit"] do
    "preview_issue"
  end

  defp status_for(_outcome), do: "failed"

  defp overflow(state) do
    %{state | status: "failed", trace: state.trace ++ [overflow_step()]}
  end

  defp overflow_step do
    %{
      "node_id" => nil,
      "type" => nil,
      "kind" => "permanent_error",
      "edge" => nil,
      "branch" => nil,
      "references" => [],
      "issues" => [
        %{
          "code" => "resource_limit",
          "severity" => "error",
          "message" => "The preview exceeded the compiled path length."
        }
      ],
      "would_send" => nil,
      "output" => %{}
    }
  end

  defp missing_node(node_id) do
    %{
      "node_id" => node_id,
      "type" => nil,
      "kind" => "permanent_error",
      "edge" => nil,
      "branch" => nil,
      "references" => [],
      "issues" => [
        %{
          "code" => "internal",
          "severity" => "error",
          "message" => "The compiled workflow does not name that step."
        }
      ],
      "would_send" => nil,
      "output" => %{}
    }
  end

  defp internal_step(node_id, node, %Error{} = error) do
    %{
      "node_id" => node_id,
      "type" => type_name(node.type),
      "kind" => "permanent_error",
      "edge" => nil,
      "branch" => nil,
      "references" => [],
      "issues" => [
        %{
          "code" => Atom.to_string(error.code),
          "severity" => "error",
          "message" => error.message
        }
      ],
      "would_send" => nil,
      "output" => %{}
    }
  end

  defp path_cap(%CompiledWorkflow{} = compiled) do
    case compiled.max_path_length do
      n when is_integer(n) and n > 0 -> min(n, Limits.max_nodes())
      _other -> Limits.max_nodes()
    end
  end

  defp identity(%{"id" => id}) when is_binary(id) and id != "", do: %{"id" => id}
  defp identity(id) when is_binary(id) and id != "", do: %{"id" => id}
  defp identity(_other), do: %{}

  defp installation_id(attrs) do
    case attr(attrs, :installation_id) do
      id when is_binary(id) and id != "" -> id
      _missing -> Ecto.UUID.generate()
    end
  end

  defp type_name(type) when is_atom(type), do: Atom.to_string(type)
  defp type_name(type) when is_binary(type), do: type
  defp type_name(_type), do: nil

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp invalid_sample(message) do
    Error.new(:validation, :invalid_sample, message: message)
  end
end
