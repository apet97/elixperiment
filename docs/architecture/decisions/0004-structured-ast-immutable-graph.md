# ADR-0004: Structured AST compiled to an immutable graph

**Status:** Accepted

## Context

A workflow must be easy to edit in a form-based UI and must run deterministically.
Editing a draft must never change the program of an execution that is already
running.

## Evidence

- `docs/contract/product_contract.md` defines a structured trigger and ordered
  step tree, immutable active versions, and the supported node catalogue.
- `PumbleAutomation.Workflows.Validator`, `Compiler`, and `Activation` validate
  and compile the draft before atomically activating an immutable version.
- The workflow validation suites enforce acyclic structure, stable node IDs,
  50 nodes, branch depth 8, and a 256 KiB definition limit.

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
- The validator and compiler are the single activation boundary for invalid drafts.
- Old versions must be retained for as long as executions or history reference them.
- Loop-shaped user needs must be met by triggers and schedules, not by AST cycles.

## Reversal condition

Reconsider if a supported feature cannot be expressed as a tree within the
documented node, depth, and size limits.
