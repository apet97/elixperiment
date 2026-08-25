# v1 product contract

This is the current v1 scope contract. Maintain it with the implementation and
tests.

A feature that is absent from this contract is outside the v1 scope.

The generic HTTP action is the only broad external integration primitive in v1.

---

## 1. Trigger categories

### 1.1 Pumble event

User-selectable event triggers:

- `NEW_MESSAGE`;
- `UPDATED_MESSAGE`;
- `REACTION_ADDED`;
- `CHANNEL_CREATED`;
- `WORKSPACE_USER_JOINED`.

Control-plane events, handled by the application and **not** selectable as workflow
triggers:

- `APP_UNINSTALLED`;
- `APP_UNAUTHORIZED`.

### 1.2 Manual Pumble entry

Static manifest entries:

- one slash command, default proposed name `/workflow`;
- one global shortcut, default proposed name `Run workflow`;
- one message shortcut, default proposed name `Run workflow on message`.

An active workflow may declare a unique manual alias and whether it appears in each
picker.

### 1.3 Schedule

- once;
- every N minutes;
- every N hours;
- daily at local time;
- weekly on selected weekdays at local time.

### 1.4 Inbound webhook

A workspace-scoped endpoint with a high-entropy token and an optional HMAC secret.

### 1.5 Test / manual browser execution

Dry-run by default. External effects require an explicit live-test action.

---

## 2. Logic nodes

- condition;
- AND;
- OR;
- NOT;
- true branch;
- false branch;
- delay;
- approval, with approved, rejected, and timeout branches;
- stop.

No loops in v1.

---

## 3. Action nodes

Production actions in v1:

- send Pumble message;
- reply to a triggering or referenced Pumble message;
- direct-message a Pumble user;
- add reaction;
- remove reaction;
- generic external HTTP request.

Deferred until proven necessary. These may be deferred without blocking release:

- edit or delete a Pumble message;
- channel creation or membership changes;
- file upload;
- scheduled Pumble message;
- message search;
- native connectors.

---

## 4. Management capabilities

- install and reinstall;
- sign in to the web UI;
- manage members and roles;
- create workflow;
- edit draft;
- validate;
- dry-run test;
- activate and deactivate;
- view immutable versions;
- inspect executions, steps, attempts, and sanitized values;
- cancel;
- safe retry;
- resolve uncertain outcomes;
- manage secrets and external HTTP connections;
- inspect audit history;
- export a bounded, sanitized diagnostic ZIP;
- uninstall and delete data.

---

## 5. Explicit non-goals

The production core does not include:

- AI or LLM workflow generation;
- arbitrary user code;
- JavaScript or Elixir evaluation;
- loops;
- free-form canvas editing;
- native GitHub, Linear, Clockify, Plaky, Gmail, or Calendar connectors;
- connector marketplace;
- arbitrary plugins;
- distributed BEAM clustering;
- microservices;
- Redis;
- Kafka;
- RabbitMQ;
- Temporal;
- Kubernetes;
- Elasticsearch;
- paid billing or entitlements;
- enterprise analytics warehouse;
- exactly-once claims.

---

## 6. Manifest trigger model

The Pumble manifest registers static entry points. Manifest entries are installation
configuration, not per-workflow runtime registrations. See ADR-0007.

Rules:

- the manifest declares one slash command, one global shortcut, and one message
  shortcut, and these do not change when users edit workflows;
- callbacks reach fixed HTTPS-only production paths;
- callback classes are: ordinary Pumble event, slash command, global shortcut,
  message shortcut, block interaction, view action, and dynamic menu. Each class
  has its own response contract;
- dynamic-menu handling stays synchronous and bounded and is used for product UI
  selection, not for workflow execution;
- an active workflow alias is unique within a workspace and trigger type;
- a manifest version or scope change requires a reinstall. Scope expansion never
  happens silently;
- if a proposed command name is unavailable, the release needs a different
  static name and a manifest migration.

---

## 7. Delivery semantics summary

Delivery is **at-least-once**. The system makes no exactly-once claim.

Guaranteed:

- one stored received-event row per accepted dedupe key;
- one logical execution per execution key;
- one logical step row per execution and node;
- stale jobs do not advance state;
- completed steps are not executed again by duplicate jobs;
- state transitions preserve database invariants.

Not guaranteed:

- exactly one callback delivery;
- exactly one job attempt;
- exactly one remote effect when the remote API lacks idempotency and the outcome is
  ambiguous.

Uncertain outcomes: when dispatch began, no definitive response was obtained,
and remote idempotency cannot prove safe retry, the execution enters
`PAUSED_UNCERTAIN`. It stores the effect key, attempt, request summary, error
class, timing, whether bytes may have left, any remote correlation ID, and
operator guidance. An authorized workspace owner resolves it to `RUNNING`,
`FAILED`, or `COMPLETED`. See ADR-0006.

---

## 8. Open items

Unresolved scope or protocol details are linked to probe IDs in
`docs/evidence/`. They are not guessed here.
