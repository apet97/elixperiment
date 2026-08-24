defmodule PumbleAutomation.Diagnostics.Export do
  @moduledoc """
  Bounded, allowlisted support bundles for one tenant.

  An owner names an execution or a time window. The bundle carries application
  version, installation status, scope names, workflow hashes, a sanitized
  timeline, error codes, provider IDs, job IDs, timings, and limits. It never
  reads a secret value, a token, a raw body, message text, a session digest, or
  another tenant.

  A ZIP is written only so the bytes can be hashed and expired. Generation
  failure deletes any partial file. `cleanup_expired/1` removes leftover
  artifacts.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.History
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @table :pumble_automation_diagnostic_artifacts
  @capability :destructive_lifecycle
  @schema_version 1
  @default_ttl_seconds 900
  @max_ttl_seconds 3_600
  @default_window_seconds 7 * 24 * 3_600
  @default_max_executions 20
  @default_max_bytes 256 * 1024
  @max_jobs_per_execution 50
  @bundle_name ~c"bundle.json"
  @zip_name ~c"bundle.zip"

  @forbidden_keys MapSet.new([
                    "authorization",
                    "bearer",
                    "body",
                    "content",
                    "cookie",
                    "credential",
                    "diagnostics",
                    "encrypted_bot_token",
                    "message",
                    "nonce",
                    "passwd",
                    "password",
                    "payload",
                    "private",
                    "raw",
                    "rendered",
                    "secret",
                    "template",
                    "text",
                    "token",
                    "token_digest",
                    "token_key_version"
                  ])

  @type result :: %{
          artifact_id: Ecto.UUID.t(),
          artifact_path: String.t(),
          bundle: map(),
          bytes: non_neg_integer(),
          digest: String.t(),
          expires_at: DateTime.t(),
          field_names: [String.t()],
          signature: String.t()
        }

  @doc "Creates the artifact ETS table. Safe to call more than once."
  @spec setup() :: :ok
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        _table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  end

  @doc "Default time-to-live for a stored ZIP, in seconds."
  @spec artifact_ttl_seconds() :: pos_integer()
  def artifact_ttl_seconds, do: config(:artifact_ttl_seconds, @default_ttl_seconds)

  @doc "Greatest execution window an owner may request, in seconds."
  @spec max_window_seconds() :: pos_integer()
  def max_window_seconds, do: config(:max_window_seconds, @default_window_seconds)

  @doc "Greatest number of executions a time-window export may include."
  @spec max_executions() :: pos_integer()
  def max_executions, do: config(:max_executions, @default_max_executions)

  @doc "Greatest encoded JSON size of a bundle, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: config(:max_bytes, @default_max_bytes)

  @doc """
  Builds, hashes, and optionally stores one tenant-scoped support bundle.

  Options: `:execution_id`, `:from`, `:until`, `:persist` (default true),
  `:ttl_seconds`, `:now`. An execution id or both ends of a time window are
  required.
  """
  @spec generate(Scope.t(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def generate(%Scope{} = scope, opts \\ []) do
    setup()
    _ = cleanup_expired(now: Keyword.get(opts, :now, DateTime.utc_now()))

    with :ok <- Policy.authorize(scope, @capability),
         {:ok, selection} <- parse_selection(opts),
         {:ok, installation} <- fetch_installation(scope.installation_id),
         {:ok, timelines, truncated?} <- load_timelines(scope, selection),
         bundle <- build_bundle(scope, installation, selection, timelines, truncated?),
         {:ok, json} <- encode_bundle(bundle),
         {:ok, zip} <- zip_bundle(json) do
      maybe_persist(scope, installation, bundle, zip, opts)
    end
  end

  @doc """
  Returns the stored ZIP for `artifact_id` when it still belongs to `scope`.

  Expired, missing, and foreign ids are the same `:not_found` error.
  """
  @spec read_artifact(Scope.t(), Ecto.UUID.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_artifact(%Scope{} = scope, artifact_id) do
    with :ok <- Policy.authorize(scope, @capability),
         {:ok, uuid} <- cast_uuid(artifact_id),
         {:ok, path} <- artifact_path_for(scope.installation_id, uuid) do
      case read_file(path) do
        {:ok, bytes} ->
          {:ok, bytes}

        {:error, _reason} ->
          _ = discard(uuid)
          {:error, Policy.not_found()}
      end
    end
  end

  @doc "Deletes expired ZIP files and registry rows. Returns how many were removed."
  @spec cleanup_expired(keyword()) :: {:ok, non_neg_integer()}
  def cleanup_expired(opts \\ []) do
    setup()
    now = Keyword.get(opts, :now, DateTime.utc_now())
    removed = Enum.reduce(expired_ids(now), 0, &delete_one/2)
    {:ok, removed}
  rescue
    _exception -> {:ok, 0}
  catch
    _kind, _reason -> {:ok, 0}
  end

  defp parse_selection(opts) do
    with {:ok, execution_id} <- optional_uuid(Keyword.get(opts, :execution_id)),
         {:ok, from} <- optional_time(Keyword.get(opts, :from)),
         {:ok, until} <- optional_time(Keyword.get(opts, :until)),
         :ok <- require_selection(execution_id, from, until),
         :ok <- validate_window(execution_id, from, until) do
      {:ok, %{execution_id: execution_id, from: from, until: until}}
    end
  end

  defp require_selection(nil, from, until) when is_nil(from) or is_nil(until) do
    {:error,
     Error.new(:validation, :selection_required,
       message: "Select an execution or both ends of a time window."
     )}
  end

  defp require_selection(_execution_id, _from, _until), do: :ok

  defp validate_window(nil, %DateTime{} = from, %DateTime{} = until) do
    cond do
      DateTime.compare(until, from) == :lt ->
        {:error,
         Error.new(:validation, :window_inverted,
           message: "The time window ends before it starts."
         )}

      DateTime.diff(until, from, :second) > max_window_seconds() ->
        {:error,
         Error.new(:validation, :window_too_large,
           message: "The time window is longer than the diagnostic export allows."
         )}

      true ->
        :ok
    end
  end

  defp validate_window(_execution_id, _from, _until), do: :ok

  defp fetch_installation(installation_id) do
    query =
      from i in Installation,
        where: i.id == ^installation_id,
        select: %{
          id: i.id,
          status: i.status,
          pumble_workspace_id: i.pumble_workspace_id,
          bot_user_id: i.bot_user_id,
          bot_scopes: i.bot_scopes,
          user_scopes: i.user_scopes,
          bot_scopes: i.bot_scopes,
          user_scopes: i.user_scopes
        }

    case Repo.one(query) do
      %{id: _} = installation -> {:ok, installation}
      nil -> {:error, Policy.not_found()}
    end
  end

  defp load_timelines(%Scope{} = scope, %{execution_id: execution_id})
       when is_binary(execution_id) do
    case History.get_detail(scope, execution_id) do
      {:ok, detail} -> {:ok, [sanitize_detail(detail)], false}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp load_timelines(%Scope{} = scope, %{from: %DateTime{} = from, until: %DateTime{} = until}) do
    limit = max_executions()

    case History.list_index(scope, from: from, until: until, limit: limit) do
      {:ok, %{entries: entries, next_cursor: cursor}} ->
        collect_details(scope, entries, not is_nil(cursor))

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp load_timelines(_scope, _selection) do
    {:error,
     Error.new(:validation, :selection_required,
       message: "Select an execution or both ends of a time window."
     )}
  end

  defp collect_details(scope, entries, truncated?) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case History.get_detail(scope, entry.id) do
        {:ok, detail} -> {:cont, {:ok, [sanitize_detail(detail) | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, details} -> {:ok, Enum.reverse(details), truncated?}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp build_bundle(scope, installation, selection, timelines, truncated?) do
    timelines = attach_hashes(timelines, scope.installation_id)
    execution_ids = Enum.map(timelines, & &1["id"])

    %{
      "schema_version" => @schema_version,
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "selection" => %{
        "execution_id" => selection.execution_id,
        "from" => encode_time(selection.from),
        "until" => encode_time(selection.until),
        "truncated" => truncated?
      },
      "application" => %{
        "name" => "pumble_automation",
        "version" => application_version()
      },
      "installation" => %{
        "id" => installation.id,
        "status" => installation.status,
        "workspace_id" => installation.pumble_workspace_id,
        "bot_user_id" => installation.bot_user_id,
        "bot_scopes" => installation.bot_scopes || [],
        "user_scopes" => installation.user_scopes || []
      },
      "workflows" => workflow_hashes(scope.installation_id),
      "executions" => timelines,
      "jobs" => job_rows(scope.installation_id, execution_ids),
      "limits" => limit_snapshot()
    }
    |> drop_forbidden()
  end

  defp attach_hashes(timelines, installation_id) do
    ids =
      timelines
      |> Enum.map(& &1["workflow_version_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    hashes = version_hashes(installation_id, ids)

    Enum.map(timelines, fn row ->
      Map.put(row, "definition_hash", Map.get(hashes, row["workflow_version_id"]))
    end)
  end

  defp version_hashes(_installation_id, []), do: %{}

  defp version_hashes(installation_id, ids) do
    from(v in WorkflowVersion,
      where: v.installation_id == ^installation_id,
      where: v.id in ^ids,
      select: {v.id, v.definition_hash}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp workflow_hashes(installation_id) do
    Repo.all(
      from w in Workflow,
        left_join: v in WorkflowVersion,
        on: v.id == w.active_version_id and v.installation_id == w.installation_id,
        where: w.installation_id == ^installation_id,
        order_by: [asc: w.name, asc: w.id],
        select: %{
          id: w.id,
          name: w.name,
          status: w.status,
          active_version_id: w.active_version_id,
          active_version_number: v.version_number,
          definition_hash: v.definition_hash
        }
    )
    |> Enum.map(fn row ->
      %{
        "id" => row.id,
        "name" => row.name,
        "status" => row.status,
        "active_version_id" => row.active_version_id,
        "active_version_number" => row.active_version_number,
        "definition_hash" => row.definition_hash
      }
    end)
  end

  defp job_rows(_installation_id, []), do: []

  defp job_rows(installation_id, execution_ids) do
    Enum.flat_map(execution_ids, fn execution_id ->
      jobs =
        Repo.all(
          from j in Oban.Job,
            where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id),
            where: fragment("? ->> 'execution_id' = ?", j.args, ^execution_id),
            order_by: [desc: j.id],
            limit: ^@max_jobs_per_execution,
            select: %{
              id: j.id,
              state: j.state,
              worker: j.worker,
              queue: j.queue,
              scheduled_at: j.scheduled_at,
              attempted_at: j.attempted_at,
              completed_at: j.completed_at
            }
        )

      Enum.map(jobs, &encode_job(&1, execution_id))
    end)
  end

  defp encode_job(job, execution_id) do
    %{
      "id" => job.id,
      "execution_id" => execution_id,
      "state" => job.state,
      "worker" => job.worker,
      "queue" => job.queue,
      "scheduled_at" => encode_time(job.scheduled_at),
      "attempted_at" => encode_time(job.attempted_at),
      "completed_at" => encode_time(job.completed_at)
    }
  end

  defp limit_snapshot do
    Map.new(Limits.keys(), fn key -> {Atom.to_string(key), Limits.get(key)} end)
  end

  defp sanitize_detail(%{execution: header, steps: steps}) do
    %{
      "id" => header.id,
      "status" => header.status,
      "inserted_at" => encode_time(header.inserted_at),
      "updated_at" => encode_time(header.updated_at),
      "workflow_id" => header.workflow_id,
      "workflow_name" => header.workflow_name,
      "workflow_version_id" => header.workflow_version_id,
      "version_number" => header.version_number,
      "execution_key" => header.execution_key,
      "current_node_id" => header.current_node_id,
      "current_node_type" => header.current_node_type,
      "run_mode" => header.run_mode,
      "trigger_type" => header.trigger_type,
      "correlation_id" => header.correlation_id,
      "trigger_occurred_at" => header.trigger_occurred_at,
      "trigger_channel_id" => header.trigger_channel_id,
      "trigger_actor_id" => header.trigger_actor_id,
      "trigger_resource_id" => header.trigger_resource_id,
      "trigger_thread_root_id" => header.trigger_thread_root_id,
      "cancelled_at" => encode_time(header.cancelled_at),
      "cancellation_reason" => header.cancellation_reason,
      "steps" => Enum.map(steps, &sanitize_step/1)
    }
  end

  defp sanitize_step(step) do
    %{
      "id" => step.id,
      "node_id" => step.node_id,
      "node_type" => step.node_type,
      "status" => step.status,
      "selected_edge" => step.selected_edge,
      "remote_reference" => step.remote_reference,
      "uncertainty_reason" => step.uncertainty_reason,
      "attempt_count" => step.attempt_count,
      "inserted_at" => encode_time(step.inserted_at),
      "updated_at" => encode_time(step.updated_at),
      "resume_at" => step.resume_at,
      "expires_at" => step.expires_at,
      "output_message_id" => step.output_message_id,
      "output_channel_id" => step.output_channel_id,
      "output_user_id" => step.output_user_id,
      "output_status" => step.output_status,
      "attempts" => Enum.map(Map.get(step, :attempts, []), &sanitize_attempt/1),
      "approval" => sanitize_approval(Map.get(step, :approval))
    }
  end

  defp sanitize_attempt(attempt) do
    %{
      "id" => attempt.id,
      "attempt_number" => attempt.attempt_number,
      "status" => attempt.status,
      "error_class" => attempt.error_class,
      "error_code" => attempt.error_code,
      "remote_status" => attempt.remote_status,
      "remote_request_id" => attempt.remote_request_id,
      "oban_job_id" => Map.get(attempt, :oban_job_id),
      "duration_ms" => attempt.duration_ms,
      "retry_at" => encode_time(attempt.retry_at),
      "started_at" => encode_time(attempt.started_at),
      "ended_at" => encode_time(attempt.ended_at)
    }
  end

  defp sanitize_approval(nil), do: nil

  defp sanitize_approval(approval) do
    %{
      "id" => approval.id,
      "status" => approval.status,
      "expires_at" => encode_time(approval.expires_at),
      "decided_at" => encode_time(approval.decided_at),
      "decided_by_pumble_user_id" => approval.decided_by_pumble_user_id,
      "pumble_channel_id" => approval.pumble_channel_id,
      "pumble_message_id" => approval.pumble_message_id
    }
  end

  defp encode_bundle(bundle) do
    case Jason.encode(bundle) do
      {:ok, json} ->
        if byte_size(json) <= max_bytes() do
          {:ok, json}
        else
          {:error,
           Error.new(:validation, :diagnostics_too_large,
             message: "The diagnostic bundle is larger than the export allows."
           )}
        end

      {:error, _reason} ->
        {:error,
         Error.new(:internal, :diagnostics_encode_failed,
           message: "The diagnostic bundle could not be encoded."
         )}
    end
  end

  defp zip_bundle(json) when is_binary(json) do
    case :zip.create(@zip_name, [{@bundle_name, json}], [:memory]) do
      {:ok, {_name, zip}} when is_binary(zip) ->
        {:ok, zip}

      {:error, _reason} ->
        {:error,
         Error.new(:internal, :diagnostics_zip_failed,
           message: "The diagnostic bundle could not be packaged."
         )}
    end
  end

  defp maybe_persist(scope, installation, bundle, zip, opts) do
    digest = hex_hash(zip)
    signature = hex_mac(zip)
    field_names = included_fields(bundle)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    expires_at = DateTime.add(now, ttl_seconds(opts), :second)

    result = %{
      artifact_id: nil,
      artifact_path: nil,
      bundle: bundle,
      bytes: byte_size(zip),
      digest: digest,
      expires_at: expires_at,
      field_names: field_names,
      signature: signature
    }

    if Keyword.get(opts, :persist, true) do
      persist_and_audit(scope, installation, zip, result)
    else
      {:ok, result}
    end
  end

  defp persist_and_audit(scope, installation, zip, result) do
    artifact_id = Ecto.UUID.generate()
    dir = tmp_dir()
    zip_path = zip_path(dir, artifact_id)
    meta_path = meta_path(dir, artifact_id)

    with :ok <- ensure_dir(dir),
         :ok <- write_artifact(zip_path, meta_path, zip, installation.id, result) do
      :ets.insert(
        @table,
        {artifact_id, installation.id, zip_path, result.digest, result.signature,
         result.expires_at}
      )

      stored = %{result | artifact_id: artifact_id, artifact_path: zip_path}

      case persist_export_audit(scope, installation, stored) do
        {:ok, stored} ->
          {:ok, stored}

        {:error, %Error{} = error} ->
          _ = discard(artifact_id)
          {:error, error}
      end
    else
      {:error, %Error{} = error} ->
        _ = delete_file(zip_path)
        _ = delete_file(meta_path)
        _ = delete_file(zip_path <> ".partial")
        {:error, error}
    end
  end

  defp persist_export_audit(%Scope{} = scope, installation, result) do
    resource_id = result.bundle["selection"]["execution_id"] || installation.id

    attrs =
      Map.merge(Writer.actor(scope), %{
        installation_id: scope.installation_id,
        action: "admin.diagnostics_exported",
        resource_type: "installation",
        resource_id: resource_id,
        metadata: %{
          "actor_role" => scope.role,
          "result" => "ok",
          "source" => "support",
          "count" => length(result.field_names),
          "schema_version" => @schema_version
        }
      })

    case Multi.new()
         |> Service.as_multi()
         |> Writer.append(:audit, attrs)
         |> Repo.transaction() do
      {:ok, _changes} ->
        {:ok, result}

      {:error, _step, _reason, _changes} ->
        {:error,
         Error.new(:internal, :audit_append_failed,
           message: "The support action could not be audited."
         )}
    end
  end

  defp ensure_dir(dir) do
    marker = Path.join(dir, ".keep")

    case :filelib.ensure_dir(String.to_charlist(marker)) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error,
         Error.new(:internal, :persist_failed,
           message: "The diagnostic bundle could not be stored."
         )}
    end
  end

  defp write_artifact(zip_path, meta_path, zip, installation_id, result) do
    partial = zip_path <> ".partial"

    meta =
      Jason.encode!(%{
        "installation_id" => installation_id,
        "digest" => result.digest,
        "signature" => result.signature,
        "expires_at" => DateTime.to_iso8601(result.expires_at)
      })

    with :ok <- write_file(partial, zip),
         :ok <- write_file(meta_path, meta),
         :ok <- rename_file(partial, zip_path) do
      :ok
    else
      {:error, _reason} ->
        _ = delete_file(partial)
        _ = delete_file(zip_path)
        _ = delete_file(meta_path)

        {:error,
         Error.new(:internal, :persist_failed,
           message: "The diagnostic bundle could not be stored."
         )}
    end
  end

  defp artifact_path_for(installation_id, artifact_id) do
    setup()

    case :ets.lookup(@table, artifact_id) do
      [{^artifact_id, ^installation_id, path, _digest, _signature, expires_at}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt and regular_file?(path) do
          {:ok, path}
        else
          _ = discard(artifact_id)
          {:error, Policy.not_found()}
        end

      [{^artifact_id, other_id, _path, _digest, _signature, _expires_at}] ->
        if other_id do
          Scope.record_mismatch(:diagnostics)
        end

        {:error, Policy.not_found()}

      [] ->
        {:error, Policy.not_found()}
    end
  end

  defp expired_ids(now) do
    from_ets = expired_ets_ids(now)
    from_disk = expired_disk_ids(now)
    Enum.uniq(from_ets ++ from_disk)
  end

  defp expired_ets_ids(now) do
    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn {id, _installation_id, _path, _digest, _signature, expires_at} ->
      if DateTime.compare(now, expires_at) != :lt, do: [id], else: []
    end)
  rescue
    _exception -> []
  end

  defp expired_disk_ids(now) do
    dir = tmp_dir()

    case list_dir(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          expired_disk_id(dir, name, now)
        end)

      {:error, _reason} ->
        []
    end
  end

  defp expired_disk_id(dir, name, now) do
    suffix = ".zip"

    if String.ends_with?(name, suffix) do
      expire_named_zip(dir, String.replace_suffix(name, suffix, ""), now)
    else
      []
    end
  end

  defp expire_named_zip(dir, id, now) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        expire_uuid_zip(dir, uuid, now)

      :error ->
        []
    end
  end

  defp expire_uuid_zip(dir, uuid, now) do
    if disk_expired?(Path.join(dir, uuid <> ".meta.json"), now), do: [uuid], else: []
  end

  defp disk_expired?(meta_path, now) do
    with {:ok, json} <- read_file(meta_path),
         {:ok, %{"expires_at" => stamp}} <- Jason.decode(json),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(stamp) do
      DateTime.compare(now, expires_at) != :lt
    else
      _missing -> true
    end
  end

  defp delete_one(id, count) do
    _ = discard(id)
    count + 1
  end

  defp discard(artifact_id) when is_binary(artifact_id) do
    setup()
    dir = tmp_dir()
    _ = delete_file(zip_path(dir, artifact_id))
    _ = delete_file(meta_path(dir, artifact_id))
    _ = delete_file(zip_path(dir, artifact_id) <> ".partial")
    _ = :ets.delete(@table, artifact_id)
    :ok
  end

  defp included_fields(term), do: term |> collect_fields("") |> Enum.uniq() |> Enum.sort()

  defp collect_fields(map, prefix) when is_map(map) and not is_struct(map) do
    Enum.flat_map(map, fn {key, value} ->
      path = join_path(prefix, to_string(key))
      [path | collect_fields(value, path)]
    end)
  end

  defp collect_fields(list, prefix) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      collect_fields(value, join_path(prefix, Integer.to_string(index)))
    end)
  end

  defp collect_fields(_other, _prefix), do: []

  defp join_path("", key), do: key
  defp join_path(prefix, key), do: prefix <> "." <> key

  defp drop_forbidden(term) when is_map(term) and not is_struct(term) do
    term
    |> Enum.reject(fn {key, _value} -> forbidden_key?(key) end)
    |> Map.new(fn {key, value} -> {key, drop_forbidden(value)} end)
  end

  defp drop_forbidden(list) when is_list(list), do: Enum.map(list, &drop_forbidden/1)
  defp drop_forbidden(other), do: other

  defp forbidden_key?(key) do
    MapSet.member?(@forbidden_keys, key |> to_string() |> String.downcase())
  end

  defp hex_hash(bytes) do
    :sha256
    |> :crypto.hash(bytes)
    |> Base.encode16(case: :lower)
  end

  defp hex_mac(bytes) do
    :hmac |> :crypto.mac(:sha256, hmac_key(), bytes) |> Base.encode16(case: :lower)
  end

  defp hmac_key do
    :pumble_automation
    |> Application.fetch_env!(PumbleAutomationWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  defp ttl_seconds(opts) do
    requested = Keyword.get(opts, :ttl_seconds, artifact_ttl_seconds())
    max_ttl = config(:max_artifact_ttl_seconds, @max_ttl_seconds)

    cond do
      not is_integer(requested) -> artifact_ttl_seconds()
      requested < 1 -> 1
      requested > max_ttl -> max_ttl
      true -> requested
    end
  end

  defp tmp_dir do
    config(:tmp_dir, Path.join(System.tmp_dir!(), "pumble_automation_diagnostics"))
  end

  defp zip_path(dir, id), do: Path.join(dir, id <> ".zip")
  defp meta_path(dir, id), do: Path.join(dir, id <> ".meta.json")

  defp chars(path), do: String.to_charlist(path)

  defp read_file(path), do: :file.read_file(chars(path))

  defp write_file(path, bytes), do: :file.write_file(chars(path), bytes)

  defp delete_file(path) do
    case :file.delete(chars(path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rename_file(from, to), do: :file.rename(chars(from), chars(to))

  defp list_dir(dir) do
    case :file.list_dir(chars(dir)) do
      {:ok, names} -> {:ok, Enum.map(names, &List.to_string/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_file?(path), do: :filelib.is_regular(chars(path))

  defp config(key, default) do
    :pumble_automation
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp application_version do
    case Application.spec(:pumble_automation, :vsn) do
      value when is_list(value) -> List.to_string(value)
      value when is_binary(value) -> value
      _other -> "0.1.0"
    end
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(""), do: {:ok, nil}

  defp optional_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Policy.not_found()}
    end
  end

  defp optional_uuid(_value), do: {:error, Policy.not_found()}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Policy.not_found()}
    end
  end

  defp optional_time(nil), do: {:ok, nil}
  defp optional_time(""), do: {:ok, nil}
  defp optional_time(%DateTime{} = time), do: {:ok, time}

  defp optional_time(value) when is_binary(value) do
    trimmed = String.trim(value)

    case DateTime.from_iso8601(trimmed) do
      {:ok, time, _offset} ->
        {:ok, DateTime.from_unix!(DateTime.to_unix(time, :microsecond), :microsecond)}

      {:error, _reason} ->
        parse_naive_time(trimmed)
    end
  end

  defp optional_time(_value), do: {:ok, nil}

  defp parse_naive_time(value) do
    stamp =
      value
      |> String.replace(" ", "T")
      |> pad_seconds()

    case NaiveDateTime.from_iso8601(stamp) do
      {:ok, naive} ->
        case DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, time} -> {:ok, time}
          _other -> {:ok, nil}
        end

      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp pad_seconds(stamp) do
    if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/, stamp) do
      stamp <> ":00"
    else
      stamp
    end
  end

  defp encode_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp encode_time(_time), do: nil
end
