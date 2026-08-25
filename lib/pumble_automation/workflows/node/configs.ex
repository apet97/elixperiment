defmodule PumbleAutomation.Workflows.Node.Predicate do
  @moduledoc """
  One comparison inside a condition.

  A predicate compares a left side with a right side. Both sides are text: a
  template the compiler resolves later, or a literal. Nothing here evaluates
  anything — this schema only records what the author chose.
  """

  @comparators %{
    "eq" => :eq,
    "neq" => :neq,
    "contains" => :contains,
    "not_contains" => :not_contains,
    "starts_with" => :starts_with,
    "ends_with" => :ends_with,
    "gt" => :gt,
    "gte" => :gte,
    "lt" => :lt,
    "lte" => :lte,
    "is_empty" => :is_empty,
    "is_not_empty" => :is_not_empty,
    "in" => :in,
    "is_present" => :is_present
  }

  @type t :: %__MODULE__{
          left: String.t() | nil,
          comparator: atom() | nil,
          right: String.t() | nil
        }

  defstruct [:left, :comparator, :right]

  @doc "The declared fields of a predicate."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [
      {:left, :string, required: true, max_length: 4096},
      {:comparator, {:enum, @comparators}, required: true},
      {:right, :string, max_length: 4096}
    ]
  end

  @doc "The comparators a predicate may use."
  @spec comparators() :: %{String.t() => atom()}
  def comparators, do: @comparators
end

defmodule PumbleAutomation.Workflows.Node.ConditionConfig do
  @moduledoc """
  A condition: a combinator over an ordered list of predicates.

  AND, OR, and NOT are represented as logic combinators. They are not
  separate node types here, because a combinator over a predicate list says the
  same thing without letting an author build a tree the compiler would have to
  flatten. `:all` is AND, `:any` is OR, and `:none` is NOT over the group.
  """

  alias PumbleAutomation.Workflows.Node.Predicate

  @combinators %{"all" => :all, "any" => :any, "none" => :none}

  @type t :: %__MODULE__{combinator: atom(), predicates: [Predicate.t()]}

  defstruct combinator: :all, predicates: []

  @doc "The declared fields of a condition configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [
      {:combinator, {:enum, @combinators}, default: :all},
      {:predicates, {:list, {:struct, Predicate}}, default: []}
    ]
  end

  @doc "The combinators a condition may use."
  @spec combinators() :: %{String.t() => atom()}
  def combinators, do: @combinators
end

defmodule PumbleAutomation.Workflows.Node.DelayConfig do
  @moduledoc """
  A wait of a fixed duration.

  The upper bound is the configured 365-day delay limit,
  expressed in seconds so the editor never has to guess a unit.
  """

  alias PumbleAutomation.Limits

  @type t :: %__MODULE__{duration_seconds: pos_integer() | nil}

  defstruct [:duration_seconds]

  @doc "The declared fields of a delay configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [{:duration_seconds, :integer, required: true, min: 1, max: max_seconds()}]
  end

  @doc "The longest delay, in seconds."
  @spec max_seconds() :: pos_integer()
  def max_seconds, do: Limits.delay_seconds()
end

defmodule PumbleAutomation.Workflows.Node.ApprovalConfig do
  @moduledoc """
  A pause until a named person approves, rejects, or the wait elapses.

  Approver identity is a list of workspace member identifiers. It is never
  derived from a Pumble role: who may approve is this application's decision,
  recorded here.
  """

  alias PumbleAutomation.Limits

  @type t :: %__MODULE__{
          prompt: String.t() | nil,
          approver_member_ids: [String.t()],
          timeout_seconds: pos_integer() | nil
        }

  defstruct prompt: nil, approver_member_ids: [], timeout_seconds: nil

  @doc "The declared fields of an approval configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [
      {:prompt, :string, max_length: 4096},
      {:approver_member_ids, {:list, :string}, default: []},
      {:timeout_seconds, :integer, required: true, min: 1, max: max_seconds()}
    ]
  end

  @doc "The longest approval wait, in seconds."
  @spec max_seconds() :: pos_integer()
  def max_seconds, do: Limits.delay_seconds()
end

defmodule PumbleAutomation.Workflows.Node.PumbleActionConfig do
  @moduledoc """
  One of the supported production Pumble actions.

  The action discriminator selects which of the remaining fields matter. This
  schema does not check that pairing: which field a given action requires is a
  semantic rule, and semantic validation owns it. What is fixed here is that
  the field list is finite and that no other action exists.
  """

  @actions %{
    "send_message" => :send_message,
    "reply_message" => :reply_message,
    "direct_message" => :direct_message,
    "add_reaction" => :add_reaction,
    "remove_reaction" => :remove_reaction
  }

  @type t :: %__MODULE__{
          action: atom() | nil,
          channel_id: String.t() | nil,
          user_id: String.t() | nil,
          message_id: String.t() | nil,
          text: String.t() | nil,
          reaction: String.t() | nil
        }

  defstruct [:action, :channel_id, :user_id, :message_id, :text, :reaction]

  @doc "The declared fields of a Pumble action configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [
      {:action, {:enum, @actions}, required: true},
      {:channel_id, :string, max_length: 128},
      {:user_id, :string, max_length: 128},
      {:message_id, :string, max_length: 128},
      {:text, :string, max_length: 16 * 1024},
      {:reaction, :string, max_length: 128}
    ]
  end

  @doc "The Pumble actions a workflow may take in version 1."
  @spec actions() :: %{String.t() => atom()}
  def actions, do: @actions
end

defmodule PumbleAutomation.Workflows.Node.HttpActionConfig do
  @moduledoc """
  A generic outbound HTTP request.

  `:connection_id` names a stored external connection rather than carrying a
  credential, so no secret ever reaches a definition. The request body is a
  template; the 16 KiB bound is the template source limit, not the request
  body limit, because what is stored here is the
  source and not the expansion.
  """

  @methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete
  }

  @type t :: %__MODULE__{
          method: atom() | nil,
          url: String.t() | nil,
          headers: %{String.t() => String.t()},
          body: String.t() | nil,
          connection_id: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          idempotency_header: String.t() | nil
        }

  defstruct method: nil,
            url: nil,
            headers: %{},
            body: nil,
            connection_id: nil,
            timeout_ms: nil,
            idempotency_header: nil

  @doc "The declared fields of an HTTP action configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [
      {:method, {:enum, @methods}, required: true},
      {:url, :string, required: true, max_length: 2048},
      {:headers, {:map, :string}, default: %{}},
      {:body, :string, max_length: 16 * 1024},
      {:connection_id, :string, max_length: 64},
      {:timeout_ms, :integer, min: 1, max: 120_000},
      {:idempotency_header, :string, max_length: 128}
    ]
  end

  @doc "The HTTP methods a workflow may use."
  @spec methods() :: %{String.t() => atom()}
  def methods, do: @methods
end

defmodule PumbleAutomation.Workflows.Node.StopConfig do
  @moduledoc """
  An explicit end of a branch.

  The reason is recorded for the execution timeline, so a run that stopped
  early can say why without the reader inferring it from an absence.
  """

  @type t :: %__MODULE__{reason: String.t() | nil}

  defstruct [:reason]

  @doc "The declared fields of a stop configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields, do: [{:reason, :string, max_length: 1024}]
end
