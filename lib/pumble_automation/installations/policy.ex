defmodule PumbleAutomation.Installations.Policy do
  @moduledoc """
  What each local role may do. The only place that answers that question.

  Plan Section 11.3 fixes the three roles and what they own. This module turns a
  role into a set of capability atoms and nothing else: it reads no row, takes no
  side effect, and has no opinion about how a caller reacts to a `false`. Every
  controller, plug, LiveView, and context that needs an authorization decision
  asks here, so that the answer cannot drift between two screens.

  ## The roles nest

      viewer ⊂ editor ⊂ owner

    * `viewer` reads workflows and sanitized executions.
    * `editor` adds managing, testing, and activating workflows, and retrying or
      cancelling an execution.
    * `owner` adds members, credentials and secrets, destructive lifecycle, and
      the resolution of anything uncertain.

  Approver identity inside a workflow is a separate concept and is never derived
  from these roles.

  ## Another tenant's resource is missing, not forbidden

  `authorize_tenant/2` answers `:not_found` for a resource belonging to another
  installation — the identical answer, with the identical message, that an
  identifier belonging to nobody gets. A `403` would confirm that the row exists,
  which turns any id-guessing route into an existence oracle across tenants. Plan
  Section 11.3's failure behaviour requires the two to be indistinguishable, and
  `policy_test.exs` compares the two errors field by field.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Scope

  @viewer ~w(read_workflows read_executions)a

  @editor @viewer ++
            ~w(manage_workflows test_workflows activate_workflows retry_execution
               cancel_execution)a

  @owner @editor ++
           ~w(manage_members manage_credentials manage_secrets destructive_lifecycle
              resolve_uncertainty)a

  @capabilities %{"viewer" => @viewer, "editor" => @editor, "owner" => @owner}

  @typedoc "One thing a role may or may not be allowed to do."
  @type capability ::
          :read_workflows
          | :read_executions
          | :manage_workflows
          | :test_workflows
          | :activate_workflows
          | :retry_execution
          | :cancel_execution
          | :manage_members
          | :manage_credentials
          | :manage_secrets
          | :destructive_lifecycle
          | :resolve_uncertainty

  @doc "Every capability this application defines, sorted."
  @spec capabilities() :: [capability()]
  def capabilities, do: Enum.sort(@owner)

  @doc "The capabilities `role` holds. An unknown role holds none."
  @spec capabilities(String.t()) :: [capability()]
  def capabilities(role) when is_binary(role), do: Map.get(@capabilities, role, [])

  @doc """
  Returns whether a scope or a role may do `capability`.

  An unknown role and an unknown capability both answer `false`, so a typo
  denies rather than permits.
  """
  @spec can?(Scope.t() | String.t(), capability()) :: boolean()
  def can?(%Scope{role: role}, capability), do: can?(role, capability)

  def can?(role, capability) when is_binary(role) and is_atom(capability) do
    capability in capabilities(role)
  end

  def can?(_role, _capability), do: false

  @doc """
  `:ok` when the scope may do `capability`, a `:permission` error otherwise.

  Use this inside one's own tenant. For a resource that may belong to another
  tenant, call `authorize_tenant/2` first: a forbidden answer about a resource
  the caller cannot see is already too much information.
  """
  @spec authorize(Scope.t(), capability()) :: :ok | {:error, Error.t()}
  def authorize(%Scope{} = scope, capability) do
    if can?(scope, capability) do
      :ok
    else
      {:error,
       Error.new(:permission, :capability_denied,
         message: "You do not have permission to do that.",
         details: %{required: capability}
       )}
    end
  end

  @doc """
  `:ok` when `installation_id` is the scope's own tenant, `:not_found` otherwise.

  The error is deliberately the same one a nonexistent identifier produces. See
  the module documentation.
  """
  @spec authorize_tenant(Scope.t(), Ecto.UUID.t() | nil) :: :ok | {:error, Error.t()}
  def authorize_tenant(%Scope{installation_id: installation_id}, installation_id), do: :ok
  def authorize_tenant(%Scope{}, _other), do: {:error, not_found()}

  @doc """
  The answer for a resource the caller may not see.

  Exposed so that a caller whose lookup returned no row answers with exactly the
  same error as a caller whose lookup found another tenant's row.
  """
  @spec not_found() :: Error.t()
  def not_found do
    Error.new(:not_found, :resource_not_found, message: "That resource does not exist.")
  end
end
