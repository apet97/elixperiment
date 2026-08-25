# Uncertain effects

This runbook covers recovery when a remote side effect may have happened but
the application cannot prove its outcome.

Related:

- [Incidents](incidents.md)
- [Queues](queues.md)
- Delivery semantics: [delivery_semantics.md](../architecture/delivery_semantics.md)

## Result

A step that may already have produced a remote write pauses as
`paused_uncertain`. The engine does not guess. An owner decides. Viewers
cannot resolve. Editors cannot resolve.

## Symptom

Execution status is `paused_uncertain` (UI label **Paused (uncertain)**).
Metric `[:pumble_automation, :executions, :uncertain]` is non-zero.
`/executions/:id` shows operator controls **Mark succeeded**, **Mark failed**,
and **Retry with duplicate risk**.

Typical causes: HTTP or Pumble timeout after request bytes may have been
sent, ambiguous 5xx on a non-idempotent write, or an interrupted in-flight
effect. Confirmed 401/403 do not pause; they fail permanently.

## Checks

1. Open `/executions/:id` as an owner (`#execution-show`,
   `#execution-controls`).
2. Read the sanitized error class and node type. The page must not show
   tokens, raw message text, or HTTP bodies.
3. Check `/audit` for `execution` uncertainty actions.
4. Confirm the installation is still usable. Uninstall refuses a resolution
   that would dispatch a new effect.

## Safe action

Use the UI. The page calls `PumbleAutomation.Executions.Engine.resolve_uncertain/4`.
It never edits execution rows in the LiveView.

| Choice | Button | Effect |
|---|---|---|
| Succeeded | **Mark succeeded** (`#resolve-succeeded-prompt`) | Continue or complete. Optional sanitized evidence. |
| Failed | **Mark failed** (`#resolve-failed-prompt`) | Permanent failure. Idempotent stay if already failed. |
| Retry | **Retry with duplicate risk** (`#resolve-retry-prompt`) | New attempt. Requires checkbox **I acknowledge the duplicate risk** (`#uncertain-retry-acknowledge`). |

Same decisions in IEx as the owner:

<!-- command-status: proven-local -->
```elixir
alias PumbleAutomation.Executions.Engine
Engine.resolve_uncertain(scope, execution_id, "succeeded")
Engine.resolve_uncertain(scope, execution_id, "failed")
Engine.resolve_uncertain(scope, execution_id, "retry", %{acknowledge_duplicate_risk: true})
```

A second identical choice is an idempotent stay. A different choice after
resolution is a conflict. Retry without the acknowledgement is refused.

Cancel instead of resolving when the workspace no longer wants the side
effect: **Cancel execution** (`#cancel-prompt`). Waiting and paused rows
become `cancelled` immediately. A running row keeps running until finalize
observes the cancel request.

## Stop conditions

- Stop if you are about to retry from Oban or SQL without the required
  owner-role acknowledgment.
- Stop if you are about to mark succeeded without evidence and the remote
  write is billing- or permission-sensitive — use **Mark failed** or wait
  for a workspace owner to decide.
- Stop if the tenant is uninstalled or deleted. Do not dispatch.
- Stop automated resolution during a provider outage that causes many
  uncertain pauses. Do not bulk-succeed from a script.
