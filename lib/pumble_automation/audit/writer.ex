defmodule PumbleAutomation.Audit.Writer do
  @moduledoc """
  The only way to add an audit row.

  ## Two functions, because there are two kinds of event

  `append/3` is for security-critical events: an install, a role change, a
  credential rotation, an activation. It takes a caller-owned `Ecto.Multi` and
  returns it, so the audit insert commits in the same transaction as the change
  it describes. That makes the guarantee symmetric, which is the point. If the
  business change rolls back, the audit row goes with it and no one reads a
  record of something that never happened. If the audit insert fails, the
  business change rolls back and the mutation does not happen unaccountably.

      Ecto.Multi.new()
      |> Ecto.Multi.update(:installation, changeset)
      |> PumbleAutomation.Audit.Writer.append(:audit, fn %{installation: installation} ->
        %{
          installation_id: installation.id,
          actor_type: "user",
          actor_id: actor.id,
          action: "installation.activated",
          resource_type: "installation",
          resource_id: installation.id,
          correlation_id: correlation_id
        }
      end)
      |> PumbleAutomation.Repo.transaction()

  `append_best_effort/1` is for explicitly noncritical diagnostics, and only
  those. It writes on its own, never raises, and reports a failure by returning
  an error tuple and a log line. Reach for it when losing the event is
  acceptable; if that sentence makes you hesitate, the event belongs in
  `append/3`.

  `append_denied/1` is the flood-limited path for refused interactions. Repeats
  from the same actor are skipped rather than filling the tenant timeline.

  `actor/1` is the only vocabulary for who acted: system, job, browser user, or
  Pumble user.

  ## What this module does not have

  There is no update and no delete, and none will be added. A correction to the
  record is a new event describing the correction, which is what makes the
  history readable in an incident. See `PumbleAutomation.Audit.AuditEvent` for
  the metadata rules and the limits of the append-only claim.
  """

  require Logger

  alias Ecto.Changeset
  alias Ecto.Multi
  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.RateLimiter
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope

  @denied_per_minute 5

  @typedoc "The fields of one audit event. String or atom keys both work."
  @type attrs :: map()

  @typedoc "Attributes, or a function building them from the earlier steps."
  @type attrs_or_fun :: attrs() | (map() -> attrs())

  @doc """
  Adds one audit insert to `multi` under `name` and returns the multi.

  `attrs_or_fun` is either an attribute map or a one-argument function that
  receives the results of the earlier steps and returns one. Use the function
  form whenever the event needs an identifier produced by an earlier step,
  which is the usual case.

  `:correlation_id` is filled with a fresh UUID when the caller omits it, so an
  event is never written without something to stitch it to its neighbours.

  Invalid attributes make the step return `{:error, changeset}`, which rolls the
  whole transaction back. That is the intended behaviour, not a failure mode to
  work around.
  """
  @spec append(Multi.t(), Multi.name(), attrs_or_fun()) :: Multi.t()
  def append(multi, name, attrs_or_fun)

  def append(multi, name, fun) when is_function(fun, 1) do
    Multi.insert(multi, name, fn changes -> changes |> fun.() |> changeset() end)
  end

  def append(multi, name, attrs) when is_map(attrs) do
    Multi.insert(multi, name, changeset(attrs))
  end

  @doc "How many denied-interaction audits one actor may record per minute."
  @spec denied_per_minute() :: pos_integer()
  def denied_per_minute, do: @denied_per_minute

  @doc """
  Canonical actor fields for an audit row.

  Workers are `:job` with a short worker name. Approvals and other Pumble
  clicks are `:pumble_user`. Browser operators are the scope's member.
  Scheduled application work that is not a job is `:system`.
  """
  @spec actor(:system | Scope.t() | {:job, module() | String.t()} | {:pumble, String.t()}) ::
          %{actor_type: String.t(), actor_id: String.t()}
  def actor(:system), do: %{actor_type: "system", actor_id: "application"}

  def actor(%Scope{member_id: member_id}) when is_binary(member_id) do
    %{actor_type: "user", actor_id: member_id}
  end

  def actor({:job, module}) when is_atom(module) do
    %{actor_type: "job", actor_id: worker_id(module)}
  end

  def actor({:job, name}) when is_binary(name) and name != "" do
    %{actor_type: "job", actor_id: name}
  end

  def actor({:pumble, id}) when is_binary(id) and id != "" do
    %{actor_type: "pumble_user", actor_id: id}
  end

  @doc """
  Writes one denied or invalid interaction, if the flood window still has room.

  Repeats from the same actor, tenant, and action beyond `denied_per_minute/0`
  are skipped. A skip is success: the surrounding interaction must not fail
  because the audit log is being hammered. Under the limit this is
  `append_best_effort/1`.
  """
  @spec append_denied(attrs()) :: :ok | {:error, :audit_append_failed}
  def append_denied(attrs) when is_map(attrs) do
    normalized = stringify(attrs)

    case RateLimiter.check(denied_key(normalized),
           limit: @denied_per_minute,
           source: :audit_denied,
           installation_id: normalized["installation_id"],
           on_error: :deny
         ) do
      :ok ->
        append_best_effort(attrs)

      {:error, %Error{}} ->
        :ok
    end
  end

  @doc """
  Writes one noncritical diagnostic event outside any transaction.

  Never raises and never propagates a database failure to the caller: the whole
  point of this function is that the surrounding operation continues. A failure
  is logged and returned as `{:error, :audit_append_failed}`.

  The log line carries field names and validation messages only. Rejected
  values are not logged, because the reason a value was rejected is often that
  it was a secret.
  """
  @spec append_best_effort(attrs()) :: :ok | {:error, :audit_append_failed}
  def append_best_effort(attrs) when is_map(attrs) do
    case insert(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("audit: best-effort append failed: " <> describe(reason))
        {:error, :audit_append_failed}
    end
  end

  defp insert(attrs) do
    Repo.insert(changeset(attrs))
  rescue
    exception -> {:error, exception.__struct__}
  end

  defp changeset(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new_lazy("correlation_id", &Ecto.UUID.generate/0)
    |> AuditEvent.changeset()
  end

  defp describe(%Changeset{errors: errors}) do
    Enum.map_join(errors, ", ", fn {field, {message, _opts}} -> "#{field} #{message}" end)
  end

  defp describe(other), do: inspect(other)

  defp stringify(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp denied_key(normalized) do
    {:audit_denied, normalized["installation_id"], normalized["action"],
     normalized["actor_id"] || "none"}
  end

  defp worker_id(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end
end
