defmodule PumbleAutomation.Scope do
  @moduledoc """
  The verified answer to "who is asking, and inside which tenant".

  One struct is built once per HTTP request and once per LiveView mount, from a
  session that was resolved against the database, and it is then the only thing
  the rest of the request is allowed to authorize against. Nothing downstream
  reads a workspace id from a parameter, a form field, or a socket assign that
  arrived from the browser.

  ## Immutable

  There is no setter and no `put_role/2`. A scope is built by `new/1` from rows
  that were just read, and a request that needs a different scope builds a new
  one from a fresh read. This is why a role change revokes sessions rather than
  editing a scope: authority is re-derived, never patched.

  `:role` is the local `PumbleAutomation.Installations.WorkspaceMember` role. It
  is never a Pumble role string, and `PumbleAutomation.Installations.Policy` is
  the only place that turns it into a permission.

  ## Isolation misses

  Tenant lookups use `(installation_id, id)` in SQL. A miss is
  `Policy.not_found/0` whether the id belongs to nobody or to another
  workspace. When the id does belong to another workspace, `refuse_unknown/4`
  emits bounded telemetry `[:pumble_automation, :tenancy, :mismatch]` so the
  miss is observable without becoming an existence oracle for the caller.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Repo

  @enforce_keys [:installation_id, :member_id, :role]
  defstruct [:installation_id, :member_id, :role]

  @telemetry_event [:pumble_automation, :tenancy, :mismatch]

  @type t :: %__MODULE__{
          installation_id: Ecto.UUID.t(),
          member_id: Ecto.UUID.t(),
          role: String.t()
        }

  @doc "Builds the scope a member's row describes."
  @spec new(WorkspaceMember.t()) :: t()
  def new(%WorkspaceMember{} = member) do
    %__MODULE__{
      installation_id: member.installation_id,
      member_id: member.id,
      role: member.role
    }
  end

  @doc "Telemetry event for a confirmed cross-tenant identifier."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Records a bounded mismatch. Metadata is a source atom only — never a
  foreign id, name, or payload.
  """
  @spec record_mismatch(atom()) :: :ok
  def record_mismatch(source) when is_atom(source) do
    :telemetry.execute(@telemetry_event, %{count: 1}, %{source: Atom.to_string(source)})
    :ok
  end

  @doc """
  Emits mismatch telemetry when `id` exists under a different installation.

  Used by job claim paths that must still return a no-op rather than
  `not_found`.
  """
  @spec record_if_foreign(module(), term(), Ecto.UUID.t(), atom()) :: :ok
  def record_if_foreign(schema, id, installation_id, source)
      when is_atom(schema) and is_binary(installation_id) and is_atom(source) do
    if foreign_row?(schema, id, installation_id) do
      record_mismatch(source)
    end

    :ok
  end

  @doc """
  The answer for a scoped lookup that returned nothing.

  Identical to `Policy.not_found/0`. When the identifier belongs to another
  tenant, also emits mismatch telemetry.
  """
  @spec refuse_unknown(module(), term(), Ecto.UUID.t(), atom()) :: {:error, Error.t()}
  def refuse_unknown(schema, id, installation_id, source)
      when is_atom(schema) and is_binary(installation_id) and is_atom(source) do
    record_if_foreign(schema, id, installation_id, source)
    {:error, Policy.not_found()}
  end

  defp foreign_row?(schema, id, installation_id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.exists?(
          from row in schema,
            where: row.id == ^uuid and row.installation_id != ^installation_id
        )

      :error ->
        false
    end
  end
end
