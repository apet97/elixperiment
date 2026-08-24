# Architecture Assessment and Missing Requirements

> [!WARNING]
> Historical greenfield assessment. Statements that the application does not
> exist are intentionally preserved and are no longer current. See the
> [current documentation](../../README.md).

## Executive verdict

Elixir, Phoenix, Ecto, PostgreSQL, Oban, and LiveView are a strong fit for this product.

The right implementation is not an Elixir clone of the Pumble Node SDK. It is a narrow Pumble protocol adapter wrapped around a durable workflow domain. The application should be one Phoenix modular monolith with one PostgreSQL database. Oban should execute asynchronous work and scheduled continuations. PostgreSQL must remain the authoritative record for installations, workflow versions, events, executions, approvals, secrets, and schedules.

The original direction is technically sound. The main risks are not language or framework risks. They are product-contract and distributed-systems risks:

1. Pumble manifest registrations are static, while users will expect runtime-created triggers.
2. external writes cannot be guaranteed exactly once;
3. the workflow-management web UI needs an identity and authorization model;
4. generic HTTP requests create an SSRF and data-exfiltration boundary;
5. several Pumble details are documented only by the supplied SDK corpus and require live probes;
6. an unrestricted node graph would create unnecessary complexity.

The recommended v1 uses a structured workflow AST, a LiveView outline editor, fixed Pumble command/shortcut entry points, static event subscriptions, indexed trigger bindings, and explicit uncertain-outcome handling.

## Source coverage

### File 01 — Overview and project map

This establishes that the supplied material mirrors the official Node SDK monorepo and identifies the runtime, auth, API, interactivity, examples, CLI, deployment, and marketplace sources. It also shows the end-to-end SDK path from manifest to listener to context to API client.

Architectural effect: use the SDK as a behavioral reference, not a runtime dependency or a porting target.

### File 02 — Core framework, auth, and runtime

This provides the `App` and `Addon` surfaces, OAuth token exchange, token-store contract, HTTP and Socket Mode listeners, raw-body HMAC verification, context composition, and the three-second acknowledgement requirement.

Architectural effect: choose production HTTP callbacks, keep interactive work small before acknowledgement, persist credentials in PostgreSQL, and implement raw-byte signature verification.

### File 03 — API clients and v1 type system

This provides the API header model, supported channel/message/user/workspace/app methods, scheduled-message support, Pumble error behavior, lack of built-in retries, and the public message/block/view types.

Architectural effect: implement a narrow typed Pumble client, centralize retry classification, and only expose actions proven by these methods.

### File 04 — Events, contexts, interactivity, and blocks

This documents the seven subscribed event types, abbreviated wire fields, slash/shortcut/block/view/dynamic-menu payloads, context-specific response behavior, view state, blocks, and routing keys.

Architectural effect: normalize wire payloads at ingress, treat lifecycle events separately, use fixed interaction routes, and do not treat dynamic menus as ordinary asynchronous triggers.

### File 05 — CLI, examples, docs, and deployment

This shows static manifest management, example app patterns, production HTTP guidance, manifest secret stripping, marketplace preparation, and the absence of a dedicated test/mocking package.

Architectural effect: generate a safe public manifest, build an internal Pumble contract harness, keep marketplace readiness in the plan, and avoid copying example-specific Mongo/timer designs.

## Current state classification

Only planning and source-reference files were provided. No application repository, source tree, tests, deployment configuration, database schema, or release evidence was supplied.

| Area | Classification | Basis |
|---|---|---|
| Repository/application | NOT VERIFIED | No repository snapshot was provided |
| Pumble integration | NOT IMPLEMENTED / NOT VERIFIED | Behavioral reference exists; application code does not |
| Workflow engine | NOT IMPLEMENTED / NOT VERIFIED | Product requirements exist; no executable code |
| Persistence | NOT IMPLEMENTED / NOT VERIFIED | PostgreSQL direction only |
| Tests | NOT IMPLEMENTED / NOT VERIFIED | Required strategy only |
| Deployment | NOT IMPLEMENTED / NOT VERIFIED | Target architecture only |
| Marketplace release | NOT IMPLEMENTED / NOT VERIFIED | Guide and desired gates only |

The canonical plan must begin with repository inspection and may mark work complete if a repository supplied later proves it already exists.

## Fact, inference, and unknown matrix

### Facts from the supplied corpus

- Pumble documents seven subscribed events: reaction added, new message, updated message, channel created, app uninstalled, app unauthorized, and workspace user joined.
- Pumble interaction payloads are distinct from ordinary events.
- Slash commands, shortcuts, block interactions, and view actions require acknowledgement within three seconds.
- Dynamic menus return an option response rather than a normal acknowledgement.
- Production HTTP callbacks use an HMAC-SHA256 signature over raw request bytes and constant-time comparison.
- Bot and user tokens are separate.
- The API client uses both the OAuth token and the app token header.
- The supplied client does not automatically retry Pumble API requests.
- HTTP and Socket Mode are supported.
- The supplied production guidance favors HTTP for marketplace-grade add-ons.
- Manifest serving strips app secrets and converts relative callback URLs to absolute URLs.
- The Node SDK includes a local JSON token store, but it is not suitable for production.
- Pumble supports messages, replies, DMs, reactions, channels, users, workspace data, Home views, files, scheduled messages, uninstall, and authorization removal through the documented API clients.

### Inferences adopted as defaults

- User-created workflows cannot create arbitrary new Pumble slash command names or shortcuts without changing the manifest and possibly reinstalling the app.
- A fixed slash command and fixed shortcuts should route to user-created workflows by alias or selection.
- `APP_UNINSTALLED` and `APP_UNAUTHORIZED` are control-plane events and should not be offered as normal workflow triggers.
- A structured AST is sufficient for the first production product.
- Bot-token actions should be the default because they make app-origin loop filtering more reliable.
- PostgreSQL and Oban are sufficient for the expected initial scale.
- A single Phoenix deployment can run HTTP handling and workers until measurements prove a need to split them.

### Unknowns that require live probes

- whether all callback types expose a stable unique delivery ID;
- whether interaction `triggerId` is stable across redelivery;
- exact signature header precedence and whether any timestamp/replay header exists;
- OAuth token expiry, refresh, and replacement behavior;
- reinstall semantics for bot and user tokens;
- ordering and duplication of authorization/uninstall events;
- exact Pumble role strings and whether they can safely bootstrap web UI roles;
- exact scopes required for every selected action;
- 429 headers, rate-limit units, and retry guidance;
- server-side idempotency support for Pumble write methods;
- whether app-generated messages carry usable metadata beyond author/bot identity;
- maximum callback body, message, block, attachment, and file limits relevant to this product;
- marketplace behavior for launch URLs and browser sign-in;
- whether a Pumble Home view may safely contain the product’s external management link in all target environments.

## Recommended architecture

```text
                         PUMBLE
             events / commands / interactions
                              |
                              v
+------------------------------------------------------------------+
| Phoenix Endpoint                                                  |
|  size limit -> raw-body capture -> signature -> classify -> ack   |
+----------------------+-------------------------------------------+
                       |
                       v
+----------------------+-------------------------------------------+
| Ingress                                                          |
| normalize -> deduplicate -> persist -> indexed trigger match      |
+----------------------+-------------------------------------------+
                       |
          Ecto.Multi: executions + Oban jobs
                       |
                       v
+------------------------------------------------------------------+
| Executions                                                        |
| claim -> evaluate/perform -> persist -> enqueue continuation       |
|                                                                  |
| pure nodes     Pumble adapter     Safe HTTP     delay/approval     |
+-----------+------------------+---------------+--------------------+
            |                  |               |
            v                  v               v
        PostgreSQL         Pumble API      external APIs
            ^
            |
+-----------+------------------------------------------------------+
| Workflows / Installations / Connections / Audit / LiveView UI     |
+------------------------------------------------------------------+
```

### Deployable unit

One Phoenix release and one PostgreSQL database.

The same release initially runs:

- web endpoint;
- LiveView;
- Pumble callback handling;
- Oban queues;
- schedule dispatcher;
- retention jobs.

Do not split web and worker releases until queue latency, deployment behavior, or independent scaling proves the need.

### Domain ownership

#### Installations

Owns:

- Pumble workspace installation;
- encrypted bot credentials;
- encrypted user credentials;
- OAuth states;
- browser members, roles, and sessions;
- reinstall, revoke, uninstall, and deletion lifecycle.

May call Pumble only through the Pumble adapter.

#### Pumble

Owns:

- wire payload structures;
- signature verification;
- payload classification and normalization;
- typed API client;
- block/view builders used by this product;
- error classification;
- scope catalog based on proven behavior.

Does not own workflows, executions, or tenant authorization.

#### Workflows

Owns:

- editable draft;
- typed AST;
- compiler;
- immutable versions;
- activation;
- trigger bindings;
- schedules attached to active versions;
- validation and scope requirements.

Does not execute external effects.

#### Ingress

Owns:

- received events;
- deduplication keys;
- generic webhook endpoints;
- trigger matching;
- execution creation from accepted triggers.

Does not contain workflow-step logic.

#### Executions

Owns:

- execution state machine;
- step and attempt ledgers;
- current program position;
- durable delays;
- approvals;
- cancellation;
- uncertain-outcome resolution;
- execution workers and node runners.

Calls infrastructure through narrow Pumble and safe-HTTP boundaries.

#### Connections

Owns:

- workspace secrets;
- external HTTP connections;
- authenticated encryption;
- runtime secret resolution;
- safe HTTP egress.

#### Audit

Owns append-only security and administrative audit records.

#### Web

Owns:

- browser sessions;
- LiveViews and controllers;
- authorization checks;
- CSRF;
- user-safe presentation.

It calls contexts and does not issue raw database queries for domain behavior.

## Architecture decisions

### AD-001 — Modular monolith

**Decision:** one Phoenix application and one PostgreSQL database.

**Reason:** transactionally inserting Oban work with domain changes is a major reliability benefit. No requirement proves a need for services or a broker.

### AD-002 — Production HTTP callbacks

**Decision:** use HTTP callback transport for production. Socket Mode may be used only in an isolated developer probe if needed.

**Reason:** the supplied corpus supports raw-body signature verification, public callback URLs, and marketplace deployment through HTTP. Socket Mode adds persistent connection and reconnect concerns without solving a product requirement.

### AD-003 — Structured AST, compiled graph

**Decision:** users edit a nested, loop-free AST. Activation compiles it to a normalized graph.

**Reason:** this preserves clear branch semantics while avoiding free-form graph cycles, fan-in, merge behavior, and an early canvas editor.

### AD-004 — Immutable executable versions

**Decision:** a workflow has a mutable draft and immutable activated versions. Executions point to one version forever.

**Reason:** editing a workflow must not change a running execution.

### AD-005 — PostgreSQL plus Oban

**Decision:** all durable workflow state is in PostgreSQL. Oban jobs contain identifiers and expected state, not authoritative workflow state.

**Reason:** restarts and deployments must not lose delays, approvals, or progression.

### AD-006 — At-least-once with explicit uncertainty

**Decision:** duplicate delivery and duplicate jobs are normal. Non-idempotent ambiguous writes enter a paused uncertain state.

**Reason:** Pumble and generic HTTP idempotency support are not proven. Automatically retrying an ambiguous write may duplicate effects.

### AD-007 — Fixed Pumble entry points

**Decision:** ship one fixed slash command, one global shortcut, and one message shortcut. Route them to active workflows by alias or selection.

**Reason:** manifest registrations are static.

### AD-008 — LiveView outline editor

**Decision:** use LiveView and a nested outline/step editor. Do not implement a canvas in the production core.

**Reason:** semantics and operational clarity matter more than visual graph manipulation.

### AD-009 — Application-enforced tenant scope

**Decision:** all tenant context APIs receive a trusted workspace scope. Every tenant query filters by installation ID.

**Reason:** this is simpler than PostgreSQL row-level security for the initial application while remaining testable. Unscoped tenant fetches are forbidden.

### AD-010 — DNS-pinned safe HTTP

**Decision:** generic external HTTP connects to a previously validated IP while preserving the original hostname for TLS.

**Reason:** validating DNS and then connecting by hostname does not prevent rebinding.

## Version snapshot

Snapshot date: **2026-08-15**. Revalidate before scaffolding or upgrading.

| Component | Recommended pin | Reason |
|---|---:|---|
| Elixir | 1.20.3 | Current stable patch |
| Erlang/OTP | 28.x | Supported by Elixir 1.20.3; conservative relative to OTP 29 |
| Phoenix | 1.8.11 | Current stable patch |
| Phoenix LiveView | 1.2.9 | Current stable patch |
| Ecto SQL | 3.14.0 | Current stable |
| Postgrex | 0.22.4 | Current patched release; earlier 0.22.x releases are flagged |
| PostgreSQL | 18.6 | Current supported stable release |
| Oban | 2.23.1 | Current stable; supports transactional insertion and durable scheduling |
| Req | 0.7.2 | Current stable for trusted Pumble API calls |
| Mint | 1.9.3 | Direct low-level client for DNS-pinned external requests |
| Cloak Ecto | 1.3.0, conditional | Mature encrypted Ecto fields; must pass compatibility spike |
| Credo | 1.7.19 | Static analysis |
| Dialyxir | latest compatible at pin gate | Dev/test type analysis; exact pin must be rechecked |
| Sobelow | latest compatible at pin gate | Phoenix security scanner; exact pin must be rechecked |
| tzdata | latest compatible at pin gate | IANA timezone database for schedules |

Do not upgrade dependencies in unrelated implementation tasks. Use a dedicated dependency-update task with tests and release notes.

## Product-facing trigger model

### Pumble event trigger

Expose these initial workflow events:

- new message;
- updated message;
- reaction added;
- channel created;
- workspace user joined.

Treat:

- app uninstalled;
- app unauthorized;

as installation lifecycle events only.

### Manual Pumble trigger

Use a fixed command such as `/workflow` and fixed shortcuts.

A workflow may configure:

- a unique alias;
- whether it appears in the global shortcut picker;
- whether it appears in the message shortcut picker;
- required input fields.

The manifest remains static. The runtime lists eligible active workflows.

### Schedule trigger

Support a typed schedule model:

- once;
- every N minutes or hours;
- daily at local time;
- weekly on selected weekdays at local time.

Do not expose arbitrary cron text initially.

### Inbound webhook trigger

Each endpoint receives a high-entropy opaque token. It may also use an HMAC secret. The endpoint is workspace-scoped, rate-limited, bounded, rotatable, and revocable.

### Test trigger

The web UI may execute a workflow against a stored or supplied fixture. The default test mode suppresses external effects and shows the planned operations. A separate explicit live-test action may execute effects.

## Workflow AST

Recommended editable representation:

```json
{
  "schema_version": 1,
  "trigger": {
    "id": "uuid",
    "type": "pumble_event",
    "config": {}
  },
  "steps": [
    {
      "id": "uuid",
      "type": "condition",
      "config": {"expression": {}},
      "if_true": [],
      "if_false": []
    },
    {
      "id": "uuid",
      "type": "approval",
      "config": {},
      "approved": [],
      "rejected": [],
      "timed_out": []
    }
  ]
}
```

The exact JSON must be finalized in code, but the following rules should remain:

- stable UUID per node;
- one trigger;
- ordered child lists;
- no loops;
- no arbitrary references between user-visible nodes;
- no executable strings;
- no JavaScript or Elixir;
- compiler produces explicit edges and continuation nodes;
- compiler records required scopes and referenced resources.

## Execution semantics

### Execution states

Recommended:

- `QUEUED`
- `RUNNING`
- `WAITING_DELAY`
- `WAITING_APPROVAL`
- `PAUSED_UNCERTAIN`
- `COMPLETED`
- `FAILED`
- `CANCELLED`

### Step states

Recommended:

- `PENDING`
- `RUNNING`
- `WAITING`
- `SUCCEEDED`
- `FAILED`
- `SKIPPED`
- `UNCERTAIN`
- `CANCELLED`

### Attempt states

Recommended:

- `STARTED`
- `SUCCEEDED`
- `RETRYABLE_FAILURE`
- `PERMANENT_FAILURE`
- `UNCERTAIN`
- `CANCELLED`

### Claim-execute-finalize

A worker must:

1. lock the execution and expected step;
2. confirm that the job still matches the current state;
3. create the next attempt and mark the step running;
4. commit;
5. perform the pure operation or external request;
6. lock again;
7. persist result, branch, output, and execution state;
8. insert the next Oban job in the same transaction.

A duplicate or stale job returns success without changing state.

### Ambiguous side effect

Before an external write, persist that dispatch is starting.

If the process receives a definite response:

- success: persist remote reference and continue;
- explicit 4xx: fail permanently, except 429;
- explicit 429: schedule bounded retry;
- explicit retry-safe failure: retry.

If the transport fails after the request may have left the process and no remote idempotency guarantee exists:

- mark attempt uncertain;
- mark step uncertain;
- set execution `PAUSED_UNCERTAIN`;
- do not auto-retry.

An authorized operator may:

- mark effect succeeded and continue;
- mark effect failed and end or branch according to policy;
- explicitly retry and accept duplicate risk.

Every resolution is audited.

## Database assessment

The following schemas are justified. Do not add more until a task proves the need.

### `installations`

Tenant root and Pumble installation state.

Important constraints:

- unique Pumble workspace ID;
- encrypted bot token;
- installation status;
- bot user ID;
- scope snapshot;
- uninstall and deletion timestamps.

### `user_authorizations`

Pumble user-token grants.

Unique by installation and Pumble user.

### `workspace_members`

Local browser authorization.

Roles:

- owner;
- editor;
- viewer.

First successful installer becomes owner. Do not trust unverified Pumble role values.

### `oauth_states`

Hashed one-time OAuth state with intent, expiry, and consumed timestamp.

### `user_sessions`

Hashed high-entropy browser session token, member, expiry, revocation, and last-used metadata.

### `workflows`

Workspace-owned name, slug, mutable draft JSON, draft revision, active version ID, state, and actor timestamps.

### `workflow_versions`

Immutable version number, source definition, compiled definition, hash, required scopes, referenced resources, creator, and activation time.

### `trigger_bindings`

Indexed active bindings by installation, trigger kind, and discriminator.

### `schedules`

Typed schedule config, timezone, next run, last run, status, and active workflow version.

### `webhook_endpoints`

Opaque token digest, optional secret reference, status, workflow binding, and rotation metadata.

### `received_events`

Deduplication key, normalized event, raw-body digest, received time, and short retention.

### `executions`

Workflow/version, trigger event, status, current node, context, lineage, cancellation, timestamps, and optimistic lock.

### `step_executions`

One row per logical node in an execution, unique by execution and node ID.

### `step_attempts`

One row per try, with error class, dispatch markers, remote status/reference, and timing.

### `approvals`

One row per approval step, decision token digest, allowed approvers, Pumble message reference, expiry, and decision.

### `connections`

Reusable external HTTP connection config without raw secrets.

### `secrets`

Encrypted workspace-scoped values with key version and write-only UI.

### `audit_events`

Append-only actor, action, target, and sanitized metadata.

## Browser authentication and authorization default

### Sign-in

Use Pumble OAuth as the canonical sign-in and installation mechanism.

Maintain distinct OAuth intents:

- install;
- reinstall;
- sign in;
- connect user authorization.

Store only a hash of the random state token. Consume it once.

### Pumble-native launch

A Pumble Home view or fixed command may issue a short-lived one-time browser launch token. The browser exchanges it for a normal database-backed session. This avoids long-lived identity data in URLs.

The launch-token path is an enhancement to OAuth sign-in, not a replacement for access control.

### Sessions

Use a random opaque cookie token whose digest is stored in `user_sessions`.

Required behavior:

- Secure, HttpOnly, SameSite=Lax cookie;
- rotate on sign-in and privilege change;
- revoke on logout, uninstall, or member removal;
- absolute and idle expiration;
- LiveView `on_mount` authorization;
- server-side workspace scope;
- CSRF protection for browser requests.

### Roles

- Owner: installation, roles, secrets, activation, uncertain resolution, data deletion.
- Editor: create/edit/test/activate workflows and inspect executions.
- Viewer: read workflows and sanitized executions.
- Approver: not necessarily a web role; approval policy may name any verified workspace user.

## Pumble adapter scope

Implement only:

- OAuth token exchange;
- current profile if needed;
- workspace;
- user list and user info;
- channel list/details and direct channel creation;
- post message;
- reply;
- DM;
- add/remove reaction;
- publish Home view;
- uninstall and authorization lifecycle handling.

Defer file actions, scheduled-message actions, channel creation, message edit/delete, calls, and broad search until a product requirement and idempotency analysis justify them.

## Generic HTTP implementation

Use Req for Pumble because the base host is trusted and fixed.

Use a dedicated Mint-based client for user-controlled destinations.

Required request process:

1. resolve template and secret references;
2. parse URI;
3. require `http` or `https`;
4. reject embedded credentials and nonstandard schemes;
5. enforce port policy;
6. resolve all addresses;
7. reject any blocked address;
8. select and pin one public address;
9. connect with the original hostname for certificate verification and SNI;
10. send a normalized Host header;
11. stream headers and body;
12. stop when the response cap is exceeded;
13. do not request compressed content;
14. do not automatically decode archives;
15. handle redirects manually with fresh validation;
16. return a sanitized typed result.

Blocked ranges must cover IPv4 and IPv6 loopback, private, link-local, multicast, unspecified, documentation, benchmark, carrier-grade NAT, and cloud metadata targets.

## Missing requirements and proposed defaults

| Requirement | Severity | Proposed default |
|---|---|---|
| Product name and app manifest identity | Medium | Use repository/module placeholder `PumbleAutomation`; finalize before marketplace work |
| Web UI authentication | Critical | Pumble OAuth plus revocable DB sessions |
| Workspace roles | Critical | First installer owner; owner/editor/viewer local roles |
| User-defined command names | Critical | Fixed `/workflow` command plus aliases |
| Uncertain external writes | Critical | Durable `PAUSED_UNCERTAIN` state |
| Data retention | High | Raw events 30 days, execution details 90 days, audit 365 days, uninstall grace 30 days |
| Billing/plans | Medium | Explicit non-goal until a commercial model is selected |
| Region/data residency | High | Deployment decision required before production |
| Pumble exact scopes | Critical | Probe and produce scope matrix before manifest freeze |
| Pumble rate limits | High | Probe; conservative bounded queue policy meanwhile |
| Pumble idempotency | Critical | Assume absent until proved |
| User-role mapping | Medium | Do not map Pumble roles automatically until proved |
| Browser launch from Pumble | Medium | OAuth link first; one-time launch token after live probe |
| Workflow limits | High | Conservative defaults in canonical plan |
| Support/admin access | High | No unaudited cross-tenant admin UI; read-only audited support tooling later |
| Paid Marketplace listing | Medium | Out of core release path unless selected |

## Principal risks

### Risk 1 — duplicate side effects

Mitigation: step ledger, stable effect key, per-action retry classification, remote idempotency where supported, and uncertain state.

### Risk 2 — callback timeouts

Mitigation: small signature/dedup/enqueue transaction, immediate protocol-correct response, no workflow execution in the controller.

### Risk 3 — cross-workspace access

Mitigation: trusted workspace scope, scoped context APIs, compound unique constraints, job workspace checks, and adversarial tests.

### Risk 4 — HTTP SSRF

Mitigation: DNS validation and IP pinning, redirect revalidation, response streaming cap, header restrictions, and dedicated tests.

### Risk 5 — automation loops

Mitigation: ignore own bot by default, bot-token actions, lineage depth, duplicate suppression, and hard execution limits.

### Risk 6 — weak-model implementation drift

Mitigation: canonical task IDs, exact invariants, completion gates, progress ledger, and architecture decision log.

### Risk 7 — overbuilding the editor

Mitigation: structured AST and outline UI. No canvas until users prove the need.

## Recommended resource limits

Initial defaults, configurable by environment or plan:

| Resource | Default |
|---|---:|
| Nodes per workflow | 50 |
| Nested branch depth | 8 |
| Draft/definition JSON | 256 KiB |
| Active workflows per workspace | 25 |
| Total workflows per workspace | 100 |
| Schedules per workspace | 100 |
| Concurrent running executions per workspace | 5 |
| Queued executions per workspace | 1,000 |
| Execution context | 256 KiB |
| Single template source | 16 KiB |
| Expanded template value | 64 KiB |
| Pumble callback body | 1 MiB pending probe |
| Generic webhook body | 512 KiB |
| HTTP request body | 256 KiB |
| HTTP response body | 1 MiB |
| Redirects | 3 |
| HTTP connect timeout | 5 seconds |
| HTTP receive timeout | 15 seconds |
| Action retries | 5 maximum |
| Maximum delay | 365 days |
| Maximum execution lifetime | 30 days |
| Lineage depth | 3 |
| Raw received-event retention | 30 days |
| Execution detail retention | 90 days |
| Audit retention | 365 days |
| Uninstall recovery grace | 30 days |

These are safety defaults, not billing entitlements.

## UI quality bar

The initial UI should feel like a finished operational product even without a canvas.

Required:

- consistent spacing and typography;
- clear status badges;
- deterministic nested branch visualization;
- accessible labels and error associations;
- keyboard-reachable controls;
- explicit save state;
- node-local validation errors;
- safe destructive confirmations;
- useful empty states;
- execution timeline;
- clear distinction between retryable, failed, and uncertain;
- responsive layout for laptop and tablet widths;
- no horizontal scrolling for ordinary workflow editing;
- no raw JSON as the primary editor.

## Final assessment

The project is feasible and the proposed stack is appropriate.

The most important architectural choice is not Elixir versus another language. It is the choice to keep the product small and explicit:

- static Pumble entry points;
- structured workflows;
- immutable versions;
- PostgreSQL truth;
- Oban continuations;
- narrow adapters;
- no false exactly-once claim;
- first-class uncertain outcomes;
- DNS-pinned HTTP;
- LiveView outline editor;
- evidence-backed release certification.

That combination reaches a production-grade end state without importing the complexity of a general integration platform.
