defmodule PumbleAutomation.Executions.StepAttempt do
  @moduledoc """
  One try at running a step, append-only.

  An attempt is the external-effect ledger: when dispatch started, what the
  provider said, how the engine classified it, and the sanitized diagnostics
  an operator may read. There is `create/2`. There is no update and no delete.
  A correction is a new attempt, which is also what makes a retry readable:
  the row that recorded the uncertain write is still the row that recorded it.

  ## Numbers are allocated under the step's row lock

  `create/2` takes `SELECT ... FOR UPDATE` on the parent step, reads
  `max(attempt_number) + 1`, and inserts. Two workers finalizing one step
  therefore serialize on that lock and receive consecutive numbers. The unique
  index on `(step_execution_id, attempt_number)` is the backstop.

  The tenant is copied from the locked step rather than from the caller, so a
  mismatched `installation_id` cannot be constructed.

  ## Diagnostics are bounded and sanitized

  They are a JSON map with the same secret-key refusal as execution context.
  A provider body does not belong here.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(started succeeded failed uncertain cancelled)
  @terminal ~w(succeeded failed uncertain cancelled)

  @max_diagnostics_bytes 16 * 1024
  @max_error 64
  @max_remote_request_id 256

  @insert_fields ~w(status oban_job_id started_at ended_at error_class error_code
                    remote_status remote_request_id retry_at duration_ms diagnostics)a

  @type t :: %__MODULE__{}

  schema "step_attempts" do
    field :installation_id, :binary_id
    field :step_execution_id, :binary_id
    field :attempt_number, :integer
    field :status, :string, default: "started"
    field :oban_job_id, :integer
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :error_class, :string
    field :error_code, :string
    field :remote_status, :integer
    field :remote_request_id, :string
    field :retry_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :diagnostics, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Builds the one and only changeset: an insertion.

  Raises when given a persisted struct. An attempt that is already stored has
  no valid change.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attempt, attrs)

  def changeset(%__MODULE__{id: nil} = attempt, attrs) do
    attempt
    |> cast(attrs, @insert_fields)
    |> validate_required([
      :installation_id,
      :step_execution_id,
      :attempt_number,
      :status,
      :started_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt_number, greater_than_or_equal_to: 1)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:oban_job_id, greater_than: 0)
    |> validate_length(:error_class, max: @max_error)
    |> validate_length(:error_code, max: @max_error)
    |> validate_length(:remote_request_id, max: @max_remote_request_id)
    |> validate_bounded_diagnostics()
    |> validate_sanitized_diagnostics()
    |> unique_constraint([:step_execution_id, :attempt_number],
      name: :step_attempts_step_execution_id_attempt_number_index
    )
    |> check_constraint(:status, name: :step_attempts_status_check)
    |> check_constraint(:attempt_number, name: :step_attempts_attempt_number_check)
    |> check_constraint(:duration_ms, name: :step_attempts_duration_ms_check)
    |> foreign_key_constraint(:step_execution_id)
    |> foreign_key_constraint(:installation_id)
  end

  def changeset(%__MODULE__{}, _attrs) do
    raise "PumbleAutomation.Executions.StepAttempt is immutable: a stored attempt " <>
            "cannot be changed. Create a new attempt instead."
  end

  @doc "The statuses an attempt may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses that have no ordinary outgoing transition."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal

  @doc "The greatest encoded size of diagnostics, in bytes."
  @spec max_diagnostics_bytes() :: pos_integer()
  def max_diagnostics_bytes, do: @max_diagnostics_bytes

  @doc """
  Creates the next attempt of `step`.

  Takes the step's row lock, allocates `max(attempt_number) + 1`, and inserts.
  Runs in a transaction; nesting inside a caller's transaction is safe.

  Any `:installation_id`, `:step_execution_id`, or `:attempt_number` in `attrs`
  is ignored: all three are derived here. `:started_at` defaults to now.
  `:status` defaults to `"started"`.

  Returns a `:not_found` error when the step does not exist inside its tenant.
  """
  @spec create(StepExecution.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def create(%StepExecution{} = step, attrs \\ %{}) when is_map(attrs) do
    result =
      Repo.transaction(fn ->
        with {:ok, locked} <- lock_step(step),
             {:ok, attempt} <- insert(locked, attrs) do
          attempt
        else
          {:error, %Error{} = error} -> Repo.rollback(error)
        end
      end)

    case result do
      {:ok, attempt} -> {:ok, attempt}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp lock_step(%StepExecution{id: id, installation_id: installation_id}) do
    query =
      from s in StepExecution,
        where: s.id == ^id and s.installation_id == ^installation_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil ->
        {:error,
         Error.new(:not_found, :step_not_found,
           message: "The step was not found in this workspace."
         )}

      step ->
        {:ok, step}
    end
  end

  defp insert(step, attrs) do
    now = DateTime.utc_now()

    writable =
      attrs
      |> Map.take(@insert_fields)
      |> Map.put_new(:status, "started")
      |> Map.put_new(:started_at, now)
      |> Map.put_new(:diagnostics, %{})

    %__MODULE__{
      installation_id: step.installation_id,
      step_execution_id: step.id,
      attempt_number: next_attempt_number(step.id)
    }
    |> changeset(writable)
    |> Repo.insert()
    |> case do
      {:ok, attempt} -> {:ok, attempt}
      {:error, changeset} -> {:error, insert_error(changeset)}
    end
  end

  defp next_attempt_number(step_execution_id) do
    query =
      from a in __MODULE__,
        where: a.step_execution_id == ^step_execution_id,
        select: max(a.attempt_number)

    case Repo.one(query) do
      nil -> 1
      highest -> highest + 1
    end
  end

  defp insert_error(%Ecto.Changeset{} = changeset) do
    if violated?(changeset, "step_attempts_step_execution_id_attempt_number_index") do
      Error.new(:conflict, :attempt_number_taken,
        message: "Another attempt was recorded at the same time. Try again."
      )
    else
      Error.new(:validation, :invalid_attempt,
        message: "The step attempt is not valid.",
        details: %{fields: Enum.map(changeset.errors, fn {field, _} -> field end)}
      )
    end
  end

  defp violated?(%Ecto.Changeset{errors: errors}, name) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == name
    end)
  end

  defp validate_bounded_diagnostics(changeset) do
    case get_field(changeset, :diagnostics) do
      nil ->
        changeset

      map ->
        if Execution.json_within?(map, @max_diagnostics_bytes) do
          changeset
        else
          add_error(changeset, :diagnostics, "is too large")
        end
    end
  end

  defp validate_sanitized_diagnostics(changeset) do
    case get_field(changeset, :diagnostics) do
      nil ->
        changeset

      map ->
        if Execution.sanitized_map?(map) do
          changeset
        else
          add_error(changeset, :diagnostics, "must not contain secret-looking keys")
        end
    end
  end
end
