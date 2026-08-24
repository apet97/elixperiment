# ADR-0004: Structured AST compiled to an immutable graph

**Status:** Accepted
**Plan decisions:** ADR-005 and ADR-006 in plan Section 7

## Context

A workflow must be easy to edit in a form-based UI and must run deterministically.
Editing a draft must never change the program of an execution that is already
running.

## Evidence

- Plan Section 7, row ADR-005: "Structured AST compiled to graph — simple editing
  and deterministic execution without graph bloat".
- Plan Section 7, row ADR-006: "Immutable executable versions — running executions
  never change program".
- Plan Section 15: the workflow AST is one trigger plus an ordered tree of steps;
  condition and approval nodes own named nested branches.
- Plan Section 16: activation and versioning; compiled versions are immutable and
  an execution is bound to one version.
- Plan Section 6: loops, free-form canvas editing, arbitrary user code, and
  JavaScript or Elixir evaluation are non-goals.
- Plan Section 31: workflow nodes 50, branch depth 8, definition size 256 KiB.

## Decision

Store a workflow draft as a structured AST: one trigger and an ordered tree of
steps. Condition and approval nodes own named nested branches. Node identity is a
stable UUID that is created on insertion and kept through reorder and edit.

Activation compiles the draft into an immutable executable version. An execution
binds to one version at creation and reads only that version until it ends.

The AST has no cycles, no merge nodes, no arbitrary jumps, and no runtime code.

## Alternatives

- A free general graph with arbitrary edges. Rejected: it adds cycle and merge
  handling that v1 does not need, and it makes an outline editor harder.
- Executing the mutable draft directly. Rejected: a running execution would change
  program when an editor saves.

## Consequences

- Reorder and edit operations keep node history and execution step references valid.
- The compiler is the single place that rejects invalid drafts (plan phase P6).
- Old versions must be retained for as long as executions or history reference them.
- Loop-shaped user needs must be met by triggers and schedules, not by AST cycles.

## Reversal condition

Reconsider if a contract-approved feature cannot be expressed as a tree within the
node, depth, and size limits of plan Section 31.
