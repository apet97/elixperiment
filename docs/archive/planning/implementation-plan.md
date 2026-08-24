# PUMBLE WORKFLOW AUTOMATION — PERFECT END STATE IMPLEMENTATION PLAN

> [!WARNING]
> Historical implementation plan from the repository's greenfield phase. It is
> retained for traceability, not as current product status or authority. See the
> [current documentation](../../README.md).

**Canonical artifact:** `PUMBLE_WORKFLOW_AUTOMATION_PERFECT_END_STATE_IMPLEMENTATION_PLAN.md`  
**Plan version:** 1.0  
**Evidence snapshot date:** 2026-08-15  
**Implementation status at creation:** planning-only; no application repository was supplied  
**Primary stack:** Elixir, Phoenix, LiveView, Ecto, PostgreSQL, Oban  
**Architecture:** modular monolith  
**Production Pumble transport:** HTTP callbacks

---

## 1. Executive summary

Build a multi-workspace Pumble workflow-automation add-on as one Phoenix application backed by PostgreSQL.

Users create a typed, loop-free workflow in a LiveView outline editor. A workflow contains one trigger and an ordered tree of steps. Conditions and approvals own nested branches. Activation validates the draft and compiles it into an immutable executable graph. Every execution references exactly one workflow version.

Pumble callbacks enter through a small transport boundary:

```text
bounded body
-> raw-byte signature verification
-> payload classification
-> normalization
-> durable deduplication
-> indexed trigger lookup
-> execution creation
-> transactional Oban insertion
-> protocol-correct acknowledgement
```

Oban jobs advance executions. PostgreSQL owns all durable state. A worker uses a claim-execute-finalize pattern. Duplicate or stale jobs become no-ops.

The system does not claim exactly-once delivery. Pumble and generic HTTP writes are classified by retry safety. If a write may have succeeded but the system cannot prove the outcome, the execution enters `PAUSED_UNCERTAIN`. An authorized operator must resolve it. The system does not automatically repeat a non-idempotent ambiguous effect.

The first production UI is not a node canvas. It is a polished nested step editor with validation, version history, execution timelines, secrets, connections, members, and operational controls.

The initial product uses static Pumble manifest entry points:

- one fixed slash command;
- one fixed global shortcut;
- one fixed message shortcut;
- fixed callback routes;
- fixed subscribed events.

User workflows route through aliases and selection screens behind those entry points.

The application reaches completion only after offline tests, adversarial failure tests, deployment proof, live certification in a sacrificial Pumble workspace, reinstall/uninstall proof, backup restore proof, marketplace preparation, and rollback proof.

---

## 2. Source coverage

### 2.1 `01-overview-and-project-map.md`

Material effect:

- confirms the supplied corpus is a compressed map of the Pumble Node SDK, CLI, examples, docs, and deployment guidance;
- shows the runtime path from manifest to listener to handler context to API client;
- establishes that the SDK is a behavioral source, not a requirement to port all exports.

### 2.2 `02-core-framework-auth-and-runtime.md`

Material effect:

- defines HTTP and Socket Mode behavior;
- documents OAuth token exchange and token-store responsibilities;
- documents raw-body HMAC signature verification;
- documents bot/user client selection;
- establishes the three-second acknowledgement requirement;
- shows that event callbacks and interactive callbacks have different contracts.

### 2.3 `03-api-clients-and-v1-type-system.md`

Material effect:

- defines the Pumble API headers;
- identifies the proven message, channel, user, workspace, app, reaction, Home-view, file, and scheduled-message operations;
- states that the client does not add automatic retries;
- provides the error-status basis for the adapter taxonomy.

### 2.4 `04-events-contexts-interactivity-and-blocks.md`

Material effect:

- defines the seven subscribed events;
- provides abbreviated wire-field names;
- defines slash, shortcut, interaction, view, and dynamic-menu payloads;
- defines which callback types acknowledge, respond, or have no acknowledgement;
- supplies the block and view structures needed for approvals and Pumble-native entry points.

### 2.5 `05-cli-examples-docs-and-deployment.md`

Material effect:

- confirms manifest registrations are deployment/configuration artifacts;
- shows how examples use Pumble Home, modals, commands, interactions, webhooks, and external persistence;
- confirms production HTTP guidance and manifest secret stripping;
- supplies marketplace and pre-publish behavior;
- confirms there is no dedicated official mock package, so this repository must build its own contract harness.

### 2.6 Other repository/project artifacts

No implementation repository, source tree, tests, deployment receipts, database schema, or live Pumble evidence was supplied with this planning request.

---

## 3. Current-state assessment

| Area | Status | Evidence |
|---|---|---|
| Application repository | NOT VERIFIED | Not supplied |
| Phoenix application | NOT VERIFIED | Not supplied |
| Pumble callback endpoint | NOT VERIFIED | Not supplied |
| OAuth/install flow | NOT VERIFIED | Not supplied |
| PostgreSQL schema | NOT VERIFIED | Not supplied |
| Workflow model | NOT VERIFIED | Not supplied |
| Execution engine | NOT VERIFIED | Not supplied |
| Oban jobs | NOT VERIFIED | Not supplied |
| LiveView UI | NOT VERIFIED | Not supplied |
| Tests | NOT VERIFIED | Not supplied |
| Deployment | NOT VERIFIED | Not supplied |
| Marketplace state | NOT VERIFIED | Not supplied |

At implementation time, Phase 0 must inspect the actual repository. Existing proved capabilities become `COMPLETE`; existing unproved capabilities become `REVERIFY`; missing capabilities remain `NOT STARTED`.

---

## 4. Fact, inference, and unknown matrix

### 4.1 Facts

- The supplied Pumble corpus documents seven subscribed events.
- Pumble events are distinct from slash commands, shortcuts, block interactions, view actions, and dynamic menus.
- Slash commands, shortcuts, block interactions, and view actions require acknowledgement within three seconds.
- Dynamic menus require an options response and do not use the normal acknowledgement contract.
- Production callback signatures use HMAC-SHA256 over raw request bytes with constant-time comparison.
- OAuth exchanges an authorization code for a response containing workspace, user, access token, optional bot token, and optional bot ID.
- Bot and user credentials are retrieved separately.
- Pumble API calls use `token` and `x-app-token` headers.
- The supplied Pumble client does not implement retries.
- HTTP and Socket Mode are available.
- The supplied production guidance favors HTTP for marketplace-grade add-ons.
- The manifest processor removes app secrets before serving or publication.
- Pumble supports the selected initial message, reply, DM, reaction, Home-view, user, channel, workspace, and lifecycle operations.

### 4.2 Inferences adopted by this plan

- Runtime-created workflows cannot register arbitrary new Pumble command names or shortcuts.
- The app should use fixed Pumble entry points and route internally.
- Lifecycle events should manage installation state, not trigger user workflows.
- A structured AST is sufficient and materially simpler than a free-form graph.
- Bot-token writes should be the default.
- One application and one database are sufficient until production evidence proves otherwise.
- Application-level tenant scoping is sufficient when backed by strict context APIs, compound constraints, and adversarial tests.
- An external write with an ambiguous outcome must pause rather than retry automatically.

### 4.3 Unknowns requiring probes

- stable unique delivery identities for all callback types;
- exact replay behavior;
- signature-header precedence and any timestamp header;
- OAuth token expiry and refresh behavior;
- reinstall token replacement;
- uninstall/unauthorized event ordering;
- exact scope matrix;
- Pumble rate-limit headers;
- Pumble server-side idempotency;
- app-generated message metadata;
- exact Pumble role values;
- callback and message size limits;
- Marketplace launch-link behavior.

These unknowns are tracked in Phase 0 and certified in Phase 17.

---

## 5. Product contract

### 5.1 Supported trigger categories

#### Pumble event

Initial user-visible event triggers:

- `NEW_MESSAGE`;
- `UPDATED_MESSAGE`;
- `REACTION_ADDED`;
- `CHANNEL_CREATED`;
- `WORKSPACE_USER_JOINED`.

Control-plane events:

- `APP_UNINSTALLED`;
- `APP_UNAUTHORIZED`.

Control-plane events are not user-selectable workflow triggers.

#### Manual Pumble entry

Static manifest entries:

- one slash command, default proposed name `/workflow`;
- one global shortcut, default proposed name `Run workflow`;
- one message shortcut, default proposed name `Run workflow on message`.

An active workflow may declare a unique manual alias and whether it appears in each picker.

#### Schedule

Initial schedule types:

- once;
- every N minutes;
- every N hours;
- daily at local time;
- weekly on selected weekdays at local time.

#### Inbound webhook

A workspace-scoped endpoint with a high-entropy token and optional HMAC secret.

#### Test/manual browser execution

Dry-run by default. External effects require an explicit live-test action.

### 5.2 Logic nodes

- condition;
- AND;
- OR;
- NOT;
- true branch;
- false branch;
- delay;
- approval with approved/rejected/timeout branches;
- stop.

No loops in v1.

### 5.3 Action nodes

Initial production actions:

- send Pumble message;
- reply to a triggering or referenced Pumble message;
- direct-message a Pumble user;
- add reaction;
- remove reaction;
- generic external HTTP request.

Deferred until proven necessary:

- edit/delete Pumble message;
- channel creation or membership changes;
- file upload;
- scheduled Pumble message;
- message search;
- native connectors.

### 5.4 Management capabilities

- install and reinstall;
- sign in to web UI;
- manage members and roles;
- create workflow;
- edit draft;
- validate;
- dry-run test;
- activate/deactivate;
- view immutable versions;
- inspect executions, steps, attempts, and sanitized values;
- cancel;
- safe retry;
- resolve uncertain outcomes;
- manage secrets and external HTTP connections;
- inspect audit history;
- uninstall and delete data.

---

## 6. Explicit non-goals

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

A secure generic HTTP action provides broad integration capability before native connectors exist.

---

## 7. Architecture decision log

| ID | Decision | Rationale |
|---|---|---|
| ADR-001 | Modular monolith | Simplest deployable architecture and strongest transaction boundary |
| ADR-002 | HTTP callbacks in production | Source-supported, signed, marketplace-aligned |
| ADR-003 | PostgreSQL is durable truth | Survives process, node, and deployment loss |
| ADR-004 | Oban for asynchronous progression | Durable jobs in the same database; transactional insertion |
| ADR-005 | Structured AST compiled to graph | Simple editing and deterministic execution without graph bloat |
| ADR-006 | Immutable executable versions | Running executions never change program |
| ADR-007 | Fixed Pumble command and shortcuts | Manifest registrations are static |
| ADR-008 | LiveView outline editor | Product quality without premature React/canvas complexity |
| ADR-009 | At-least-once plus uncertainty | Honest semantics for duplicate delivery and ambiguous writes |
| ADR-010 | DNS-pinned generic HTTP | Required to defend against rebinding |
| ADR-011 | Local owner/editor/viewer roles | Avoid unproved Pumble role mapping |
| ADR-012 | Bot-token actions by default | Better permission clarity and loop prevention |
| ADR-013 | No PII-heavy logs | Operational visibility without unnecessary content exposure |
| ADR-014 | Expand-contract database changes | Safe application rollback |

Any implementation-driven architecture change must add an ADR entry with evidence and update affected tasks and acceptance tests.

---

## 8. Dated dependency snapshot

Snapshot date: **2026-08-15**.

| Component | Pin target |
|---|---:|
| Elixir | 1.20.3 |
| Erlang/OTP | 28.x |
| Phoenix | 1.8.11 |
| Phoenix LiveView | 1.2.9 |
| Ecto SQL | 3.14.0 |
| Postgrex | 0.22.4 |
| PostgreSQL | 18.6 |
| Oban | 2.23.1 |
| Req | 0.7.2 |
| Mint | 1.9.3 |
| Cloak Ecto | 1.3.0, after compatibility proof |
| Credo | 1.7.19 |
| Dialyxir | latest compatible at Phase 2 pin gate |
| Sobelow | latest compatible at Phase 2 pin gate |
| tzdata | latest compatible at Phase 2 pin gate |

Version rules:

- revalidate before scaffolding;
- pin exact direct dependency versions in `mix.lock`;
- do not opportunistically upgrade during feature work;
- run a dedicated dependency update with changelog review, full tests, audit, and release build;
- do not use a vulnerable or retired package release.

---

## 9. Final architecture

```text
Pumble
  |
  | HTTPS callbacks
  v
Phoenix Endpoint
  |-- body-size gate
  |-- raw-body cache
  |-- HMAC verification
  |-- callback classifier
  |
  +--> interactive acceptance/response path (< 3 seconds)
  |
  v
Ingress
  |-- normalize
  |-- deduplicate
  |-- persist
  |-- active trigger lookup
  |-- create executions
  |-- insert Oban jobs in Ecto.Multi
  v
PostgreSQL <-------------------------------+
  ^                                        |
  |                                        |
Workflows ---- compiled immutable graph    |
  |                                        |
Executions ---- claim/execute/finalize -----+
  |              |            |
  |              |            +--> Safe HTTP / Mint
  |              +----------------> Pumble / Req
  |
LiveView UI
```

### 9.1 Oban queues

Initial queues:

- `ingress`: 20;
- `executions`: 20;
- `schedules`: 2;
- `maintenance`: 2.

These are starting limits, not permanent scaling values.

### 9.2 Allowed domain dependencies

```text
Web -> Installations, Workflows, Executions, Connections, Audit
Ingress -> Installations, Workflows, Executions, Audit
Executions -> Workflows, Installations, Pumble, Connections, Audit
Workflows -> Installations, Connections, Audit
Pumble -> no domain context
Connections -> Installations, Audit
Audit -> Installations identity references only
```

Forbidden:

- Pumble adapter querying workflow tables;
- controllers issuing workflow SQL directly;
- LiveViews bypassing authorization contexts;
- jobs carrying raw credentials;
- Workflows executing side effects;
- Connections deciding workflow transitions.

---

## 10. Proposed repository structure

Adapt names if an existing repository already has coherent conventions.

```text
lib/
  pumble_automation/
    application.ex
    repo.ex
    oban.ex
    scope.ex
    crypto/
      vault.ex
      encrypted_binary.ex

    installations/
      installation.ex
      user_authorization.ex
      workspace_member.ex
      oauth_state.ex
      user_session.ex
      service.ex
      policy.ex

    pumble/
      signature.ex
      payload.ex
      classifier.ex
      normalizer.ex
      manifest.ex
      scopes.ex
      blocks.ex
      client.ex
      client/error.ex
      client/transport.ex

    workflows/
      workflow.ex
      workflow_version.ex
      trigger_binding.ex
      schedule.ex
      definition.ex
      node.ex
      validator.ex
      compiler.ex
      activation.ex
      templates.ex
      expressions.ex
      schedule_calculator.ex

    ingress/
      received_event.ex
      webhook_endpoint.ex
      deduplication.ex
      trigger_matcher.ex
      service.ex

    executions/
      execution.ex
      step_execution.ex
      step_attempt.ex
      approval.ex
      state_machine.ex
      engine.ex
      node_runner.ex
      outcome.ex
      workers/
        advance_execution_worker.ex
        schedule_dispatcher_worker.ex
        approval_timeout_worker.ex
        retention_worker.ex
        reconciliation_worker.ex

    connections/
      secret.ex
      connection.ex
      resolver.ex
      safe_http.ex
      ip_policy.ex

    audit/
      audit_event.ex
      writer.ex

  pumble_automation_web/
    endpoint.ex
    router.ex
    telemetry.ex
    components/
    controllers/
      oauth_controller.ex
      pumble_callback_controller.ex
      inbound_webhook_controller.ex
      health_controller.ex
      session_controller.ex
    plugs/
      cache_raw_body.ex
      verify_pumble_signature.ex
      fetch_session.ex
      require_member.ex
      load_scope.ex
    live/
      onboarding_live.ex
      workflow_live/
      execution_live/
      connection_live/
      secret_live/
      member_live/
      audit_live/

priv/
  repo/migrations/
  pumble/
    manifest.template.json
    fixtures/

test/
  support/
    data_case.ex
    conn_case.ex
    pumble_fake.ex
    failure_injector.ex
    tenant_assertions.ex
```

Do not create an interface or directory merely to match this tree. Each module must own current behavior.

---

## 11. Browser identity and authorization

### 11.1 OAuth intents

Persist one-time OAuth states for:

- installation;
- reinstall;
- browser sign-in;
- connecting or refreshing a user authorization.

Store only a SHA-256 digest of a 256-bit random state token.

State fields:

- digest;
- intent;
- installation hint;
- return path;
- expires at;
- consumed at;
- request metadata.

State is one-time and expires in ten minutes.

### 11.2 Sessions

Use opaque random session tokens.

Cookie:

- Secure;
- HttpOnly;
- SameSite=Lax;
- path `/`;
- no token data in local storage.

Database stores:

- token digest;
- member;
- issued at;
- last used at;
- idle expiry;
- absolute expiry;
- revoked at;
- user agent hash if used.

Rotate the session after sign-in, role change, and sensitive actions.

### 11.3 Roles

- `OWNER`: installation, members, secrets, activation, deletion, uncertain resolution.
- `EDITOR`: workflows, tests, activation, execution retry/cancel.
- `VIEWER`: read workflows and sanitized executions.

Approver identity is independent from web role.

Every LiveView loads a trusted `%Scope{installation_id, member_id, role}` through `on_mount`.

---

## 12. Pumble integration design

### 12.1 HTTP transport

Production callback paths are fixed and HTTPS-only.

The endpoint must:

1. reject oversized bodies;
2. retain exact raw bytes;
3. compute HMAC-SHA256 with the signing secret;
4. compare in constant time;
5. reject missing or malformed signatures;
6. parse JSON only for dispatch after raw bytes are retained;
7. classify the callback;
8. return the correct protocol response.

No production bypass when signing secret is absent.

### 12.2 Callback classes

- ordinary Pumble event;
- slash command;
- global shortcut;
- message shortcut;
- block interaction;
- view action;
- dynamic menu.

Each class has its own response contract.

Dynamic-menu handling remains synchronous and bounded. It is used for product UI selection, not arbitrary long workflow execution.

### 12.3 Normalized event

Recommended internal shape:

```elixir
%AutomationEvent{
  provider: :pumble,
  installation_id: uuid,
  kind: :event | :slash_command | :global_shortcut | :message_shortcut | :block | :view,
  type: string,
  actor_id: string | nil,
  channel_id: string | nil,
  resource_id: string | nil,
  thread_root_id: string | nil,
  occurred_at: DateTime.t() | nil,
  delivery_key: string,
  data: map
}
```

The final struct must be derived from fixtures and probes.

Pumble abbreviated fields do not cross the adapter boundary.

### 12.4 Pumble client

Use Req against a fixed configured Pumble base URL.

Every request includes:

- token;
- `x-app-token`;
- JSON content type where applicable;
- correlation metadata in local telemetry only.

The client returns typed success or `%Pumble.Client.Error{class, status, retry_after, body_summary}`.

No automatic write retry inside the transport.

---

## 13. OAuth and installation lifecycle

### Install

1. create OAuth state;
2. redirect to Pumble consent;
3. verify and consume state;
4. exchange code;
5. upsert installation by Pumble workspace ID;
6. encrypt tokens;
7. store bot ID and scope snapshot;
8. create/update the initiating member;
9. make the first member owner if no owner exists;
10. create session;
11. publish onboarding Home view if scope permits;
12. audit.

### Reinstall

- replace credentials atomically;
- update scope snapshot;
- preserve workflows and versions;
- revalidate active workflows against scopes;
- disable only workflows with known missing required scopes;
- revoke old sessions only if authorization identity changed;
- audit old/new scope sets without tokens.

### Unauthorized

- identify affected user authorization or installation;
- mark it revoked;
- stop using the token immediately;
- invalidate dependent sessions when needed;
- mark affected workflows degraded or disabled;
- do not delete data.

### Uninstall

- mark installation uninstalled;
- disable trigger bindings and schedules;
- revoke sessions;
- prevent new executions;
- allow running workers to observe uninstall and stop before new side effects;
- cancel queued jobs best effort;
- retain data for a 30-day recovery/deletion grace period;
- purge credentials immediately;
- schedule final data deletion;
- audit.

---

## 14. Database model

All tenant-owned tables include `installation_id` directly or through a mandatory parent and have indexes supporting tenant-scoped access.

### 14.1 Installation and identity tables

#### `installations`

- primary key: UUID;
- unique: `pumble_workspace_id`;
- fields: status, workspace name snapshot, bot user ID, encrypted bot token, token key version, bot/user scopes, installed by user, authorized/revoked/uninstalled/deletion timestamps;
- sensitive: tokens;
- lifecycle: active -> degraded/revoked/uninstalled -> deleted.

#### `user_authorizations`

- primary key: UUID;
- foreign key: installation;
- unique: installation + Pumble user ID;
- encrypted token and scope snapshot;
- status and revoked timestamp.

#### `workspace_members`

- primary key: UUID;
- foreign key: installation;
- unique: installation + Pumble user ID;
- local role;
- profile snapshot;
- disabled timestamp.

#### `oauth_states`

- primary key: UUID;
- unique state digest;
- intent, expiry, consumed timestamp;
- delete after expiry plus short audit window.

#### `user_sessions`

- primary key: UUID;
- member;
- unique token digest;
- expiry and revocation;
- no raw token.

### 14.2 Workflow tables

#### `workflows`

- UUID;
- installation;
- name, slug, description;
- mutable draft definition JSONB;
- draft revision integer;
- state;
- active version ID;
- creator/updater;
- archived timestamp;
- unique installation + slug.

#### `workflow_versions`

- UUID;
- workflow and installation;
- monotonically increasing version number;
- source definition JSONB;
- compiled definition JSONB;
- SHA-256 definition hash;
- required scopes;
- referenced secret/connection IDs;
- created by and activated at;
- unique workflow + version;
- no update API after insert.

#### `trigger_bindings`

- UUID;
- installation and workflow version;
- trigger kind;
- discriminator fields;
- normalized filter config;
- enabled;
- indexes by installation + kind + discriminator;
- unique binding identity per version.

#### `schedules`

- UUID;
- installation, workflow, active workflow version;
- schedule type/config/timezone;
- next and last run;
- status and lock version;
- unique workflow active schedule identity.

### 14.3 Ingress tables

#### `webhook_endpoints`

- UUID;
- installation and workflow;
- token digest;
- optional secret ID;
- status;
- rotated/last used timestamps;
- no raw token after creation.

#### `received_events`

- UUID;
- installation;
- source;
- delivery key;
- event type;
- normalized payload JSONB;
- raw payload digest;
- occurred/received timestamps;
- processing status;
- unique installation + source + delivery key;
- short retention.

### 14.4 Execution tables

#### `executions`

- UUID;
- installation;
- workflow and immutable version;
- received event optional;
- unique execution key;
- state;
- current node ID;
- context JSONB;
- root execution ID and lineage depth;
- cancellation fields;
- lock version;
- timestamps.

#### `step_executions`

- UUID;
- installation and execution;
- node ID and node type;
- state;
- sanitized resolved input/output;
- selected edge;
- effect key;
- remote reference;
- uncertainty reason;
- timestamps;
- unique execution + node ID.

#### `step_attempts`

- UUID;
- step execution;
- attempt number;
- state;
- dispatch-started timestamp;
- error class/code;
- remote status/request ID;
- retry time;
- duration;
- unique step + attempt number.

#### `approvals`

- UUID;
- installation, execution, step;
- state;
- decision token digest/nonce;
- allowed approver policy;
- Pumble channel/message references;
- expiry;
- decision actor/time;
- unique step.

### 14.5 Connections and audit

#### `secrets`

- UUID;
- installation;
- unique name;
- authenticated ciphertext;
- key version;
- value fingerprint;
- description;
- rotation and last-used timestamps;
- value is write-only.

#### `connections`

- UUID;
- installation;
- unique name;
- type `http`;
- base URL;
- auth/config without secret values;
- referenced secret IDs;
- status.

#### `audit_events`

- UUID;
- installation;
- actor type/ID;
- action;
- target type/ID;
- sanitized metadata;
- correlation ID;
- timestamp;
- append only.

---

## 15. Workflow AST

### 15.1 Editable source

```json
{
  "schema_version": 1,
  "trigger": {
    "id": "uuid",
    "type": "pumble_event",
    "config": {}
  },
  "steps": []
}
```

Node types:

- `condition`;
- `delay`;
- `approval`;
- `pumble_action`;
- `http_action`;
- `stop`.

Condition owns:

- `if_true`;
- `if_false`.

Approval owns:

- `approved`;
- `rejected`;
- `timed_out`.

Every branch is an ordered list.

### 15.2 Compiler output

```json
{
  "schema_version": 1,
  "entry_node_id": "uuid",
  "nodes": {
    "uuid": {
      "type": "condition",
      "config": {},
      "edges": {
        "true": "uuid-or-null",
        "false": "uuid-or-null"
      }
    }
  },
  "required_scopes": [],
  "trigger_binding": {},
  "definition_hash": "sha256"
}
```

The compiler may create internal continuation nodes, but user-visible node IDs remain stable.

### 15.3 Validation invariants

- exactly one trigger;
- supported schema version;
- unique node IDs;
- known node types;
- branch depth <= 8;
- total nodes <= 50;
- all required config present;
- templates and expressions valid;
- referenced steps exist and precede use;
- secrets and connections belong to the same installation;
- required Pumble context is available;
- delay and schedule limits valid;
- known required scopes are granted;
- no compiled cycle;
- compiled entry reaches every node;
- deterministic definition hash.

---

## 16. Activation and versioning

Activation is one `Ecto.Multi`.

It must:

1. lock workflow;
2. verify draft revision;
3. validate and compile;
4. insert next immutable version;
5. disable old active trigger bindings;
6. insert new trigger bindings;
7. replace schedule binding;
8. update active version and state;
9. insert any schedule-dispatch job needed;
10. append audit event;
11. commit atomically.

If any operation fails, no partial activation exists.

Deactivation:

- disables bindings and schedules;
- does not cancel running executions by default;
- prevents new executions;
- audits.

Version rollback:

- reactivates a prior immutable version through the same activation transaction;
- does not mutate the old version;
- records a new activation event.

---

## 17. Event ingestion and trigger matching

### 17.1 Deduplication keys

Use the strongest source key available.

Pumble event priority:

1. documented request ID in the event body;
2. callback-level stable ID proved by probe;
3. deterministic fallback hash of stable envelope fields and body digest, with explicit collision limitations.

Interactions:

- use trigger ID plus callback class and stable action/view/source identifiers after live proof;
- otherwise store a deterministic envelope digest.

Inbound webhook:

- caller-supplied idempotency header when configured;
- otherwise endpoint ID + body digest + bounded time bucket, with documented semantics.

Schedule:

- schedule ID + scheduled-for UTC instant.

Manual web execution:

- generated one-time request UUID.

### 17.2 Matching

Query active bindings by:

- installation;
- trigger kind;
- primary discriminator such as event type or manual alias.

Evaluate remaining typed filters in memory.

Do not scan inactive versions or every workflow.

### 17.3 Interactive timing

The pre-ack path may perform only:

- signature verification;
- minimum payload validation;
- dedupe insert;
- execution insert;
- Oban insert;
- small response construction.

It must not call Pumble or external APIs before acknowledgement.

If the durable acceptance transaction fails, return a protocol-correct failure before the deadline.

---

## 18. Deduplication, idempotency, and delivery semantics

### 18.1 Guaranteed properties

The system guarantees:

- one stored received-event row per accepted dedupe key;
- one logical execution per execution key;
- one logical step row per execution/node;
- stale jobs do not advance state;
- completed steps are not executed again by duplicate jobs;
- state transitions preserve database invariants.

### 18.2 Not guaranteed

The system does not guarantee:

- exactly one callback delivery;
- exactly one job attempt;
- exactly one remote effect when the remote API lacks idempotency and the outcome is ambiguous.

### 18.3 Effect key

Every effectful step has a stable effect key:

```text
installation_id / execution_id / node_id
```

Pass it to a remote idempotency header only when the remote system supports such a header or the workflow owner explicitly configures it.

### 18.4 Uncertain outcome

A write enters uncertainty when:

- request dispatch began;
- no definitive response was obtained;
- remote idempotency cannot prove safe retry.

The system stores:

- effect key;
- attempt;
- request summary;
- error class;
- timing;
- whether bytes may have left;
- available remote correlation ID;
- operator guidance.

It then pauses.

---

## 19. Execution state machine

```text
QUEUED
  -> RUNNING
      -> WAITING_DELAY
      -> WAITING_APPROVAL
      -> PAUSED_UNCERTAIN
      -> COMPLETED
      -> FAILED
      -> CANCELLED
```

Allowed transitions are centralized in one pure state-machine module.

Examples:

- `QUEUED -> RUNNING`;
- `RUNNING -> WAITING_DELAY`;
- `WAITING_DELAY -> RUNNING`;
- `RUNNING -> WAITING_APPROVAL`;
- `WAITING_APPROVAL -> RUNNING`;
- `RUNNING -> PAUSED_UNCERTAIN`;
- `PAUSED_UNCERTAIN -> RUNNING|FAILED|COMPLETED`;
- nonterminal -> `CANCELLED`;
- terminal states have no ordinary outgoing transition.

Database updates use row locks and optimistic lock versions.

---

## 20. Oban and transaction model

### 20.1 Job types

- `AdvanceExecutionWorker`;
- `ScheduleDispatcherWorker`;
- `ApprovalTimeoutWorker`;
- `RetentionWorker`;
- `ReconciliationWorker`.

Avoid one worker class per node.

### 20.2 Job payloads

Jobs contain identifiers and expected state only:

```json
{
  "installation_id": "uuid",
  "execution_id": "uuid",
  "expected_node_id": "uuid",
  "generation": 3
}
```

No tokens, secret values, full message bodies, or HTTP bodies.

### 20.3 Transaction boundaries

#### Create execution

Atomically:

- insert execution;
- insert initial step if desired;
- insert Oban advance job.

#### Finalize step

Atomically:

- mark attempt;
- mark step;
- update execution current node/state/context;
- insert next job or timeout job;
- append audit event when required.

#### Approval decision

Atomically:

- lock approval;
- verify pending and authorized;
- persist decision;
- update execution;
- insert resume job.

#### Schedule dispatch

Atomically:

- lock due schedule;
- insert execution with unique schedule occurrence key;
- insert first job;
- calculate and persist next run.

### 20.4 Oban uniqueness

Use unique jobs to reduce duplicate queue entries, but database execution/step invariants remain authoritative.

---

## 21. Conditions, paths, and templates

### 21.1 Path resolver

Allowed roots:

- `trigger`;
- `steps.<node_id>.output`;
- `execution`;
- `workspace`;
- `actor`.

No arbitrary map traversal outside allowed roots.

### 21.2 Condition representation

Structured JSON, not text code.

Operators:

- `eq`, `neq`;
- `gt`, `gte`, `lt`, `lte`;
- `contains`, `starts_with`, `ends_with`;
- `in`;
- `is_present`;
- `and`, `or`, `not`.

Type errors are validation errors when static and runtime failures when input-dependent.

### 21.3 Templates

Syntax:

```text
{{ trigger.message.text }}
{{ steps.<node_id>.output.ticket_id }}
```

Secret references use a separate structured field or explicit form:

```text
{{ secret.API_TOKEN }}
```

Secret values may be used in outbound headers/body but never persisted in resolved input/output or logs.

Missing-value policy is configured per field:

- fail;
- empty string;
- null.

Default: fail.

---

## 22. Delay semantics

A delay node:

1. resolves a duration or target time;
2. validates maximum delay;
3. stores `resume_at`;
4. marks step waiting;
5. marks execution `WAITING_DELAY`;
6. inserts a scheduled advance job transactionally.

On wake:

- worker verifies execution still waits on that node;
- early jobs snooze or reschedule;
- duplicate jobs no-op after continuation;
- cancellation prevents continuation;
- workflow edits do not affect the old version.

Never use `Process.sleep` or a long-lived timer.

---

## 23. Schedule semantics

### Timezone

Store an IANA timezone.

### DST

- nonexistent local time: use the first valid instant after the gap;
- ambiguous local time: use the earlier occurrence once.

### Dispatcher

A static Oban cron entry runs the dispatcher every minute.

The dispatcher:

- selects due rows with `FOR UPDATE SKIP LOCKED`;
- creates unique scheduled executions;
- advances `next_run_at`;
- handles a bounded batch;
- records lag metrics.

Editing a schedule only affects future runs. Existing executions keep their version.

---

## 24. Approval semantics

The approval node sends a Pumble message with approve and reject buttons.

Button payload contains an opaque signed token identifying:

- approval;
- decision;
- nonce;
- expiry.

The database stores a digest or nonce and authoritative status.

Allowed approvers in v1:

- specific Pumble users;
- workflow owners/editors;
- trigger actor, when configured.

Decision flow:

1. verify Pumble signature;
2. acknowledge quickly;
3. lock approval;
4. verify pending, token, expiry, and actor;
5. persist decision;
6. update execution;
7. enqueue resume;
8. update Pumble message best effort;
9. audit.

Duplicate valid clicks return the existing decision without a second resume.

---

## 25. Pumble action semantics

### Send message

Inputs:

- channel ID template;
- text;
- optional supported blocks.

Use bot token by default.

### Reply

Requires a triggering or referenced channel/message/thread identity.

Validation rejects workflows where required message context cannot exist.

### Direct message

Resolve or create a direct channel using the documented API, then send.

### Reactions

Add/remove reaction against a referenced message.

### Error policy

- 400: permanent configuration/input failure;
- 401: installation/user authorization revoked;
- 403: missing scope or forbidden;
- 404: missing target, permanent unless product policy says otherwise;
- 429: retry using `Retry-After` when present;
- explicit 5xx on writes: uncertain unless live evidence proves safe retry;
- connection failure before dispatch: retryable;
- timeout or connection loss after dispatch may have begun: uncertain.

---

## 26. Generic HTTP action

### Supported

- GET, HEAD, POST, PUT, PATCH, DELETE;
- HTTPS by default;
- HTTP only with owner-level explicit override and warning;
- query parameters;
- controlled headers;
- JSON or text body;
- JSON response extraction;
- status matching;
- stable optional idempotency header.

### Blocked headers

At minimum:

- Host;
- Content-Length;
- Transfer-Encoding;
- Connection;
- Proxy-Authorization;
- Proxy-Connection;
- Upgrade;
- TE;
- Trailer.

### SSRF algorithm

1. render URL without leaking secrets;
2. parse URI;
3. reject userinfo;
4. validate scheme, host, and port;
5. resolve A and AAAA;
6. reject if any selected address is blocked;
7. connect to a validated IP tuple;
8. set original hostname for SNI and certificate verification;
9. send original Host header;
10. stream response;
11. stop at hard byte cap;
12. disable compression/decompression;
13. handle redirects manually;
14. re-resolve and revalidate every redirect;
15. cap redirects at three.

### Retry policy

- GET/HEAD: retry explicit transient failures up to five;
- PUT/DELETE: retry only when user marks the endpoint idempotent or provides a remote idempotency key;
- POST/PATCH: no automatic retry after ambiguous dispatch without remote idempotency;
- 429 and 503 may use `Retry-After`;
- all retries are bounded by execution lifetime.

---

## 27. Security threat model

| Threat | Boundary | Mitigation | Automated proof |
|---|---|---|---|
| Cross-workspace access | Context/query | Trusted scope and compound filters | Tenant adversarial tests |
| OAuth CSRF | OAuth callback | One-time hashed state | Invalid/reused/expired state tests |
| Forged callback | Pumble ingress | Raw-body HMAC and constant-time compare | Valid/invalid fixture tests |
| Replay | Ingress | Durable dedupe key | Duplicate-delivery tests |
| Token leak | Storage/logging | Authenticated encryption and redaction | Log capture and secret scan |
| SSRF | HTTP action | Resolve, reject, pin, revalidate redirects | IP-range and rebinding tests |
| Workflow bomb | Compiler/runtime | Node, depth, size, lifetime limits | Limit tests |
| Recursion loop | Pumble events | Own-bot filter and lineage ceiling | Loop tests |
| Job flood | Ingress/schedules | Workspace limits and rate controls | Quota tests |
| Approval spoof | Interaction | Actor policy and one-time token | Unauthorized/double-click tests |
| Scope escalation | Pumble client | Explicit required-scope matrix | Activation/scope tests |
| Log leakage | Observability | Field allowlist and redaction | Captured-log tests |
| Stored content injection | LiveView | Escaped rendering and CSP | UI security tests |
| Admin abuse | Support tools | No unscoped access; audited operations | Authorization tests |
| Dependency compromise | Build | Lockfile, audit, minimal deps | Hex audit and review |

---

## 28. Multi-tenancy

Use `%PumbleAutomation.Scope{installation_id, member_id, role}`.

Rules:

- every browser context function receives a scope;
- every tenant query filters installation ID;
- tenant objects are fetched by `(installation_id, id)`;
- jobs carry installation ID and verify it against the loaded record;
- callbacks derive installation from verified payload/workspace mapping;
- webhook token lookup resolves one installation and never accepts a caller-supplied workspace override;
- approval callback verifies installation, approval, actor, and token together;
- audit events include installation;
- support tooling is tenant-scoped and audited.

Do not rely on hidden fields or route prefixes as authorization.

---

## 29. Loop prevention

Default behavior:

- ignore `NEW_MESSAGE` and `UPDATED_MESSAGE` events authored by the installation bot;
- use bot token for workflow actions;
- store root execution and lineage depth;
- reject new derived execution above depth three;
- deduplicate repeated event deliveries;
- cap total steps and execution lifetime.

An owner may enable own-bot messages for a trigger only after a warning. The hard lineage limit remains.

Do not depend on undocumented message metadata.

---

## 30. Error taxonomy and retry matrix

Error classes:

- `validation`;
- `authentication`;
- `authorization`;
- `missing_scope`;
- `installation_revoked`;
- `not_found`;
- `rate_limited`;
- `transient_transport`;
- `remote_transient`;
- `remote_permanent`;
- `ambiguous_transport`;
- `side_effect_uncertain`;
- `resource_limit`;
- `cancelled`;
- `internal_invariant`.

Retry is decided by the node runner and action semantics, not by generic exception rescue.

Default backoff:

1. 1 second;
2. 5 seconds;
3. 30 seconds;
4. 2 minutes;
5. 10 minutes.

Honor a valid shorter or longer `Retry-After` within configured bounds.

---

## 31. Resource limits

| Limit | Default |
|---|---:|
| Workflow nodes | 50 |
| Branch depth | 8 |
| Definition size | 256 KiB |
| Active workflows/workspace | 25 |
| Total workflows/workspace | 100 |
| Schedules/workspace | 100 |
| Running executions/workspace | 5 |
| Queued executions/workspace | 1,000 |
| Context size | 256 KiB |
| Template source | 16 KiB |
| Template expansion | 64 KiB |
| Pumble callback body | 1 MiB pending probe |
| Generic webhook body | 512 KiB |
| HTTP request body | 256 KiB |
| HTTP response body | 1 MiB |
| Redirects | 3 |
| Retries | 5 |
| Delay | 365 days |
| Execution lifetime | 30 days |
| Lineage depth | 3 |

Limits are operational safety defaults, not commercial plan limits.

---

## 32. Observability

### Logs

Structured fields:

- correlation ID;
- installation ID;
- workflow ID/version;
- execution ID;
- step ID;
- attempt ID;
- Oban job ID;
- event type;
- error class;
- duration.

Never log:

- OAuth token;
- app secret;
- signing secret;
- workflow secret value;
- Authorization/token headers;
- full message or HTTP body by default.

### Metrics

- callback count/latency/status;
- signature failures;
- dedupe hits;
- execution counts by state;
- step latency by type;
- retries;
- uncertain outcomes;
- Pumble API status/latency;
- external HTTP status/latency;
- queue depth and age;
- schedule lag;
- expired approvals;
- per-workspace limit rejections.

### Health

- `/health/live`: process is alive;
- `/health/ready`: database query, required migration version, Oban supervision and queue checks;
- readiness fails if durable work cannot be accepted.

---

## 33. UI and UX plan

### Information architecture

- Onboarding;
- Workflows;
- Workflow editor;
- Versions;
- Executions;
- Execution detail;
- Connections;
- Secrets;
- Members;
- Audit;
- Settings.

### Outline editor

- trigger card;
- ordered step cards;
- add-before/add-after;
- nested true/false branches;
- nested approval outcomes;
- drag/reorder only within the same sequence;
- stable node IDs;
- node-local validation;
- explicit saved state;
- keyboard alternatives to drag.

### Test mode

Dry-run shows:

- resolved branch;
- rendered messages/HTTP request summaries;
- missing values;
- required scopes;
- side effects that would occur.

Live test requires explicit confirmation.

### Execution timeline

Show:

- trigger;
- each step;
- attempt count;
- sanitized input/output;
- retry;
- branch reason;
- wait deadline;
- approval decision;
- uncertainty;
- final reason.

Do not expose raw secret material.

---

## 34. Testing architecture

### Pure tests

- AST validation;
- compiler;
- path resolution;
- conditions;
- templates;
- schedule calculation;
- state transitions;
- retry classification;
- IP policy.

### Database tests

- tenant isolation;
- activation atomicity;
- immutable version behavior;
- event dedupe;
- execution/step uniqueness;
- approval races;
- cancellation;
- uninstall;
- retention.

### Contract tests

- Pumble callback fixtures;
- signature fixtures;
- fake Pumble API;
- error mapping;
- scope mapping;
- manifest stripping.

### Failure tests

- duplicate callback;
- duplicate Oban job;
- two workers race;
- crash before claim commit;
- crash after claim;
- crash before side effect;
- crash after ambiguous side effect;
- restart during delay;
- restart during approval;
- schedule duplicate dispatch.

### UI tests

- role authorization;
- editor operations;
- validation display;
- activation;
- execution controls;
- secret write-only behavior;
- accessibility basics.

### Live certification

A small explicit suite against a sacrificial Pumble developer workspace. Never run it in normal CI.

---

## 35. Deployment architecture

One containerized Phoenix release and managed PostgreSQL.

Requirements:

- reproducible multi-stage build;
- non-root runtime;
- runtime env validation;
- release migrations;
- HTTPS reverse proxy preserving callback body bytes;
- graceful termination;
- Oban shutdown grace;
- database backups and PITR where available;
- log access;
- readiness/liveness;
- rollback to prior image;
- expand-contract migrations;
- no local persistent token file.

---

## 36. Backup, restore, and rollback

### Backup

- daily full backup or provider equivalent;
- point-in-time recovery when available;
- encrypted backups;
- documented retention;
- backup coverage includes Oban jobs.

### Restore proof

At least quarterly and before first release:

1. restore to isolated database;
2. start exact application release;
3. run migrations if required;
4. verify installations without exposing tokens;
5. verify workflows/versions;
6. verify scheduled jobs and approvals;
7. verify integrity queries;
8. destroy test restore.

### Application rollback

- prior image remains available;
- migrations are backward-compatible for at least one release;
- destructive cleanup occurs only after rollback window;
- rollback smoke test includes callback, DB, and queue acceptance.

### Workflow rollback

Reactivate a prior immutable version through normal activation semantics.

---

## 37. Marketplace and release process

- finalize manifest identity;
- freeze minimal scopes from live evidence;
- configure HTTPS redirect and callback URLs;
- serve public manifest with secrets stripped;
- provide listing, help, privacy, terms, support, and deletion URLs;
- verify welcome/Home onboarding;
- run pre-publish manifest validation;
- install in developer workspace;
- run live certification;
- deploy release candidate;
- run production smoke;
- verify reinstall;
- verify uninstall and deletion schedule;
- document rollback;
- submit or publish only after all release gates pass.

“Code builds” is not release readiness.

---

## 38. Phase dependency graph

```text
P0 Evidence
 -> P1 Contract and decisions
 -> P2 Foundation
 -> P3 Installations and identity
 -> P4 Pumble protocol/client
 -> P5 Workflow and dependency model
 -> P6 Compiler/activation
 -> P7 Execution engine
 -> P8 Ingress/matching
 -> P9 Core nodes/templates
 -> P10 Safe generic HTTP
 -> P11 Delay/schedule/approval
 -> P12 LiveView product UI
 -> P13 Security/tenancy/limits
 -> P14 Observability/maintenance
 -> P15 Adversarial test completion
 -> P16 Deployment
 -> P17 Live certification/Marketplace
 -> P18 Polish/final release
```

Some tasks may overlap only when their dependencies and completion gates permit it.

---

## 39. Detailed ordered implementation tasks

### State-aware entry rule for every task

Before implementing a task:

1. inspect current code and tests;
2. if the capability is proved complete, record evidence and skip;
3. if it exists without proof, verify it first;
4. if it violates an invariant, make the smallest correction;
5. do not rewrite correct code for style preference.

### Phase P0 — Evidence and current-state reconstruction

#### P0-T01 — Inventory repository and preserve evidence

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Determine whether the target repository is empty, partially implemented, or already contains valid capabilities.

##### Why now

Every later task is state-aware. Rebuilding before inventory would violate the smallest-remediation rule.

##### Files/modules

- `repository root`
- `mix.exs`
- `config/**`
- `lib/**`
- `priv/repo/migrations/**`
- `test/**`
- `.github/workflows/**`
- `Dockerfile*`
- `README*`

##### Changes

- Record the file tree, current branch and HEAD, dirty files, ignored generated files, and available environment/toolchain versions.
- Map existing modules to the target contexts in Section 10 without renaming working code for cosmetic reasons.
- Create an evidence note for each apparently implemented capability: source path, tests, last passing command, and gaps.
- Do not modify production code in this task.

##### Invariants

- The original working tree is not mutated.
- Existing implementation is described from evidence, not filenames alone.

##### Failure behavior

- If the repository is inaccessible, mark all implementation state `NOT VERIFIED`; do not claim greenfield.
- If local commands cannot run, record the exact failure and continue with static inventory only.

##### Security considerations

- Do not print `.env`, tokens, secrets, database dumps, or credential-bearing config. Record only variable names.

##### Tests

- No application tests are added; verify that inventory scripts, if any, are read-only.

##### Verification

- `git status --short`
- `git rev-parse HEAD`
- find . -maxdepth 4 -type f | sort
- elixir --version
- `mix --version`

##### Completion gate

- Current-state inventory exists.
- Every later phase can distinguish implement, remediate, verify, or skip.
- No unintended diff exists.

##### Dependencies

None.

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P0-T02 — Establish reproducible baseline

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Run all commands already defined by the repository and capture their exact outcomes before changing code.

##### Why now

A baseline separates pre-existing defects from regressions introduced by implementation.

##### Files/modules

- `mix.exs`
- `Makefile`
- `justfile`
- `README*`
- `.github/workflows/**`
- `assets/package.json if present`

##### Changes

- Discover, do not invent, the repository's format, compile, test, static-analysis, asset, migration, and release commands.
- Run the smallest complete baseline supported by the current repository.
- Record failed tests with file, assertion, and whether failure is deterministic.
- If no project exists, record `NOT APPLICABLE — scaffold required by P2-T01`.

##### Invariants

- Baseline results are immutable evidence; do not fix failures in the same task.
- All commands include exit status.

##### Failure behavior

- A missing external service is `BLOCKED`, not a passing result.
- Flaky failures are repeated once and labelled, not hidden.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Run existing test commands unchanged.
- Run `git diff --check` after the baseline.

##### Verification

- `mix format --check-formatted when available`
- `MIX_ENV=test mix compile --warnings-as-errors when available`
- `mix test when available`
- existing CI-equivalent commands

##### Completion gate

- A dated baseline table exists.
- Every failure has classification and reproduction command.
- Working tree remains unchanged except an explicitly allowed planning ledger.

##### Dependencies

`P0-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P0-T03 — Create source-evidence matrix

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Convert the five supplied Pumble guides and current repository evidence into a traceable protocol matrix.

##### Why now

Pumble-specific behavior must not be invented or lost while translating from the Node SDK to Elixir.

##### Files/modules

- `docs/evidence/pumble_source_matrix.md`
- `the five supplied guide files`
- `existing Pumble fixtures or adapter code`

##### Changes

- List every product-used callback class, event, payload identity field, acknowledgement type, API operation, required header, likely scope, and lifecycle event.
- For each entry record `SUPPORTED`, `INFERRED`, or `PROBE REQUIRED`, with source file and section.
- Separate user-selectable workflow triggers from lifecycle/control events.
- Record contradictions, especially interaction acknowledgement versus modal response examples.

##### Invariants

- Only seven documented subscribed events are treated as proven.
- Undocumented Pumble fields and response semantics remain unknown.
- Source conflicts are retained.

##### Failure behavior

- If a source is ambiguous, create a probe item instead of selecting a convenient interpretation.

##### Security considerations

- Do not copy real tokens, signing secrets, workspace IDs, or private message content into fixtures or documentation.

##### Tests

- Review matrix entries against sanitized guide excerpts.
- Add a simple documentation test or CI grep ensuring required event names remain listed if useful.

##### Verification

- No executable command is required beyond documentation linting.
- A reviewer manually cross-checks all five source files.

##### Completion gate

- The matrix covers every Pumble dependency in the product contract.
- No unsupported event or API is listed as proven.

##### Dependencies

`P0-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P0-T04 — Create protocol probe register

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Define finite live experiments for every Pumble behavior that the supplied corpus does not prove.

##### Why now

Unknown protocol behavior must be resolved before architecture depends on it.

##### Files/modules

- `docs/evidence/pumble_probe_register.md`
- `test/live/pumble/** or equivalent later location`

##### Changes

- Create one probe per unknown with hypothesis, weakest acceptable conclusion, setup, exact request/action, expected observations, cleanup, and blocking downstream task.
- Include callback retry behavior and stable IDs, slash/shortcut/modal response ordering, OAuth redirect/error payloads, reinstall token replacement, exact scope mapping, rate-limit headers, Pumble-generated message metadata, and uninstall delivery.
- Mark probes that require a sacrificial developer workspace and owner interaction.
- Do not run production mutations in this task.

##### Invariants

- Each unknown has one bounded probe.
- A failed or absent observation does not become support.
- Probe cleanup is explicit.

##### Failure behavior

- If the environment lacks credentials, mark the probe `BLOCKED` while keeping downstream assumptions conservative.

##### Security considerations

- Use a sacrificial workspace only; generate unique probe prefixes; never expose personal or customer data.

##### Tests

- Review every `UNKNOWN / REQUIRES PROBE` item from Section 4.3 has a matching probe ID.

##### Verification

- Documentation review
- optional markdown link check

##### Completion gate

- No architecture-critical unknown is untracked.
- Each probe names the earliest phase it can unblock.

##### Dependencies

`P0-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P0-T05 — Create progress ledger and ADR skeleton

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide stable implementation bookkeeping that a weak agent can resume without re-planning.

##### Why now

The plan is intentionally reusable from any implementation state.

##### Files/modules

- `IMPLEMENTATION_LEDGER.md`
- `docs/architecture/decisions/README.md`
- `docs/architecture/decisions/0001-record-template.md`

##### Changes

- Create one row for every task ID in this plan with status, owner/agent, dependencies, evidence, and notes.
- Permit only `NOT STARTED`, `IN PROGRESS`, `BLOCKED`, `COMPLETE`, and `REVERIFY`.
- Define that `COMPLETE` requires the task's gate and exact evidence.
- Create a short ADR template: context, evidence, decision, alternatives, consequences, reversal condition.

##### Invariants

- The canonical plan is not rewritten to track progress.
- Status changes do not erase prior evidence.
- Architecture changes require an ADR.

##### Failure behavior

- If a task was previously claimed complete without evidence, set it to `REVERIFY`.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Validate all IDs in the ledger occur exactly once in the canonical plan.
- Validate dependencies reference existing IDs.

##### Verification

- a small script or grep-based check for duplicate/missing task IDs
- `git diff --check`

##### Completion gate

- Ledger includes every task.
- ADR rules are documented.
- No task is marked complete at creation unless P0 evidence proves it.

##### Dependencies

`P0-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P1 — Product contract and architecture decisions

#### P1-T01 — Freeze product contract and non-goals

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Turn Sections 5 and 6 into an approved release contract with explicit v1 trigger, logic, action, and management surfaces.

##### Why now

Schema and architecture cannot stabilize while the product catalog remains open-ended.

##### Files/modules

- `docs/product/product_contract.md`
- `docs/product/non_goals.md`
- `IMPLEMENTATION_LEDGER.md`

##### Changes

- List exact v1 node types and their configuration fields.
- State that lifecycle events are not user workflow triggers.
- State fixed manifest entry points and alias/picker behavior.
- State explicit exclusions: loops, arbitrary code, arbitrary connectors, visual canvas, microservices, AI generation, native third-party integrations.
- Define what can be deferred without blocking release.

##### Invariants

- A feature absent from the contract cannot silently enter the critical path.
- The generic HTTP node is the only broad external integration primitive in v1.

##### Failure behavior

- Unresolved scope or protocol details are linked to probe IDs rather than guessed.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Documentation review against Section 5 and the source matrix.
- Check each planned AST node maps to a contract item.

##### Verification

- markdown lint/link check if configured

##### Completion gate

- The v1 catalog is finite.
- Each feature has acceptance behavior or is an explicit non-goal.

##### Dependencies

`P0-T03`, `P0-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P1-T02 — Approve manifest trigger model

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Define the static Pumble manifest and how dynamic user workflows route behind it.

##### Why now

Pumble manifest entries are installation configuration, not per-workflow runtime registrations.

##### Files/modules

- `docs/architecture/pumble_manifest.md`
- `priv/pumble/manifest.template.json later`
- `docs/evidence/pumble_source_matrix.md`

##### Changes

- Reserve one slash command, one global shortcut, and one message shortcut with proposed names from Section 5.
- Define unique per-workspace manual aliases, picker visibility, and alias collision behavior.
- List the five selectable Pumble events and two lifecycle events.
- Define callback route classes and minimum scopes as a matrix, leaving unverified scopes linked to probes.
- Record how manifest version and scope changes require reinstall.

##### Invariants

- Manifest callbacks remain fixed across user workflow edits.
- Active aliases are unique within a workspace and trigger type.
- Scope expansion never happens silently.

##### Failure behavior

- If a proposed command name is unavailable, change only through an ADR and manifest migration plan.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Matrix tests later validate active nodes against manifest-supported triggers.
- Manual review against source event catalog.

##### Verification

- documentation review
- future manifest schema validation command recorded

##### Completion gate

- A weak implementer can generate the manifest without inventing entries.
- All unknown scope fields are explicit.

##### Dependencies

`P1-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P1-T03 — Approve workflow representation and execution semantics

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Freeze the structured editable AST, compiled graph, node identity, state machine, and uncertain-outcome policy.

##### Why now

Persistence and workers depend directly on these semantics.

##### Files/modules

- `docs/architecture/workflow_semantics.md`
- `docs/architecture/decisions/0002-workflow-representation.md`
- `docs/architecture/decisions/0003-effect-semantics.md`

##### Changes

- Define one trigger plus an ordered tree of steps; condition and approval nodes own named nested branches.
- Define stable UUID node IDs generated on insertion and retained through reorder/edit.
- Define immutable compiled versions and execution version binding.
- Define execution and step states, including `PAUSED_UNCERTAIN`.
- Define claim-execute-finalize and stale-job no-op behavior.
- Define cancellation, retry, and operator resolution semantics.

##### Invariants

- No cycles, merges, arbitrary jumps, or runtime code.
- Completed external effects are never repeated merely because an Oban job repeats.
- Ambiguous non-idempotent writes do not auto-retry.

##### Failure behavior

- Invalid transitions return typed conflict errors and do not mutate state.
- A worker crash leaves a recoverable durable record.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Model state-transition tables and enumerate invalid transitions.
- Review failure windows before/after persistence and side effects.

##### Verification

- documentation review
- state-machine property tests are planned in P8

##### Completion gate

- Every execution state and transition has one owner and recovery rule.
- No exactly-once claim remains.

##### Dependencies

`P1-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P1-T04 — Approve threat model and data classification

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Classify data and map credible threats to concrete boundaries, mitigations, and proof.

##### Why now

Security controls must shape schemas and transports before implementation.

##### Files/modules

- `docs/security/threat_model.md`
- `docs/security/data_classification.md`
- `docs/architecture/decisions/0004-security-boundaries.md`

##### Changes

- Classify Pumble credentials, user secrets, workflow definitions, callback bodies, execution data, audit data, and logs.
- Map threats from Section 27 to entry points and owner modules.
- Define redaction rules, browser session properties, tenant isolation policy, SSRF policy, payload limits, and admin/debug restrictions.
- Define secrets that must use authenticated encryption and data that may use normal database encryption/storage.
- Assign automated proof or explicit manual review to each mitigation.

##### Invariants

- No raw credential appears in logs, workflow JSON, execution history, metrics, or ordinary errors.
- Tenant ID alone is never authorization.
- Debug routes are absent in production.

##### Failure behavior

- A risk without a viable mitigation is release-blocking and recorded, not waived implicitly.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Threat-model review with one abuse case per boundary.
- Map every high/critical threat to a later test task.

##### Verification

- documentation review
- future Sobelow and secret-scan commands recorded

##### Completion gate

- Threat table has threat → boundary → mitigation → proof.
- No high-severity threat lacks an owner.

##### Dependencies

`P1-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P1-T05 — Freeze dependency and coding policy

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Select the minimal direct dependencies and repository conventions for the implementation snapshot.

##### Why now

Scaffolding and security-sensitive code need deterministic versions and conventions.

##### Files/modules

- `mix.exs later`
- `.tool-versions or mise.toml later`
- `docs/architecture/dependencies.md`
- `docs/engineering/conventions.md`

##### Changes

- Revalidate the dated version table from official sources before pinning.
- Approve Phoenix, LiveView, Ecto SQL, Postgrex, Oban, Req, Mint, tzdata, Credo, Dialyxir, and Sobelow only when needed.
- Decide credential encryption after a compatibility spike: use Cloak Ecto if proven compatible, otherwise a small AES-256-GCM Ecto type using OTP crypto.
- For each direct dependency record problem solved, why standard library is insufficient, maintenance evidence, and removal condition.
- Define context boundaries, naming, error tuples/structs, test placement, no-warning policy, and no-unused-production-code policy.

##### Invariants

- Direct dependencies are exact in `mix.lock`.
- Req is not used to bypass the pinned-IP SSRF transport.
- No package is added for trivial behavior.

##### Failure behavior

- A dependency that fails compatibility or maintenance review is rejected with an ADR.

##### Security considerations

- Review supply-chain ownership, release recency, known advisories, and transitive dependency count.

##### Tests

- Compatibility spike compiles a minimal encrypted field if Cloak is selected.
- Run audit against proposed lockfile after scaffold.

##### Verification

- official version revalidation
- future `mix hex.audit`
- future `MIX_ENV=test mix compile --warnings-as-errors`

##### Completion gate

- Dependency ledger is approved.
- Every proposed dependency has current justification.
- Encryption implementation path is unambiguous.

##### Dependencies

`P1-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P2 — Phoenix, PostgreSQL, Oban, and quality foundation

#### P2-T01 — Scaffold or reconcile Phoenix application

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Create the smallest Phoenix modular monolith foundation or align the existing project to it.

##### Why now

All production modules, migrations, tests, and release configuration depend on a valid application skeleton.

##### Files/modules

- `mix.exs`
- `mix.lock`
- `config/*.exs`
- `lib/pumble_automation/**`
- `lib/pumble_automation_web/**`
- `assets/**`
- `test/**`

##### Changes

- If no app exists, generate Phoenix with Ecto and LiveView using the approved versions; retain only required generated features.
- If an app exists, preserve coherent names and migrate incrementally rather than regenerating.
- Set application namespace, Repo, Endpoint, telemetry, gettext only if user-facing localization is actually retained, and asset pipeline.
- Delete sample pages/routes/code not used by the product.
- Add `.tool-versions` or `mise.toml` with Elixir and OTP.

##### Invariants

- One OTP application owns web and workers.
- Generated demo code does not ship.
- Compilation has no warnings.

##### Failure behavior

- Scaffold failures leave no half-generated mixed tree; revert or complete atomically.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Generated connection/data tests pass.
- Home route returns the intentional onboarding/login shell, not a Phoenix demo.

##### Verification

- `mix deps.get`
- `mix format --check-formatted`
- `MIX_ENV=test mix compile --warnings-as-errors`
- `mix test`

##### Completion gate

- Application boots in test and dev.
- No sample/demo production route remains.
- Toolchain versions are pinned.

##### Dependencies

`P1-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P2-T02 — Implement strict runtime configuration

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Validate all runtime settings at boot and separate compile-time from runtime configuration.

##### Why now

Silent defaults for credentials, URLs, or encryption keys create unsafe deployments.

##### Files/modules

- `config/config.exs`
- `config/dev.exs`
- `config/test.exs`
- `config/runtime.exs`
- `lib/pumble_automation/config.ex`
- `.env.example`

##### Changes

- Define required variables for database, endpoint, host/scheme/port, Pumble app identity, signing/client/app secrets, encryption keys, session signing, and optional telemetry.
- Parse integers, booleans, URLs, trusted proxy settings, queue concurrency, and limits with typed validation.
- Allow deterministic test defaults only in `config/test.exs`.
- Fail boot with a redacted actionable error when production configuration is missing or malformed.
- Document variable names, purpose, sensitivity, and rotation impact.

##### Invariants

- Production never falls back to development secrets.
- Errors do not echo secret values.
- Canonical public URL is explicit.

##### Failure behavior

- Malformed configuration stops startup before accepting traffic or running jobs.

##### Security considerations

- Encryption and signing keys must meet documented byte lengths and arrive through runtime secret injection, not repository files.

##### Tests

- Unit-test configuration parsers.
- Boot a production-config validation command with each required variable intentionally absent.
- Assert errors redact values.

##### Verification

- `MIX_ENV=test mix test test/pumble_automation/config_test.exs`
- `MIX_ENV=prod mix release` after release setup, plus the task's production-configuration failure tests

##### Completion gate

- All required settings are typed and documented.
- Production boot fails closed.
- Test config is isolated.

##### Dependencies

`P2-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P2-T03 — Configure PostgreSQL and migration discipline

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Establish database ownership, migration conventions, constraints, and safe test sandboxing.

##### Why now

PostgreSQL is the durable truth for every later subsystem.

##### Files/modules

- `lib/pumble_automation/repo.ex`
- `config/*.exs`
- `priv/repo/migrations/**`
- `test/support/data_case.ex`
- `docs/operations/migrations.md`

##### Changes

- Configure Ecto Repo pools, timeouts, queue targets, test SQL Sandbox, and production SSL policy.
- Define UUID primary-key convention, UTC timestamp type, JSONB use policy, tenant-key/index convention, check-constraint naming, and foreign-key deletion policy.
- Create only foundational extensions actually needed, such as `pgcrypto` for UUIDs if the chosen Ecto strategy requires it.
- Document expand-contract migration rules and prohibited destructive changes during rollback window.
- Add migration smoke helpers for clean-up and replay.

##### Invariants

- Schema constraints enforce critical invariants in addition to changesets.
- Migrations run from empty database in order.
- No application schema is created ad hoc at runtime.

##### Failure behavior

- A migration failure aborts release migration and prevents the new release becoming ready.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Create/migrate/drop test database from scratch.
- Run all migrations twice where idempotent checks apply.
- Test rollback of the newest reversible migration during development.

##### Verification

- `MIX_ENV=test mix ecto.create`
- `MIX_ENV=test mix ecto.migrate`
- `MIX_ENV=test mix test`
- `mix ecto.migrations`

##### Completion gate

- Fresh database reaches current schema.
- Migration policy is documented.
- Repo tests use SQL Sandbox correctly.

##### Dependencies

`P2-T01`, `P2-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P2-T04 — Install and configure Oban

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Add durable job execution with explicit queues, plugins, uniqueness policy, and test mode.

##### Why now

Execution, delays, schedules, retries, retention, and reconciliation require durable jobs.

##### Files/modules

- `mix.exs`
- `config/*.exs`
- `lib/pumble_automation/application.ex`
- `lib/pumble_automation/oban.ex`
- `priv/repo/migrations/*oban*.exs`
- `test/support/**`

##### Changes

- Add Oban at the approved version and generate its migration.
- Configure queues from Section 9 with conservative concurrency and runtime overrides.
- Enable only required plugins; do not add Cron for user schedules if the database dispatcher owns them.
- Configure `testing: :manual` or approved test mode.
- Define a helper for inserting jobs inside caller-owned `Ecto.Multi` transactions.
- Document shutdown grace and queue pause/drain operations.

##### Invariants

- Business transitions and job insertion can share one database transaction.
- Job payloads contain IDs only, never tokens or private payloads.
- Workers remain idempotent.

##### Failure behavior

- If Oban cannot connect or migrate, readiness is false and workflow work does not run.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Oban migration test.
- Insert and perform a trivial test worker transactionally.
- Assert rollback removes both business row and job.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/oban_test.exs`
- inspect queue insertion and availability through the Oban test API, database assertions, or the documented operational health query

##### Completion gate

- Oban tables exist.
- Transactional insertion is proved.
- Queue names and concurrency are explicit.

##### Dependencies

`P2-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P2-T05 — Add quality gates and continuous integration

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Make formatting, warnings, tests, static analysis, audits, assets, and release build reproducible.

##### Why now

A weak implementer needs one authoritative verification path after every task.

##### Files/modules

- `mix.exs`
- `.formatter.exs`
- `.credo.exs`
- `dialyzer config`
- `sobelow config`
- `.github/workflows/ci.yml`
- `scripts/verify.sh`

##### Changes

- Add Credo, Dialyxir, and Sobelow as development/test tools after compatibility verification.
- Create `scripts/verify.sh` that stops on first failure and runs format, compile warnings-as-errors, tests, Credo, Dialyzer, Sobelow, Hex audit, asset build, and `git diff --check` in a documented order.
- Configure CI with PostgreSQL service, dependency caches keyed by lockfile/toolchain, and no secret-requiring live tests.
- Make generated warnings actionable; do not blanket-ignore rules.
- Add secret-pattern scanning using an available trusted CI action or local tool, with false positives documented.

##### Invariants

- CI and local verification use the same commands.
- No test is silently skipped due to missing secrets.
- Live certification is a separate manual job.

##### Failure behavior

- A failed gate blocks merge/release; exceptions require an ADR and expiry.

##### Security considerations

- CI never prints runtime secrets; dependency and secret scans are release blockers for high/critical findings.

##### Tests

- Intentionally introduce a format error in a temporary branch/script test to verify the gate fails, then remove it.
- Run CI-equivalent locally.

##### Verification

- `./scripts/verify.sh`
- `MIX_ENV=test mix compile --warnings-as-errors`
- `mix credo --strict`
- `mix dialyzer`
- `mix sobelow --config`
- `mix hex.audit`

##### Completion gate

- Clean repository passes the full gate.
- CI artifact records test results.
- No unconditional ignore hides high-severity findings.

##### Dependencies

`P2-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P2-T06 — Create health, readiness, and typed error foundation

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Add operational endpoints and a shared internal error vocabulary without coupling domains to web responses.

##### Why now

Later components need consistent failure classification and deployment health semantics.

##### Files/modules

- `lib/pumble_automation/error.ex`
- `lib/pumble_automation_web/controllers/health_controller.ex`
- `lib/pumble_automation_web/router.ex`
- `lib/pumble_automation_web/telemetry.ex`
- `test/**/health*_test.exs`

##### Changes

- Define a small error struct or tagged-tuple convention with class, code, retryability, safe message, details-for-logs, and cause.
- Add unauthenticated `/health/live` that proves the BEAM/Endpoint is alive without DB.
- Add `/health/ready` that performs a bounded database query and verifies required migrations; include queue/config checks that can be evaluated safely.
- Return minimal machine-readable status and no infrastructure secrets.
- Instrument health latency and failures.

##### Invariants

- Liveness does not depend on optional external APIs.
- Readiness is false when PostgreSQL is unavailable or schema is behind.
- Domain errors do not contain Plug/Phoenix response types.

##### Failure behavior

- Health checks time out quickly and fail closed rather than hanging the platform.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Connection tests for healthy and simulated DB-down responses.
- Error serialization redaction test.
- Readiness migration-version test.

##### Verification

- `mix test test/pumble_automation_web/controllers/health_controller_test.exs`
- `curl against local release after P16`

##### Completion gate

- Endpoints report meaningful distinct states.
- No private data appears.
- Shared error convention is documented and used by foundation code.

##### Dependencies

`P2-T03`, `P2-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P2-T07 — Create append-only audit foundation

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide a minimal tenant-scoped audit table and transactional writer for security-sensitive actions from the first OAuth mutation onward.

##### Why now

Install, role, credential, activation, and lifecycle operations must not wait until late hardening to become accountable.

##### Files/modules

- `lib/pumble_automation/audit/audit_event.ex`
- `writer.ex`
- `priv/repo/migrations/*audit_events*.exs`
- `test/pumble_automation/audit/foundation_test.exs`

##### Changes

- Create audit rows with installation nullable only for pre-install OAuth failures where justified, actor type/ID, action code, resource type/ID, correlation ID, safe metadata, and UTC timestamp.
- Expose a small writer that can append inside a caller-owned `Ecto.Multi` and a separate best-effort event only for explicitly noncritical diagnostics.
- Use an allowlist of metadata keys/types and size limits.
- Disallow update/delete through public application API.
- Reserve action-code namespace; later P13-T06 expands coverage and operations.

##### Invariants

- Security-sensitive mutations and audit append commit together.
- Metadata never contains token, secret, code, raw callback body, or private full payload.
- Audit ownership is tenant-correct.

##### Failure behavior

- Audit insertion failure rolls back the protected mutation.
- Pre-install failure events without installation use only correlation and safe reason.

##### Security considerations

- Do not claim tamper-proof storage; database administrators retain database authority.

##### Tests

- Atomic Multi rollback.
- metadata rejection/redaction.
- cross-tenant actor/resource.
- public update/delete absence.
- size limit.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/audit/foundation_test.exs`

##### Completion gate

- Foundation audit is available before OAuth install.
- Critical callers can append transactionally.
- No sensitive metadata leaks.

##### Dependencies

`P2-T03`, `P2-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P3 — Installations, OAuth, browser identity, and authorization

#### P3-T01 — Create installation and identity schemas

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Persist workspaces, Pumble credentials, local members, OAuth state, and browser sessions with database-enforced ownership.

##### Why now

OAuth callbacks and every tenant-owned feature need a durable installation identity.

##### Files/modules

- `lib/pumble_automation/installations/installation.ex`
- `user_authorization.ex`
- `workspace_member.ex`
- `oauth_state.ex`
- `user_session.ex`
- `priv/repo/migrations/*installations*.exs`

##### Changes

- Create schemas described in Section 14.1 with UUID keys and Pumble IDs as opaque strings.
- Add unique constraints for workspace installation, workspace/member identity, OAuth nonce hash, and session token hash.
- Add status checks and expiry indexes.
- Store scope snapshots as normalized sorted arrays or an explicit structure.
- Use foreign keys and deletion policies matching uninstall retention.

##### Invariants

- Every identity row resolves to exactly one installation.
- OAuth state and session plaintext tokens are never stored.
- Installation workspace ID is immutable.

##### Failure behavior

- Constraint violations return domain conflicts; they do not leak another workspace row.
- Expired states/sessions are treated as absent.

##### Security considerations

- Mark encrypted/token-hash columns as sensitive in inspect implementations and logging filters.

##### Tests

- Changeset tests for required fields and states.
- Unique/race tests for first installation and member.
- Foreign-key and expiry-index migration tests.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/installations/**`

##### Completion gate

- All identity migrations replay from empty DB.
- Database constraints match documented invariants.
- No credential field is plaintext.

##### Dependencies

`P2-T03`, `P1-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P3-T02 — Implement credential encryption and redaction

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide authenticated encryption for Pumble tokens and later user secrets with rotation-aware key identifiers.

##### Why now

Credentials must be safely persisted before OAuth can be implemented.

##### Files/modules

- `lib/pumble_automation/crypto/vault.ex`
- `encrypted_binary.ex`
- `lib/pumble_automation/installations/*.ex`
- `config/runtime.exs`
- `test/pumble_automation/crypto/**`

##### Changes

- Complete the P1 compatibility decision: configure Cloak Ecto or implement a small AES-256-GCM Ecto type.
- Use random nonces, authentication tags, version/key ID, and associated data that binds ciphertext to record type and tenant where practical.
- Support a primary write key and explicit legacy read keys for rotation.
- Return opaque redacted values from `Inspect`; never expose decrypt functions outside the owner context.
- Add a batch rotation service but do not run it automatically during normal requests.

##### Invariants

- Tampering causes decryption failure.
- The same plaintext encrypts differently each time.
- Only owner contexts can resolve plaintext at the moment of use.

##### Failure behavior

- Unknown key ID or failed authentication returns a typed non-retryable security error and prevents external calls.

##### Security considerations

- Keys come only from secret injection; reject weak length; zeroization cannot be guaranteed on BEAM, so minimize plaintext lifetime and copies.

##### Tests

- Round-trip, randomized ciphertext, tamper, wrong associated data, unknown key, and rotation tests.
- Log capture test proves plaintext does not appear.

##### Verification

- `mix test test/pumble_automation/crypto/**`
- `mix sobelow --config`
- secret-pattern scan

##### Completion gate

- Encryption is authenticated and versioned.
- Rotation path is tested.
- No plaintext token is observable in inspect/log/error output.

##### Dependencies

`P3-T01`, `P1-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P3-T03 — Implement OAuth state service

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Create, validate, atomically consume, and expire OAuth state for install, reinstall, and browser sign-in intents.

##### Why now

OAuth CSRF protection must exist before exposing consent redirects.

##### Files/modules

- `lib/pumble_automation/installations/oauth_state.ex`
- `service.ex`
- `lib/pumble_automation_web/controllers/oauth_controller.ex`
- `test/**/oauth_state*_test.exs`

##### Changes

- Generate at least 256 bits of randomness; send a URL-safe token and persist only a keyed or cryptographic hash.
- Store intent, requested workspace hint, return path allowlist key, expiry, and optional initiating session/member.
- Consume state with one atomic update that requires unconsumed and unexpired status.
- Allow only internal named return destinations; never accept an arbitrary post-OAuth redirect URL.
- Add periodic expiry cleanup.

##### Invariants

- A state token succeeds once.
- Intent cannot be changed by the callback.
- Return path cannot leave the application origin.

##### Failure behavior

- Missing, expired, reused, or mismatched state fails closed with a safe retry path and audit event.

##### Security considerations

- Use constant-time comparison for token hashes where comparison occurs in application code; rate-limit state creation and callback failures.

##### Tests

- Single-use and concurrent-consume race tests.
- Expiry and intent-mismatch tests.
- Open-redirect tests.

##### Verification

- `mix test test/pumble_automation/installations/oauth_state_test.exs`
- `mix test test/pumble_automation_web/controllers/oauth_controller_test.exs`

##### Completion gate

- Concurrent callbacks produce exactly one successful state consumption.
- Invalid state never exchanges a code.

##### Dependencies

`P3-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P3-T04 — Implement install and sign-in OAuth flow

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Exchange valid Pumble authorization codes, persist installation/user authorization atomically, and establish a browser session.

##### Why now

The application needs a verified workspace and user identity before tenant UI or API actions can operate.

##### Files/modules

- `lib/pumble_automation/installations/service.ex`
- `policy.ex`
- `lib/pumble_automation/pumble/oauth_client.ex`
- `lib/pumble_automation_web/controllers/oauth_controller.ex`
- `router.ex`
- `test/support/pumble_fake.ex`

##### Changes

- Build authorization URLs from configured app ID, exact redirect URI, required scopes, workspace hint, reinstall flag, and state.
- Exchange the code using the documented multipart endpoint through a dedicated client with bounded timeout.
- Obtain/validate the authorized Pumble profile if required to bind workspace/user identity.
- Inside one transaction upsert installation, bot/user credentials, scope snapshot, member, first-owner assignment, session, and audit record.
- Distinguish install, reinstall, and sign-in intents; a sign-in must not silently grant owner role.
- Redirect only to named local destinations.

##### Invariants

- Workspace identity comes from Pumble response/profile, not a browser parameter.
- First owner is assigned only when no owner exists.
- Token replacement is atomic.

##### Failure behavior

- Network/4xx/5xx exchange failures create no partial installation.
- Identity mismatch or missing bot token when required fails without session creation.

##### Security considerations

- Filter authorization codes and token responses from logs; use TLS verification; cap response body; do not retry code exchange after an ambiguous success without a new user flow.

##### Tests

- Fake-server tests for success, malformed response, timeout, duplicate callback, concurrent first installers, reinstall, and cross-workspace mismatch.
- Transaction rollback test.

##### Verification

- `mix test test/pumble_automation/installations/service_test.exs`
- `mix test test/pumble_automation_web/controllers/oauth_controller_test.exs`

##### Completion gate

- Install creates one durable tenant and session.
- Reinstall preserves tenant data and replaces credentials atomically.
- No partial rows remain after failure.

##### Dependencies

`P3-T03`, `P2-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P3-T05 — Implement revoke, unauthorized, and uninstall lifecycle

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Make credential revocation and app uninstall safe, durable, and observable.

##### Why now

A multi-workspace automation service must stop effects promptly when authorization ends.

##### Files/modules

- `lib/pumble_automation/installations/service.ex`
- `lib/pumble_automation/executions/** later integration points`
- `lib/pumble_automation/executions/workers/retention_worker.ex`
- `test/**/lifecycle*_test.exs`

##### Changes

- Implement user-authorization revocation and installation unauthorized/uninstalled transitions.
- On unauthorized, delete affected encrypted tokens, revoke dependent sessions, and mark dependent active workflows degraded/disabled according to known scopes.
- On uninstall, atomically mark uninstalled, delete all Pumble/user secrets, disable trigger bindings and schedules, revoke sessions, and insert cleanup work.
- Running workers must re-read installation status before each new external side effect.
- Retain non-secret workflow/history data for 30 days, then purge by tenant in resumable batches.
- Audit lifecycle transitions without credential values.

##### Invariants

- No new execution or external effect starts for an uninstalled installation.
- Credential deletion is immediate.
- Retention purge is deterministic and tenant-scoped.

##### Failure behavior

- Cleanup job failure leaves the installation blocked and retryable; it never re-enables work.
- Duplicate lifecycle events are idempotent.

##### Security considerations

- Treat uninstall callbacks as signed Pumble events; never provide a public tenant-deletion endpoint keyed only by workspace ID.

##### Tests

- Duplicate unauthorized/uninstall tests.
- Race uninstall against execution start and approval.
- Retention purge test with cross-tenant sentinel rows.
- Session revocation test.

##### Verification

- `mix test test/pumble_automation/installations/lifecycle_test.exs`
- `mix test test/pumble_automation/executions/uninstall_race_test.exs after P8`

##### Completion gate

- Uninstall blocks work before acknowledgement returns.
- All credential ciphertext is removed.
- Duplicate events do not corrupt data.
- Purge cannot touch another tenant.

##### Dependencies

`P3-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P3-T06 — Implement browser sessions and membership roles

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Authenticate browser users and authorize every web/LiveView operation with local owner, editor, and viewer roles.

##### Why now

The Pumble corpus does not define browser application authorization; the product must not leave it implicit.

##### Files/modules

- `lib/pumble_automation/installations/user_session.ex`
- `workspace_member.ex`
- `policy.ex`
- `lib/pumble_automation_web/plugs/fetch_session.ex`
- `require_member.ex`
- `load_scope.ex`
- `lib/pumble_automation_web/live/**`

##### Changes

- Issue a random opaque session token; persist only its hash, member, installation, expiry, last-used timestamp, and revocation state.
- Set Secure, HttpOnly, SameSite=Lax cookie with explicit max age and rotate session after OAuth.
- Load an immutable tenant scope struct once per HTTP/LiveView session.
- Define capabilities: viewer reads; editor manages workflows and tests under limits; owner manages members, credentials, destructive lifecycle, and uncertainty resolution.
- Require reauthentication or a recent session for high-risk actions if adopted in the threat model.
- Add sign-out and revoke-all-sessions operations.

##### Invariants

- Every browser query and mutation carries a verified scope.
- Role comes from local membership, not unverified Pumble role strings.
- Session token is never in URL or localStorage.

##### Failure behavior

- Expired/revoked sessions redirect to sign-in and terminate LiveView sockets.
- Authorization denial is not distinguishable as another tenant's resource existence.

##### Security considerations

- Apply Phoenix CSRF protection to browser mutations and LiveView; rate-limit sign-in initiation and session failures.

##### Tests

- Cookie attribute tests.
- Role matrix tests for controllers and LiveViews.
- Session fixation, expiry, revocation, LiveView reconnect, and cross-workspace URL tests.

##### Verification

- `mix test test/pumble_automation_web/plugs/**`
- `mix test test/pumble_automation/installations/policy_test.exs`
- `mix test test/pumble_automation_web/live/**`

##### Completion gate

- All protected routes have policy coverage.
- No ID-only route bypass exists.
- Revocation terminates new and reconnected access.

##### Dependencies

`P3-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P3-T07 — Add installation and identity contract suite

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove the complete identity lifecycle independently of workflow features.

##### Why now

Auth defects contaminate every later tenant and UI test.

##### Files/modules

- `test/pumble_automation/installations/**`
- `test/pumble_automation_web/controllers/oauth_controller_test.exs`
- `test/support/pumble_fake.ex`
- `priv/pumble/fixtures/oauth/**`

##### Changes

- Create sanitized OAuth/profile fixtures.
- Test first install, second user sign-in, reinstall with added/removed scopes, user unauthorized, full uninstall, duplicate events, expired/reused state, and session revocation.
- Test database rollback on every network and persistence failure point.
- Test redaction in logs and exception inspection.
- Document which cases remain live probes.

##### Invariants

- Tests do not require internet.
- Fixtures contain no real IDs/tokens.
- Each lifecycle transition has one durable final state.

##### Failure behavior

- A non-proven Pumble response shape remains a fixture hypothesis and links to its live probe.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- All tests in this suite.
- Property/race tests for OAuth state and first-owner assignment where practical.

##### Verification

- `mix test test/pumble_automation/installations test/pumble_automation_web/controllers/oauth_controller_test.exs --trace`

##### Completion gate

- Identity suite passes repeatedly.
- No leaked fixture secret is detected.
- Live-only assumptions are tagged and documented.

##### Dependencies

`P3-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P4 — Pumble protocol and API boundary

#### P4-T01 — Capture bounded raw callback bodies

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Preserve exact request bytes for signature verification while enforcing callback size and read time limits.

##### Why now

HMAC validation is invalid if JSON is parsed or reserialized first.

##### Files/modules

- `lib/pumble_automation_web/endpoint.ex`
- `lib/pumble_automation_web/plugs/cache_raw_body.ex`
- `config/config.exs`
- `test/**/cache_raw_body_test.exs`

##### Changes

- Implement a Plug body reader or route-specific plug that accumulates exact bytes once and passes them to Plug.Parsers.
- Set a conservative callback body limit from Section 31 and a bounded read timeout.
- Store bytes in a private connection field, not params.
- Reject oversized, truncated, or unreadable bodies before JSON parsing.
- Ensure reverse-proxy documentation forbids transformations.

##### Invariants

- The byte sequence used for HMAC exactly matches the received entity body.
- Body is read only once.
- Oversized requests never allocate without bound.

##### Failure behavior

- Return 413 for size violation and 400 for malformed/truncated reads; do not dispatch.

##### Security considerations

- Do not log the raw callback body by default; callback content may include private messages.

##### Tests

- Binary/non-UTF8 body preservation test.
- Chunked read test.
- limit boundary test.
- prove JSON whitespace changes produce different raw HMAC inputs.

##### Verification

- `mix test test/pumble_automation_web/plugs/cache_raw_body_test.exs`

##### Completion gate

- Exact bytes are available to the signature plug.
- Limits are enforced before decode.
- Normal Phoenix forms/JSON routes still work.

##### Dependencies

`P2-T01`, `P2-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P4-T02 — Verify Pumble callback signatures

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Authenticate Pumble HTTP callbacks using the documented HMAC-SHA256 raw-body scheme.

##### Why now

No callback may reach lifecycle, workflow, or approval code without authenticity verification.

##### Files/modules

- `lib/pumble_automation/pumble/signature.ex`
- `lib/pumble_automation_web/plugs/verify_pumble_signature.ex`
- `router.ex`
- `priv/pumble/fixtures/signatures/**`

##### Changes

- Read the configured signing secret and accepted header name from the evidence matrix.
- Decode the supplied signature only in documented format; compute HMAC-SHA256 over cached raw bytes.
- Compare fixed-length binaries in constant time and reject missing, malformed, or wrong-length signatures.
- Do not permit the Node SDK's no-secret development bypass outside explicit test/dev configuration.
- Attach a verified marker to the connection for downstream assertions.

##### Invariants

- Production callback routes always require a valid signature.
- Comparison timing is independent of matching prefix.
- Parsing happens after verification.

##### Failure behavior

- Return generic 401 and stop the pipeline; do not reveal expected signature or secret state.

##### Security considerations

- Filter signature headers; rotate signing secret through deployment configuration and documented overlap procedure only if Pumble supports overlap.

##### Tests

- Known valid/invalid fixture tests.
- missing/malformed/length tests.
- raw whitespace mutation test.
- production boot/test asserts bypass disabled.

##### Verification

- `mix test test/pumble_automation/pumble/signature_test.exs test/pumble_automation_web/plugs/verify_pumble_signature_test.exs`

##### Completion gate

- Every Pumble callback route is behind the plug.
- All invalid cases return 401 with no persistence.
- Valid fixture passes.

##### Dependencies

`P4-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P4-T03 — Classify and decode Pumble payloads

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Convert verified callback JSON into a finite typed union for events and interactive request classes.

##### Why now

Controllers must not dispatch on arbitrary maps or mix interaction contracts.

##### Files/modules

- `lib/pumble_automation/pumble/payload.ex`
- `classifier.ex`
- `lib/pumble_automation_web/controllers/pumble_callback_controller.ex`
- `priv/pumble/fixtures/callbacks/**`

##### Changes

- Define structs/embedded schemas for the seven event wrappers, slash command, global/message shortcuts, block interactions, view actions, and dynamic menu only if the product uses it.
- Decode event `body` exactly as documented when it arrives as a JSON string.
- Validate required envelope fields and preserve unknown fields only in a bounded raw map for diagnostics.
- Return a typed classification result and protocol response class.
- Reject unsupported message types explicitly.

##### Invariants

- Only known callback classes reach domain services.
- Wire abbreviations stay inside the Pumble boundary.
- Malformed nested event bodies do not crash controllers.

##### Failure behavior

- Malformed payload returns 400 after signature validation; unsupported valid type returns a stable non-retryable response documented by probe evidence.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- One fixture per callback class.
- Missing/wrong-type/fuzzed field tests.
- event-body string decode test.
- unknown message type test.

##### Verification

- `mix test test/pumble_automation/pumble/payload_test.exs test/pumble_automation/pumble/classifier_test.exs`

##### Completion gate

- Finite classifier covers every product-used callback.
- No Map.get chains leak into workflow code.
- Malformed input is bounded and safe.

##### Dependencies

`P4-T02`, `P0-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P4-T04 — Normalize Pumble events and identities

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Translate supported wire payloads into stable internal events and interaction commands.

##### Why now

Workflow matching must not depend on abbreviated provider-specific fields.

##### Files/modules

- `lib/pumble_automation/pumble/normalizer.ex`
- `lib/pumble_automation/ingress/normalized_event.ex or value struct`
- `test/**/normalizer_test.exs`

##### Changes

- Define normalized fields: provider, installation/workspace, class, type, actor, resource/channel/message IDs, occurrence time, provider request ID, correlation ID, and bounded data.
- Map all five selectable events and two lifecycle events.
- Normalize slash/shortcut/approval interactions separately; do not pretend they are normal events.
- Parse timestamps with explicit failure fallback and preserve provider time when valid.
- Tag bot/self origin only from proven fields or API lookups.

##### Invariants

- Normalized events contain no decrypted credentials.
- Tenant comes from verified payload and installation lookup.
- Provider wire keys do not leak past the adapter.

##### Failure behavior

- Unmappable required identity is a permanent ingestion error; do not create an unscoped event.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Golden fixture tests for every event.
- Timestamp and missing optional field tests.
- assert normalized map size limits.

##### Verification

- `mix test test/pumble_automation/pumble/normalizer_test.exs`

##### Completion gate

- All supported events normalize deterministically.
- Lifecycle events map to lifecycle commands.
- Unknowns remain represented as probe-dependent behavior.

##### Dependencies

`P4-T03`, `P3-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P4-T05 — Implement protocol-correct response dispatch

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Return the correct synchronous response for each callback class and keep expensive work outside controllers.

##### Why now

Pumble interactions have a three-second deadline and different ack/response capabilities.

##### Files/modules

- `lib/pumble_automation_web/controllers/pumble_callback_controller.ex`
- `lib/pumble_automation/pumble/response.ex`
- `lib/pumble_automation/ingress/service.ex later`
- `test/**/pumble_callback_controller_test.exs`

##### Changes

- Create a dispatch table for event, slash, shortcut, block, view, and any retained dynamic-menu callbacks.
- Events: perform only verify/decode/dedup-persist/enqueue and return the documented acknowledgement.
- Approval interaction: complete a bounded DB transaction and enqueue resume before ack.
- Manual picker/modal response behavior remains behind its probe until proven; implement the weakest protocol-safe flow, such as immediate ack plus asynchronous ephemeral status, when modal ordering is uncertain.
- Measure end-to-end controller latency and set an internal warning threshold below three seconds.
- Never call Pumble/external APIs synchronously before required acknowledgement except a protocol-required immediate response.

##### Invariants

- Each request sends one terminal HTTP response.
- No long workflow step runs in a controller.
- Accepted interactive intent is durable before a success ack where feasible.

##### Failure behavior

- DB failure produces protocol-safe nack/error; timeout is surfaced and not falsely acknowledged as durable.

##### Security considerations

- Do not include internal errors or private callback content in nack messages; rate-limit invalid signed payloads separately from valid Pumble traffic.

##### Tests

- Response table tests.
- Header-sent/double-response regression test.
- DB-slow timeout test.
- latency test under local load.
- dynamic-menu response test only if retained.

##### Verification

- `mix test test/pumble_automation_web/controllers/pumble_callback_controller_test.exs`
- a benchmark/integration check proving p99 local handler latency below the internal budget

##### Completion gate

- All callback classes have explicit response behavior.
- No controller starts an arbitrary workflow step inline.
- Three-second gate is covered by test and live probe.

##### Dependencies

`P4-T04`, `P2-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P4-T06 — Build Pumble API transport and error classifier

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Create one workspace-scoped client boundary with required headers, timeouts, bounded responses, and typed errors.

##### Why now

OAuth and workflow actions need a reliable adapter; the supplied SDK does not retry automatically.

##### Files/modules

- `lib/pumble_automation/pumble/client.ex`
- `client/transport.ex`
- `client/error.ex`
- `scopes.ex`
- `test/support/pumble_fake.ex`

##### Changes

- Use Req for ordinary Pumble HTTPS calls with TLS verification, explicit connect/read timeouts, response-size cap, and redirects disabled unless an endpoint explicitly proves them.
- Resolve bot or user credentials through the Installations context; inject `token` and `x-app-token` headers.
- Classify transport failures and HTTP 400/401/403/404/409/429/5xx, preserving retry-after metadata when present.
- Redact request headers and configured sensitive body keys.
- Do not retry in the transport; return classification to the caller.
- Attach workspace, operation, correlation, and sanitized provider request ID to telemetry.

##### Invariants

- A client instance cannot be used for a different installation.
- 401/403 are not treated as transient writes.
- Response body is bounded before decode.

##### Failure behavior

- Missing/revoked credentials fail before network.
- Malformed responses become typed provider errors.
- 429 carries a bounded retry hint.

##### Security considerations

- Never allow caller-provided base URLs in production except an explicit test environment; pin official host configuration and verify certificates.

##### Tests

- Fake server tests for headers, timeout, oversize, invalid JSON, each status class, retry-after parsing, and redaction.
- Cross-workspace credential-selection test.

##### Verification

- `mix test test/pumble_automation/pumble/client_test.exs`
- `mix test test/pumble_automation/pumble/client/error_test.exs`

##### Completion gate

- All Pumble calls pass through this boundary.
- No raw Req error escapes domain code.
- No automatic retry exists below node policy.

##### Dependencies

`P3-T02`, `P2-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P4-T07 — Implement product-required Pumble operations and scope map

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Expose only the Pumble methods needed by v1 nodes, onboarding, approvals, and lifecycle.

##### Why now

A narrow adapter avoids cloning the entire Node SDK and makes scope/retry behavior reviewable.

##### Files/modules

- `lib/pumble_automation/pumble/client.ex`
- `blocks.ex`
- `manifest.ex`
- `scopes.ex`
- `test/pumble_automation/pumble/operations_test.exs`

##### Changes

- Implement bot/user profile/workspace lookup required by OAuth identity.
- Implement post channel message, reply, direct-channel lookup/create plus send, add/remove reaction, publish Home view, and any approval-message update proven necessary.
- Implement uninstall/revoke calls only if the product exposes them.
- Build message/block payload constructors with provider limits and escaped user content.
- Map each operation to required bot/user scope from evidence; unverified scope entries remain probe IDs.
- Define per-operation retry safety and idempotency capability.

##### Invariants

- Workflow nodes cannot issue arbitrary Pumble paths.
- Payloads are validated before network.
- Minimal scopes are derived from active node catalog.

##### Failure behavior

- Missing known scope returns a local permanent error before network when the installation snapshot proves absence.
- Unknown scope mapping does not masquerade as known.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Golden request/response tests for each operation.
- DM existing/missing direct channel path.
- message/reaction limit tests.
- 403 scope mapping tests.

##### Verification

- `mix test test/pumble_automation/pumble/operations_test.exs`
- live probes in P17 for every retained method

##### Completion gate

- Each v1 Pumble action has one adapter operation, one scope mapping, one error policy, and offline contract tests.
- Unused SDK methods are absent.

##### Dependencies

`P4-T06`, `P0-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P5 — Durable workflow, secrets, and connection model

#### P5-T01 — Create workflow and draft persistence

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Persist tenant-scoped workflow identity, mutable draft metadata, status, and ownership.

##### Why now

The editor and compiler need a stable aggregate before versions or executions exist.

##### Files/modules

- `lib/pumble_automation/workflows/workflow.ex`
- `definition.ex`
- `priv/repo/migrations/*workflows*.exs`
- `test/pumble_automation/workflows/workflow_test.exs`

##### Changes

- Create `workflows` with installation ID, name, description, draft definition JSONB, draft revision, active version ID nullable, status, manual alias settings, creator/updater, and timestamps.
- Use optimistic locking or revision compare-and-swap for draft saves.
- Add tenant/name and tenant/manual-alias indexes/constraints as approved.
- Validate name/description and maximum serialized definition size.
- Keep activation fields separate from mutable draft.

##### Invariants

- Editing a draft never mutates an active version.
- Every workflow row has one installation.
- Lost updates are detected.

##### Failure behavior

- Revision conflict returns a typed conflict with current revision; no silent overwrite.
- Malformed draft is rejected before persistence.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Changeset, unique alias, optimistic lock, tenant isolation, size-limit, and active-version independence tests.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/workflows/workflow_test.exs`

##### Completion gate

- Draft CRUD is durable and conflict-safe.
- Database constraints enforce tenant uniqueness.
- No execution schema is coupled to draft JSON.

##### Dependencies

`P3-T01`, `P2-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P5-T02 — Implement typed editable AST

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Represent every v1 trigger, sequence, condition branch, approval branch, and action as validated Elixir embedded data.

##### Why now

The weak implementer and UI must not manipulate arbitrary untyped JSON maps.

##### Files/modules

- `lib/pumble_automation/workflows/definition.ex`
- `node.ex`
- `nodes/*.ex if justified`
- `test/pumble_automation/workflows/definition_test.exs`

##### Changes

- Define one root trigger and ordered `steps`.
- Define finite node type discriminators and per-type configuration structures.
- Condition owns `when_true` and `when_false`; approval owns approve/reject/timeout branches; all branches are ordered sequences.
- Generate stable UUID node IDs on insertion; reject duplicate/missing IDs on load.
- Provide explicit encode/decode version for future migrations.
- Do not create a behaviour per node until the execution boundary requires substitution.

##### Invariants

- No cycles or cross-node references exist in the editable representation.
- Node configuration is finite and typed.
- Unknown schema versions fail safely.

##### Failure behavior

- Decode errors produce structured validation issues with JSON paths; they never atomize user strings.

##### Security considerations

- Use existing atoms only for discriminators; bound string/list/map sizes during decode to prevent memory abuse.

##### Tests

- Round-trip every node type.
- unknown type/version tests.
- duplicate ID test.
- nested branch depth tests.
- fuzz malformed JSON without atom growth.

##### Verification

- `mix test test/pumble_automation/workflows/definition_test.exs`

##### Completion gate

- All contract node types round-trip.
- Arbitrary maps cannot enter compiler APIs.
- No dynamic atom creation exists.

##### Dependencies

`P5-T01`, `P1-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P5-T03 — Implement AST editing primitives and limits

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide deterministic insert, remove, move, replace, and branch operations used by LiveView and tests.

##### Why now

Centralized mutations preserve node IDs and structural invariants better than UI-side JSON surgery.

##### Files/modules

- `lib/pumble_automation/workflows/editor.ex`
- `limits.ex`
- `test/pumble_automation/workflows/editor_test.exs`

##### Changes

- Address nodes by stable ID and branch path.
- Implement add before/after, append to branch, update config, reorder within same sequence, move across sequences if explicitly supported, and delete subtree.
- Return a new definition plus changed revision metadata; no in-place state.
- Enforce 50-node and depth-8 defaults, definition-size limits, and unique IDs on every mutation.
- Define deletion confirmation metadata when a node owns non-empty branches.

##### Invariants

- Mutation is deterministic.
- Unaffected node IDs and order remain unchanged.
- Limits cannot be bypassed by one operation.

##### Failure behavior

- Unknown node/path and stale revision return typed errors; partial mutation is never persisted.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Table-driven edit tests, property test preserving unique IDs, boundary-limit tests, nested branch deletion tests.

##### Verification

- `mix test test/pumble_automation/workflows/editor_test.exs`

##### Completion gate

- Every UI edit maps to one tested function.
- All structural limits are enforced outside LiveView.
- Operations preserve serializable AST.

##### Dependencies

`P5-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P5-T04 — Create immutable workflow versions

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Persist canonical compiled source and content hash so executions can bind to an unchangeable program.

##### Why now

Durable execution correctness requires version immutability.

##### Files/modules

- `lib/pumble_automation/workflows/workflow_version.ex`
- `priv/repo/migrations/*workflow_versions*.exs`
- `test/pumble_automation/workflows/workflow_version_test.exs`

##### Changes

- Create version rows with workflow/installation, monotonic version number, source definition, compiled representation, compiler version, content hash, required scopes, activation metadata, and creator.
- Add unique workflow/version and workflow/content-hash constraints.
- Prevent update/delete through context API after creation; database permissions/triggers are optional only if operationally justified.
- Canonicalize JSON/term representation before hashing.
- Reference active version from workflow with a foreign key.

##### Invariants

- A version's executable content never changes.
- Version tenant matches parent workflow.
- Same canonical content produces the same hash.

##### Failure behavior

- Attempted mutation returns an explicit immutable error.
- Hash mismatch on read is a high-severity integrity failure.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Immutability context tests.
- canonical hash tests with key-order variation.
- concurrent version-number allocation test.
- cross-tenant FK test.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/workflows/workflow_version_test.exs`

##### Completion gate

- Version rows are append-only through application APIs.
- Concurrent activation cannot duplicate version numbers.
- Integrity is testable.

##### Dependencies

`P5-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P5-T05 — Create trigger bindings and schedules schema

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Materialize indexed trigger lookup and durable schedule definitions outside workflow JSON.

##### Why now

Ingress must not scan every workflow or parse every active definition.

##### Files/modules

- `lib/pumble_automation/workflows/trigger_binding.ex`
- `schedule.ex`
- `priv/repo/migrations/*trigger_bindings*.exs`
- `*schedules*.exs`

##### Changes

- Create active-version trigger bindings with installation, trigger class/type, selective channel/user/alias fields, filter summary, version ID, enabled status, and timestamps.
- Create schedules with version/workflow/installation, schedule type/config, timezone, next_run_at, enabled, lock/version fields, and last dispatch metadata.
- Add composite indexes matching event lookup and due-schedule queries.
- Add uniqueness for manual aliases and one materialized binding per active trigger.
- Keep full validated trigger config in the version; binding is a query projection.

##### Invariants

- A binding always points to an immutable active version.
- Schedules are tenant-scoped and use UTC `next_run_at`.
- Disabled bindings never match.

##### Failure behavior

- Orphan/inconsistent bindings are prevented by FKs and activation transaction.
- Invalid timezone/schedule config cannot persist.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Index-plan test/EXPLAIN fixture for lookup.
- unique alias race.
- due schedule query.
- deactivation cascade/disable test.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/workflows/trigger_binding_test.exs test/pumble_automation/workflows/schedule_test.exs`

##### Completion gate

- Lookup tables support indexed access.
- Constraints match activation semantics.
- No workflow scan is required.

##### Dependencies

`P5-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P5-T06 — Implement tenant-scoped workflow context and audit

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Expose the only supported query/mutation API for workflow drafts, versions, bindings, and schedules.

##### Why now

Controllers and LiveViews must not perform raw Repo operations or bypass tenant policy.

##### Files/modules

- `lib/pumble_automation/workflows.ex or workflows/service.ex`
- `lib/pumble_automation/scope.ex`
- `lib/pumble_automation/audit/writer.ex later stub`
- `test/pumble_automation/workflows/context_test.exs`

##### Changes

- Require a verified scope struct for every public function.
- Implement list/get/create/update/delete-draft/deactivate and version-history queries without activation logic yet.
- Use tenant in every predicate and return not-found for cross-tenant IDs.
- Append workflow create/update/delete/deactivate audit rows through the P2 audit writer, in the same transaction as security-sensitive mutations.
- Preload only required associations and prevent N+1 lists.

##### Invariants

- No public unscoped `get(id)` exists.
- Cross-tenant access reveals no resource metadata.
- Mutations record actor and revision.

##### Failure behavior

- Audit insertion failure follows the approved atomicity policy: security-sensitive mutations roll back; low-risk read audit is not required.

##### Security considerations

- Use opaque UUIDs but rely on authorization, not obscurity; filter draft data in logs.

##### Tests

- Cross-workspace sentinel tests for every function.
- optimistic conflict tests.
- query-count test for list page.
- role-policy integration tests after P3-T06.

##### Verification

- `mix test test/pumble_automation/workflows/context_test.exs`

##### Completion gate

- All workflow access flows through tenant-scoped API.
- No web module imports Repo for workflow data.
- CRUD behavior is transactionally audited and no raw Repo access is required by web modules.

##### Dependencies

`P5-T05`, `P3-T06`, `P2-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P5-T07 — Create encrypted secrets context

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Store named tenant secrets as write-only encrypted values referenced by UUID.

##### Why now

HTTP actions must not embed credentials in workflow definitions.

##### Files/modules

- `lib/pumble_automation/connections/secret.ex`
- `resolver.ex`
- `priv/repo/migrations/*secrets*.exs`
- `test/pumble_automation/connections/secret_test.exs`

##### Changes

- Create secrets with installation, name, encrypted value, kind, key version, last rotated/used, creator, and soft/deleted state as needed.
- Public API returns metadata only and supports create, replace/rotate, list metadata, and delete when unreferenced or with explicit dependency handling.
- Resolve plaintext only inside an authorized action process immediately before building outbound headers/body.
- Track references from compiled dependencies or query active versions before delete.
- Audit create/rotate/delete/use metadata without value.

##### Invariants

- Workflow JSON contains only secret IDs/placeholders.
- No read-back endpoint exists.
- Cross-tenant secret IDs behave as not found.

##### Failure behavior

- Decrypt failure blocks action permanently/security class.
- Delete of referenced secret is rejected or degrades affected workflows explicitly.

##### Security considerations

- Require owner/editor capability per contract; consider owner-only for deletion; mask names only if names themselves may reveal sensitive context.

##### Tests

- Write-only API.
- rotation.
- tamper.
- cross-tenant.
- referenced delete.
- inspect/log redaction.
- uninstall purge.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/connections/secret_test.exs`

##### Completion gate

- Secrets are never returned after creation.
- References and deletion are safe.
- All values use P3 encryption boundary.

##### Dependencies

`P3-T02`, `P5-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P5-T08 — Create HTTP connections context

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Persist reusable, tenant-scoped outbound HTTP configuration without hiding arbitrary execution logic.

##### Why now

Connections centralize base URL, authentication references, and policy while keeping node definitions readable.

##### Files/modules

- `lib/pumble_automation/connections/connection.ex`
- `resolver.ex`
- `priv/repo/migrations/*connections*.exs`
- `test/pumble_automation/connections/connection_test.exs`

##### Changes

- Define one `http` connection type with name, optional HTTPS base origin/path prefix, fixed literal headers, secret-backed header/auth references, enabled status, and policy version.
- Do not store arbitrary scripts, retry code, or templated secrets in the connection.
- Validate header names and block hop-by-hop/auth override rules.
- Resolve a connection with secret handles, not plaintext, for validation; plaintext only at execution.
- Implement tenant-scoped CRUD, dependency-aware delete, test-connection as explicit side-effectful operation with safe target policy.

##### Invariants

- Connection cannot cross tenant.
- Base URL must pass URL policy.
- Workflow node may narrow path but cannot escape approved origin/prefix when using a connection.

##### Failure behavior

- Invalid/disabled/missing connection blocks activation or action with a permanent error.
- Test-connection failure does not mutate workflow.

##### Security considerations

- Block user-supplied `Host`, `Content-Length`, `Transfer-Encoding`, proxy, connection, and authorization headers except through approved auth fields.

##### Tests

- CRUD/role/cross-tenant.
- origin/path escape.
- header validation.
- secret reference.
- dependency delete.
- test-connection redaction.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/connections/connection_test.exs`

##### Completion gate

- Connection behavior is finite and documented.
- No plaintext secret appears in schemas/returns.
- URL restrictions are enforced centrally.

##### Dependencies

`P5-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P6 — Validation, compilation, activation, and versions

#### P6-T01 — Implement structural workflow validator

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Reject malformed or non-executable workflow structure before activation.

##### Why now

Later semantic checks and compilation require a structurally sound AST.

##### Files/modules

- `lib/pumble_automation/workflows/validator.ex`
- `validation_issue.ex`
- `test/pumble_automation/workflows/validator_structure_test.exs`

##### Changes

- Traverse the typed AST and return all deterministic issues with code, severity, node ID, field path, and safe message.
- Validate one supported trigger, supported node types, non-empty required branches, unique IDs, node/depth/serialized-size limits, required config fields, finite lists, and absence of unsupported schema versions.
- Detect unreachable structure only where the structured AST permits it, such as nodes after an unconditional stop in the same sequence.
- Keep validation pure: no Repo, network, or token access.
- Sort issues deterministically for stable UI/tests.

##### Invariants

- Validation never mutates the draft.
- Same input produces byte-for-byte equivalent issue ordering.
- No user string becomes an atom.

##### Failure behavior

- Invalid input returns issues, not exceptions; programmer-invariant violations may raise only in internal constructors and are tested.

##### Security considerations

- Bound traversal and nested collection sizes before expanding errors to avoid validation amplification.

##### Tests

- One positive and negative case per node.
- multiple-error aggregation.
- limit boundaries.
- stop/unreachable test.
- property test that validator terminates within bounded time.

##### Verification

- `mix test test/pumble_automation/workflows/validator_structure_test.exs`

##### Completion gate

- All structural invalid states have stable error codes.
- Valid contract examples pass.
- No I/O occurs.

##### Dependencies

`P5-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P6-T02 — Implement expressions, templates, and semantic validation

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Validate deterministic data references, comparisons, templates, node-specific configuration, and cross-reference availability.

##### Why now

A structurally valid workflow can still reference missing data or unsafe configuration.

##### Files/modules

- `lib/pumble_automation/workflows/expressions.ex`
- `templates.ex`
- `validator.ex`
- `test/pumble_automation/workflows/validator_semantic_test.exs`

##### Changes

- Define path segments and operators from Sections 21.1–21.3; no arbitrary function calls or code.
- Build a static output schema per trigger/node so references may target only trigger data or prior reachable step outputs.
- Validate typed comparison compatibility, missing-value policy, template size, interpolation locations, delay/schedule ranges, Pumble action fields, and HTTP method/header/body rules.
- For branch-local data, reject references not guaranteed on the current branch.
- Return warnings only for genuinely non-blocking risk; activation blocks on any error.

##### Invariants

- References cannot look forward or across an unexecuted branch.
- Templates are deterministic and bounded.
- Unknown values never silently coerce to truth.

##### Failure behavior

- Invalid paths/operators produce exact issues; validator does not access secrets or call external services.

##### Security considerations

- Disallow property traversal into internal structs, atom keys supplied by users, regex backtracking hazards, and unbounded interpolation.

##### Tests

- Path grammar tests.
- typed comparison matrix.
- branch reachability tests.
- template expansion upper-bound tests.
- missing-value behavior tests.

##### Verification

- `mix test test/pumble_automation/workflows/validator_semantic_test.exs test/pumble_automation/workflows/expressions_test.exs test/pumble_automation/workflows/templates_test.exs`

##### Completion gate

- Every expression/template accepted by activation can be evaluated by runtime.
- All invalid references are caught when statically knowable.

##### Dependencies

`P6-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P6-T03 — Implement compiler and canonical executable graph

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Compile the editable AST into a small immutable graph optimized for deterministic execution.

##### Why now

Workers should execute a verified program rather than repeatedly interpret editor layout.

##### Files/modules

- `lib/pumble_automation/workflows/compiler.ex`
- `compiled_workflow.ex`
- `test/pumble_automation/workflows/compiler_test.exs`

##### Changes

- Assign each node explicit next edges; condition and approval nodes receive named outcome edges; terminal paths target `end`.
- Embed only validated configuration and stable node IDs.
- Precompile path tokens, condition forms, and template segments into safe data.
- Derive node order, maximum path length, trigger projection, required capabilities, and compiler version.
- Canonicalize output for hashing; reject compile when validation has errors.
- Provide a read-only decoder for stored compiled versions.

##### Invariants

- Compiled graphs are acyclic and all nodes are reachable from trigger.
- Every nonterminal outcome has exactly one next target.
- Compiler output contains no secret plaintext.

##### Failure behavior

- Compiler returns issues rather than persisting partial output; unknown compiler version blocks execution with a typed operational error.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Golden compile tests for sequence, nested conditions, approval branches, delays, and terminals.
- graph acyclicity/reachability property tests.
- canonical output/hash stability.

##### Verification

- `mix test test/pumble_automation/workflows/compiler_test.exs`

##### Completion gate

- All valid sample workflows compile deterministically.
- Runtime can select next node without editor-tree traversal.
- No graph cycles/merges exist.

##### Dependencies

`P6-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P6-T04 — Calculate required scopes and dependencies

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Derive Pumble scopes, connection references, secret references, and trigger-binding metadata from the compiled workflow.

##### Why now

Activation must reject known missing prerequisites before production traffic.

##### Files/modules

- `lib/pumble_automation/workflows/compiler.ex`
- `lib/pumble_automation/pumble/scopes.ex`
- `lib/pumble_automation/workflows/dependencies.ex`
- `test/**/dependencies_test.exs`

##### Changes

- Walk compiled nodes and aggregate minimal bot/user scopes using the Pumble operation map.
- Collect connection and secret IDs with expected types and tenant.
- Derive trigger class/type/filter projection and schedule metadata.
- Distinguish `known required`, `probe-dependent`, and `not applicable` scope evidence.
- Compare known requirements with installation scope snapshot; return blocking issues only for proven missing scope and an explicit probe warning for unknown mappings.

##### Invariants

- Scope sets are sorted/deduplicated.
- A workflow cannot reference another tenant's connection/secret.
- Dependency calculation is deterministic.

##### Failure behavior

- Missing/revoked dependency blocks activation; unknown scope evidence cannot be claimed verified.

##### Security considerations

- Return secret names/IDs only to authorized editors; never decrypt during validation.

##### Tests

- Per-node scope tests.
- combined workflow dedupe.
- cross-tenant secret/connection test.
- removed-scope reinstall regression.

##### Verification

- `mix test test/pumble_automation/workflows/dependencies_test.exs`

##### Completion gate

- Every compiled node declares capabilities and dependencies.
- Known missing scopes are caught without Pumble call.
- Unknown mappings remain visible.

##### Dependencies

`P6-T03`, `P4-T07`, `P5-T08`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P6-T05 — Implement atomic activation

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Validate, compile, version, materialize bindings/schedules, and switch the active version in one transaction.

##### Why now

Activation is the boundary between editable configuration and production execution.

##### Files/modules

- `lib/pumble_automation/workflows/activation.ex`
- `lib/pumble_automation/workflows.ex`
- `test/pumble_automation/workflows/activation_test.exs`

##### Changes

- Lock the workflow and verify expected draft revision and installation status.
- Run pure validation/compiler and database dependency checks before mutation.
- Inside one `Ecto.Multi`, allocate version number, insert immutable version, replace trigger binding/schedule projection, set active version/status, and insert audit event.
- Reuse an existing identical content hash only if semantics and audit requirements explicitly allow; otherwise create the next version consistently.
- Return version and warnings; never activate with errors.
- Record compiler/dependency snapshot.

##### Invariants

- Readers see either the old complete activation or the new complete activation.
- Running executions stay bound to old version.
- Only one active version is referenced.

##### Failure behavior

- Any insert/constraint/audit failure rolls back all activation changes.
- Concurrent activations produce one winner and a revision conflict for the other.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Transaction rollback at every Multi step.
- concurrent activation race.
- old running execution version test.
- binding/schedule replacement test.
- known missing scope test.

##### Verification

- `mix test test/pumble_automation/workflows/activation_test.exs --trace`

##### Completion gate

- Activation is atomic under concurrency.
- No orphan version/binding/schedule exists.
- Invalid workflow receives full issue list and no production change.

##### Dependencies

`P6-T04`, `P5-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P6-T06 — Implement deactivation and version reactivation

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Stop new triggers safely and allow deliberate activation of a prior immutable version.

##### Why now

Operators need rollback without mutating historical programs.

##### Files/modules

- `lib/pumble_automation/workflows/activation.ex`
- `workflows.ex`
- `test/pumble_automation/workflows/deactivation_test.exs`

##### Changes

- Deactivation locks workflow, disables/removes active trigger binding and schedules, clears or marks active version reference according to schema, updates status, and audits atomically.
- Do not cancel running executions by default; expose that as a separate explicit operation.
- Reactivation validates current installation scopes/dependencies and creates fresh materialized bindings/schedules pointing to the selected immutable version.
- Require owner/editor policy as defined; destructive cancel-all requires owner.
- Keep version history unchanged.

##### Invariants

- After commit, no new event/schedule/manual trigger matches the deactivated workflow.
- Existing executions retain their version and continue unless explicitly cancelled.

##### Failure behavior

- Concurrent trigger creation observes binding state transactionally; a deactivation race may allow an execution already committed before deactivation, which is documented.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Deactivation/ingress race test.
- reactivate old version test.
- missing current secret/scope test.
- audit rollback test.

##### Verification

- `mix test test/pumble_automation/workflows/deactivation_test.exs`

##### Completion gate

- New matching is stopped at commit.
- Prior version can be reactivated only after current dependency validation.
- History remains immutable.

##### Dependencies

`P6-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P7 — Durable execution engine

#### P7-T01 — Create execution, step, attempt, and approval schemas

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Persist the complete durable state machine and external-effect ledger.

##### Why now

Workers cannot be correct without database constraints for execution ownership and step identity.

##### Files/modules

- `lib/pumble_automation/executions/execution.ex`
- `step_execution.ex`
- `step_attempt.ex`
- `approval.ex`
- `priv/repo/migrations/*executions*.exs`

##### Changes

- Create schemas from Section 14.4 with installation/workflow/version keys, status, current node, context, trigger snapshot, lineage, cancellation, timestamps, and lock version.
- Create one step execution per execution/node with status, resolved input hash/sanitized data, output summary, branch/outcome, effect key, and attempt counters.
- Create immutable attempt rows with job ID, start/end, classification, provider IDs, and sanitized diagnostics.
- Create approvals with opaque public action ID/token hash, allowed approvers, status, deadline, decision actor/time, and version.
- Add check/unique constraints for valid status and `(execution_id,node_id)`.

##### Invariants

- All rows share the same installation through validated inserts.
- A loop-free node executes at most once per execution.
- Attempt history is append-only.

##### Failure behavior

- Constraint failure prevents worker progress; context/output size overflow becomes explicit failure, not database crash.

##### Security considerations

- Execution trigger/input/output columns store sanitized bounded data; approval tokens are hashed, not plaintext.

##### Tests

- Migration/changeset/status constraint tests.
- cross-tenant parent mismatch.
- unique step race.
- approval decision uniqueness.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/executions/schema_test.exs`

##### Completion gate

- Durable schema represents every planned state.
- Critical uniqueness is enforced in PostgreSQL.
- Sensitive fields are marked/redacted.

##### Dependencies

`P5-T04`, `P3-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P7-T02 — Implement pure execution state machine

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Define valid execution, step, attempt, approval, cancellation, and uncertainty transitions as pure functions.

##### Why now

Workers and operator actions need one authority for invariants.

##### Files/modules

- `lib/pumble_automation/executions/state_machine.ex`
- `outcome.ex`
- `test/pumble_automation/executions/state_machine_test.exs`

##### Changes

- Enumerate states from Section 19 and transition commands with required preconditions.
- Return transition plans or typed conflicts; do not mutate Ecto structs directly in callers.
- Define terminal-state behavior, waiting/resume, retry, cancellation request, uncertain pause, and operator resolution.
- Define how workflow deactivation differs from installation uninstall.
- Define branch/outcome labels and next-node expectations.

##### Invariants

- Terminal states cannot leave.
- At most one current runnable node exists.
- A step cannot move from completed back to runnable.
- Uncertainty requires explicit resolution.

##### Failure behavior

- Invalid/stale transitions are no-ops or conflicts according to caller; they never corrupt state.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Complete transition table.
- property tests for terminal closure and no illegal backwards transitions.
- duplicate command idempotency.

##### Verification

- `mix test test/pumble_automation/executions/state_machine_test.exs`

##### Completion gate

- All state transitions used later are explicit and tested.
- No worker invents status updates.
- Uncertainty/cancellation semantics are unambiguous.

##### Dependencies

`P7-T01`, `P1-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P7-T03 — Implement atomic execution creation

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Create an execution, initial step state, and Oban advance job in one transaction.

##### Why now

Every ingress path depends on a no-gap execution start primitive.

##### Files/modules

- `lib/pumble_automation/executions/engine.ex`
- `workers/advance_execution_worker.ex`
- `test/pumble_automation/executions/create_execution_test.exs`

##### Changes

- Accept verified scope, immutable version ID, trigger identity/snapshot, idempotency key, lineage, and run mode.
- Lock/check active installation and applicable workflow binding as needed.
- Insert execution in `PENDING`, derive first node from compiled version, insert initial step record if design requires it, and insert an Oban job in the same `Ecto.Multi`.
- Add a unique source key for ingress-triggered execution where duplicate creation must collapse.
- Return existing execution for duplicate source according to ingress semantics.

##### Invariants

- No durable execution lacks a future advance job unless terminal.
- Version belongs to tenant/workflow.
- Context starts within limits.

##### Failure behavior

- Any validation, insert, or job failure rolls back everything.
- Duplicate concurrent create returns one execution.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Rollback injection at each Multi step.
- concurrent duplicate create.
- inactive installation/version mismatch.
- lineage depth limit.

##### Verification

- `mix test test/pumble_automation/executions/create_execution_test.exs --trace`

##### Completion gate

- One call creates one recoverable execution/job atomically.
- All ingress modules can use it without Repo access.
- Duplicate semantics are proved.

##### Dependencies

`P7-T02`, `P2-T04`, `P6-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P7-T04 — Implement worker claim protocol

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Allow one worker attempt to claim the current runnable step while duplicates and stale jobs safely exit.

##### Why now

At-least-once job execution and races are normal.

##### Files/modules

- `lib/pumble_automation/executions/engine.ex`
- `workers/advance_execution_worker.ex`
- `test/pumble_automation/executions/claim_test.exs`

##### Changes

- Worker loads IDs from job args, opens a short transaction, locks execution/current step, and verifies installation, status, node, expected generation/version, and cancellation.
- If no step row exists, insert it under unique constraint; if completed/waiting/terminal, return a stale no-op.
- Create attempt row and mark step/execution running with attempt token/generation.
- Commit before evaluating or calling an external service.
- Return a bounded execution snapshot containing only data needed by node runner.

##### Invariants

- Only one attempt token owns finalization at a time.
- Duplicate jobs do not create duplicate active attempts.
- No external I/O occurs while DB locks are held.

##### Failure behavior

- Lock timeout/retry is classified transiently; stale job returns success/no-op so Oban does not retry forever.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Two-worker barrier race.
- duplicate job.
- cancel-before-claim.
- uninstall-before-claim.
- already-completed/waiting cases.

##### Verification

- `mix test test/pumble_automation/executions/claim_test.exs --trace`

##### Completion gate

- Concurrent claim has exactly one winner.
- Locks are short.
- Every loser has deterministic no-op/retry behavior.

##### Dependencies

`P7-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P7-T05 — Define node runner protocol and registry

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Give the engine one finite boundary for pure and effectful node evaluation.

##### Why now

Node-specific code must not own execution transactions or arbitrary next-node logic.

##### Files/modules

- `lib/pumble_automation/executions/node_runner.ex`
- `node_registry.ex`
- `outcome.ex`
- `test/pumble_automation/executions/node_runner_test.exs`

##### Changes

- Define input: compiled node, immutable context snapshot, tenant scope/reference resolver, run mode, effect key, attempt metadata.
- Define outcomes: success with sanitized output and named edge; wait until timestamp; await approval; retryable error; permanent error; uncertain effect; cancelled.
- Register only contract node types in a static map/pattern match.
- Separate pure evaluators from Pumble/HTTP adapters through actual substitution boundaries.
- Require runners to declare effect class, retry safety, output schema, and max output size.

##### Invariants

- Runners never update execution tables or enqueue jobs.
- Every outcome is bounded and typed.
- Unknown node type is permanent compiler/runtime mismatch.

##### Failure behavior

- Runner exception is caught at worker boundary, classified internal, recorded, and retried only under bounded engine policy.

##### Security considerations

- Registry uses compile-time atoms/modules only; runner diagnostics pass through redaction before persistence.

##### Tests

- Registry completeness test against compiler node catalog.
- outcome validation/size tests.
- exception wrapping.

##### Verification

- `mix test test/pumble_automation/executions/node_runner_test.exs`

##### Completion gate

- Compiler and runtime catalogs match exactly.
- No arbitrary module dispatch from user data.
- All outcomes map to state-machine commands.

##### Dependencies

`P7-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P7-T06 — Implement finalize-and-advance transaction

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Persist a runner outcome, update context/state, and enqueue the next durable job atomically.

##### Why now

This closes the claim-execute-finalize failure window.

##### Files/modules

- `lib/pumble_automation/executions/engine.ex`
- `workers/advance_execution_worker.ex`
- `test/pumble_automation/executions/finalize_test.exs`

##### Changes

- Lock execution/step and require the current attempt token/generation.
- Insert/finalize attempt diagnostics; finalize step with outcome, branch, provider IDs, and sanitized output.
- Merge output into bounded immutable execution context under the step node ID.
- Use compiled edge to choose next node; mark completed terminal or waiting/approval/uncertain states.
- Insert next advance/delay/timeout job in the same transaction when runnable.
- A stale finalizer returns no-op and cannot overwrite a newer/terminal state.

##### Invariants

- Completed step and next job commit together.
- Context keys are deterministic and one-write per node.
- Only compiled edges can be followed.

##### Failure behavior

- Transaction failure leaves claim recoverable by reconciliation/retry without treating effect as unperformed blindly.
- Output limit violation becomes permanent failure.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Rollback at each step.
- duplicate finalization.
- stale attempt.
- branch edge.
- terminal completion.
- job insertion failure.
- context size limit.

##### Verification

- `mix test test/pumble_automation/executions/finalize_test.exs --trace`

##### Completion gate

- Every outcome produces one valid durable transition.
- No completed step lacks next work when required.
- Stale finalizers cannot corrupt state.

##### Dependencies

`P7-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P7-T07 — Implement retry and error policy

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Apply bounded per-node retry decisions with jittered backoff and explicit exhaustion behavior.

##### Why now

Oban retries alone do not understand ambiguous effects or provider semantics.

##### Files/modules

- `lib/pumble_automation/executions/retry_policy.ex`
- `workers/advance_execution_worker.ex`
- `test/pumble_automation/executions/retry_policy_test.exs`

##### Changes

- Map error taxonomy to retry/no-retry/uncertain from Section 30.
- Use maximum five attempts by default, exponential backoff with full jitter and provider Retry-After capped by resource policy.
- Differentiate infrastructure failure before effect, confirmed provider rejection, and unknown remote outcome.
- Record every attempt and next retry time.
- On exhaustion, finalize execution failed with safe diagnostic.
- Configure Oban worker attempts high enough for engine-controlled scheduling but prevent double retry layers; choose one authoritative mechanism.

##### Invariants

- Permanent errors never retry.
- Unknown non-idempotent write outcomes never auto-retry.
- Backoff is bounded and deterministic under seeded test.

##### Failure behavior

- Retry scheduling insert failure leaves a reconcilable state; it does not mark step completed.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Status/error matrix tests.
- Retry-After parsing/cap.
- jitter range.
- attempt exhaustion.
- worker-level exception before/after claim.

##### Verification

- `mix test test/pumble_automation/executions/retry_policy_test.exs`

##### Completion gate

- Every error class has one policy.
- No infinite retry path.
- Attempt history explains each delay/exhaustion.

##### Dependencies

`P7-T06`, `P4-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P7-T08 — Implement uncertain-effect pause and operator resolution

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Stop unsafe automatic repetition when a remote write may have succeeded and provide audited recovery choices.

##### Why now

Network ambiguity is unavoidable without server-side idempotency.

##### Files/modules

- `lib/pumble_automation/executions/engine.ex`
- `uncertainty.ex`
- `lib/pumble_automation_web/live/execution_live/show.ex later`
- `test/**/uncertainty_test.exs`

##### Changes

- Persist effect key, attempt, operation summary, timing, remote correlation if any, and why outcome is uncertain.
- Transition execution to `PAUSED_UNCERTAIN` and stop all automatic jobs.
- Expose owner-only commands: mark effect succeeded with optional sanitized evidence; mark failed and stop; or deliberately retry with duplicate-risk acknowledgement.
- Resolution locks the execution, is one-time/idempotent, updates step/attempt, schedules next work when appropriate, and audits actor/choice.
- Never ask the operator to paste secrets or raw private payloads.

##### Invariants

- Uncertain state performs no new effects automatically.
- Only an authorized owner can resolve.
- A resolution cannot be changed silently.

##### Failure behavior

- Concurrent duplicate resolution has one winner; stale UI receives conflict.
- Retry choice creates a new attempt and preserves prior uncertainty history.

##### Security considerations

- Show only sanitized method/host/action summary and IDs; restrict duplicate-risk retry to owner with explicit confirmation.

##### Tests

- Role tests.
- concurrent resolution.
- mark-success continuation.
- stop.
- deliberate retry.
- uninstall during uncertainty.
- audit redaction.

##### Verification

- `mix test test/pumble_automation/executions/uncertainty_test.exs`

##### Completion gate

- Ambiguous write failure never loops.
- All recovery choices are durable/audited.
- Resolution resumes or terminates exactly once.

##### Dependencies

`P7-T07`, `P3-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P7-T09 — Implement cancellation, concurrency limits, and reconciliation

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide safe operator cancellation, tenant fairness, and repair of recoverable state/job gaps.

##### Why now

Production operation needs bounded work and recovery without manual database surgery.

##### Files/modules

- `lib/pumble_automation/executions/engine.ex`
- `workers/reconciliation_worker.ex`
- `concurrency.ex`
- `test/**/cancellation_reconciliation_test.exs`

##### Changes

- Cancellation sets a durable request and immediately terminates waiting states where safe; a running external call cannot be magically revoked and finalizer observes cancellation before next step.
- Enforce per-workspace running limit using transactional counters/advisory locks or indexed query plus lock; choose the simplest proven correct method.
- Queue excess executions in `PENDING` and wake them fairly when slots free.
- Reconciliation scans bounded indexed anomalies: runnable execution without job, stale running attempt past lease, waiting state without scheduled job, orphaned approval timeout.
- Repair only states whose safe action is provable; ambiguous effects become uncertain, not retried.
- Audit manual cancellation and automatic repair.

##### Invariants

- Cancellation never rewinds completed effects.
- Concurrency is enforced per tenant.
- Reconciliation is idempotent and bounded.

##### Failure behavior

- If state cannot be safely classified, alert and pause rather than guessing.
- Uninstall wins over resume.

##### Security considerations

- Reconciliation queries and repairs are tenant-aware; admin invocation is protected and audit logged.

##### Tests

- Cancel pending/running/waiting/approval.
- concurrency race with many workers.
- fair wake-up.
- missing-job repair.
- stale attempt before/after possible effect.
- duplicate reconciliation.

##### Verification

- `mix test test/pumble_automation/executions/cancellation_reconciliation_test.exs --trace`

##### Completion gate

- No normal recoverable gap requires SQL surgery.
- Limits hold under race.
- Unsafe stale effects enter uncertainty.

##### Dependencies

`P7-T08`, `P2-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P8 — Ingress, deduplication, and trigger matching

#### P8-T01 — Create received-event and inbound-webhook schemas

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Persist callback receipt identity, bounded sanitized payload, processing state, and tenant-owned webhook endpoints.

##### Why now

Deduplication and durable trigger creation require an ingress ledger.

##### Files/modules

- `lib/pumble_automation/ingress/received_event.ex`
- `webhook_endpoint.ex`
- `priv/repo/migrations/*received_events*.exs`
- `*webhook_endpoints*.exs`

##### Changes

- Create `received_events` with installation, provider/class/type, dedup key, provider ID, raw body hash, normalized bounded data, received/occurred timestamps, processing state, and retention date.
- Add unique `(installation_id, provider, dedup_key)` and lookup indexes.
- Create webhook endpoints with public ID, token hash, optional previous token hash/expiry, workflow/version binding, enabled, last-used, rate settings, and timestamps.
- Never persist raw Pumble body by default; retain only hash and normalized/sanitized fields needed for audit/debug.
- Set foreign-key behavior for uninstall/deactivation.

##### Invariants

- Every received event has one installation.
- Dedup uniqueness is database enforced.
- Webhook plaintext token is shown once and never stored.

##### Failure behavior

- Duplicate insert is a normal result, not an exception surfaced as 500.
- Invalid retention/config cannot persist.

##### Security considerations

- Use a slow password hash only if token entropy is low; with 256-bit random tokens, a keyed SHA-256 hash is sufficient and cheaper under webhook load.

##### Tests

- Migration/changeset tests.
- unique dedup race.
- token hash verification.
- cross-tenant endpoint lookup.
- retention index test.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/ingress/received_event_test.exs test/pumble_automation/ingress/webhook_endpoint_test.exs`

##### Completion gate

- Ingress schemas replay cleanly.
- No raw credential/body storage exists.
- Duplicate race is deterministic.

##### Dependencies

`P5-T05`, `P3-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P8-T02 — Implement deduplication-key strategy

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Derive stable provider-aware keys without making false guarantees for payloads lacking a documented unique ID.

##### Why now

Duplicate delivery is expected, but false suppression of legitimate events is also harmful.

##### Files/modules

- `lib/pumble_automation/ingress/deduplication.ex`
- `docs/architecture/delivery_semantics.md`
- `test/pumble_automation/ingress/deduplication_test.exs`

##### Changes

- For documented event request IDs, use callback class + event type + provider ID scoped to installation.
- For interactive triggers, use trigger ID plus action/source identity where documented and live-proven.
- For lifecycle events, use provider event/install identifiers and terminal state.
- When no stable ID exists, use the weakest conservative fallback defined by probe evidence; label semantics and bounded dedup window explicitly.
- For generic webhooks, use caller `Idempotency-Key` when present; without it, treat each authenticated request as distinct.
- Hash keys before storage if they may contain sensitive material.

##### Invariants

- A documented stable ID always wins over body heuristics.
- No claim of exactly-once is made.
- Fallback collisions and window are documented.

##### Failure behavior

- Missing identity that would create unsafe cross-event suppression results in distinct acceptance or a typed rejection according to trigger class.

##### Security considerations

- Do not use attacker-controlled unbounded idempotency keys directly in indexes; normalize length and hash.

##### Tests

- Same-ID/different-body test records integrity anomaly.
- concurrent duplicate insert.
- no-key webhook distinct-delivery test.
- fallback-window boundary test.

##### Verification

- `mix test test/pumble_automation/ingress/deduplication_test.exs`

##### Completion gate

- Every accepted ingress class has explicit dedup semantics.
- Duplicate race creates one receipt.
- Fallback uncertainty is visible in docs/telemetry.

##### Dependencies

`P8-T01`, `P0-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P8-T03 — Implement indexed trigger matcher

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Find active workflow versions for a normalized trigger using tenant/type/selective filters without scanning workflows.

##### Why now

Event throughput and tenant correctness depend on simple indexed matching.

##### Files/modules

- `lib/pumble_automation/ingress/trigger_matcher.ex`
- `lib/pumble_automation/workflows/trigger_binding.ex`
- `test/pumble_automation/ingress/trigger_matcher_test.exs`

##### Changes

- Build queries by installation, enabled state, trigger class/type, and materialized selective fields such as channel or manual alias.
- Apply remaining small deterministic trigger filters in Elixir only after indexed candidate selection.
- Return immutable version IDs and binding IDs.
- Define stable ordering for multiple matching workflows.
- Exclude uninstalled installations and deactivated bindings.

##### Invariants

- No cross-tenant candidate can enter the result.
- Matcher never parses draft workflow JSON.
- Same database snapshot yields stable ordering.

##### Failure behavior

- Malformed filter projection marks binding invalid/degraded and does not crash all matching.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Cross-tenant tests.
- channel/alias/filter tests.
- disabled/uninstalled tests.
- query-plan assertion on representative dataset.
- large workspace candidate-count test.

##### Verification

- `mix test test/pumble_automation/ingress/trigger_matcher_test.exs`
- EXPLAIN ANALYZE fixture documented for production-like sample

##### Completion gate

- Matching uses intended indexes.
- No full workflow scan occurs.
- All returned versions are active and tenant-correct.

##### Dependencies

`P8-T01`, `P6-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P8-T04 — Implement Pumble event ingestion transaction

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Deduplicate a verified normalized event and create all matching executions with initial jobs durably.

##### Why now

This is the main event-to-execution consistency boundary.

##### Files/modules

- `lib/pumble_automation/ingress/service.ex`
- `lib/pumble_automation/executions/engine.ex later interface`
- `test/pumble_automation/ingress/pumble_ingestion_test.exs`

##### Changes

- Given verified payload/raw hash, resolve installation by workspace ID and reject inactive tenants.
- Compute dedup key and attempt received-event insert with conflict-safe return.
- For a new receipt, find bindings and create one execution plus initial Oban job per binding within a transaction or a deliberately bounded sequence of transactions with resume marker.
- Store a minimal sanitized trigger snapshot and correlation identity.
- Mark receipt processed with execution count; duplicate receipt returns existing result and creates nothing.
- Choose batch limits so one event cannot create unbounded executions.

##### Invariants

- Receipt and resulting execution/job records cannot diverge silently.
- Duplicate callbacks do not create new executions.
- Each execution binds the exact version returned by matcher.

##### Failure behavior

- A failed transaction leaves receipt unprocessed/retryable or rolls it back according to the chosen atomic design; reconciliation can finish partial bounded batches if batching is required.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Duplicate concurrent callback.
- zero/one/many matches.
- job insert failure rollback.
- process crash injection between receipt and execution creation.
- uninstalled tenant test.

##### Verification

- `mix test test/pumble_automation/ingress/pumble_ingestion_test.exs --trace`

##### Completion gate

- Same stable event produces documented execution count once.
- No execution exists without initial job.
- Failure is recoverable without duplicate effects.

##### Dependencies

`P8-T03`, `P7-T03`, `P4-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P8-T05 — Wire lifecycle callbacks

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Route APP_UNAUTHORIZED and APP_UNINSTALLED through the signed, deduplicated ingress boundary into installation lifecycle services.

##### Why now

Lifecycle events must not be mistaken for user workflow triggers.

##### Files/modules

- `lib/pumble_automation/ingress/service.ex`
- `lib/pumble_automation/installations/service.ex`
- `test/pumble_automation/ingress/lifecycle_ingestion_test.exs`

##### Changes

- Classify lifecycle events before normal trigger matching.
- Deduplicate them using lifecycle identity.
- Call the appropriate idempotent installation transition in a bounded transaction.
- Return the protocol acknowledgement only after the terminal blocked state is durable.
- Do not create user executions or expose these events in workflow editor.

##### Invariants

- Uninstall/unauthorized cannot trigger user actions.
- Duplicate lifecycle events converge to one state.
- Credentials are unusable before success acknowledgement.

##### Failure behavior

- Unknown workspace lifecycle callback is acknowledged or rejected according to live-proven Pumble retry behavior and recorded as an anomaly without creating tenant data.

##### Security considerations

- Do not accept lifecycle transitions from generic webhook or browser routes.

##### Tests

- Duplicate, out-of-order unauthorized/uninstall, unknown workspace, and race-with-worker tests.

##### Verification

- `mix test test/pumble_automation/ingress/lifecycle_ingestion_test.exs`

##### Completion gate

- Lifecycle events produce only lifecycle state changes.
- No workflow execution is created.
- Credential purge/blocking is durable before ack.

##### Dependencies

`P3-T05`, `P8-T02`, `P4-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P8-T06 — Implement manual Pumble and browser trigger ingestion

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Convert fixed slash/shortcut selections and authorized browser test/run actions into durable executions.

##### Why now

Static manifest entry points need a safe route to dynamic workflow aliases.

##### Files/modules

- `lib/pumble_automation/ingress/manual_trigger.ex`
- `lib/pumble_automation_web/controllers/pumble_callback_controller.ex`
- `lib/pumble_automation_web/live/workflow_live/** later`
- `test/**/manual_trigger_test.exs`

##### Changes

- Resolve workflow by installation plus unique active alias or selected version; never by unscoped ID.
- For message shortcut, include a bounded normalized source-message reference/snapshot only when proven available.
- For browser run, require editor role and explicit dry-run/live mode.
- Deduplicate Pumble interactions using trigger/action identity; browser runs receive a generated request ID and optional idempotency token.
- Persist execution and initial job through the same engine API as events.
- Use protocol-safe picker/response behavior selected by P17 probes; keep alternatives behind adapter functions.

##### Invariants

- Manual entry cannot bypass active-version or scope checks.
- A viewer cannot live-run.
- One Pumble interaction creates at most one execution.

##### Failure behavior

- Unknown/disabled alias returns a safe ephemeral/not-found response; no fallback to another tenant.
- Failure before durable creation is not acknowledged as started.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Alias collision, disabled workflow, duplicate trigger, message-source, role, dry-run, and cross-tenant tests.

##### Verification

- `mix test test/pumble_automation/ingress/manual_trigger_test.exs`

##### Completion gate

- All manual entry paths use one tenant-scoped engine API.
- Interaction duplicates are safe.
- Response behavior is isolated for live correction.

##### Dependencies

`P8-T02`, `P7-T03`, `P3-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P8-T07 — Implement authenticated generic inbound webhooks

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Accept bounded JSON webhook triggers with revocable high-entropy credentials and explicit delivery semantics.

##### Why now

The generic webhook expands integration reach but is an internet-facing abuse boundary.

##### Files/modules

- `lib/pumble_automation_web/controllers/inbound_webhook_controller.ex`
- `lib/pumble_automation/ingress/webhook_service.ex`
- `router.ex`
- `test/**/inbound_webhook_controller_test.exs`

##### Changes

- Expose POST only on an opaque public endpoint ID.
- Verify a 256-bit bearer token from `Authorization` or one fixed header using stored keyed hash; never accept credentials in query strings.
- Support token rotation with a short explicit overlap.
- Require JSON content type, enforce body/depth/key/string limits, and normalize headers from a small allowlist if exposed to templates.
- Apply per-endpoint and per-IP rate limits.
- Use caller `Idempotency-Key` if present; otherwise create a distinct receipt.
- Create execution against the endpoint's currently bound active version and return 202 with opaque receipt ID.

##### Invariants

- Endpoint token authorizes only one tenant endpoint.
- Webhook cannot choose arbitrary workflow/version.
- Payload never contains executable code or secret definitions.

##### Failure behavior

- Invalid auth is 401/404 without endpoint disclosure; disabled endpoint is terminal; overload is 429; persistence failure is 503 and not falsely accepted.

##### Security considerations

- Use uniform auth failure timing where practical; add abuse telemetry without retaining full payload.

##### Tests

- Auth/rotation, content-type, size/depth, rate, idempotency, disabled, cross-tenant, and transaction failure tests.

##### Verification

- `mix test test/pumble_automation_web/controllers/inbound_webhook_controller_test.exs`

##### Completion gate

- Internet-facing webhook is bounded and revocable.
- Accepted response corresponds to durable execution/job.
- No credential appears in logs/URL.

##### Dependencies

`P8-T02`, `P7-T03`, `P6-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P9 — Core runtime data and Pumble nodes

#### P9-T01 — Implement runtime path resolver

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Resolve prevalidated trigger and prior-step data without arbitrary object access.

##### Why now

Conditions and templates need one deterministic data-access primitive.

##### Files/modules

- `lib/pumble_automation/workflows/path.ex`
- `lib/pumble_automation/executions/context.ex`
- `test/pumble_automation/workflows/path_test.exs`

##### Changes

- Represent paths as compiler-produced segment lists, not runtime-parsed arbitrary code.
- Allow roots `trigger`, `steps`, and explicitly documented execution metadata only.
- Support string-keyed maps and bounded list indices; do not traverse structs, PIDs, functions, or atoms from user input.
- Return `{:ok, value}` or a typed missing/type error with safe path.
- Define and test null versus missing distinction.

##### Invariants

- Resolution is read-only and deterministic.
- A path cannot access credentials, tenant structs, or internal process state.
- Traversal work is bounded by path length.

##### Failure behavior

- Missing/type mismatch follows node-configured policy; it never raises into worker.

##### Security considerations

- Never expose secret resolver results in the general context tree; secret references are resolved only by owning action.

##### Tests

- All root/segment types.
- missing vs null.
- index bounds.
- malicious segment/atom growth.
- maximum path length.

##### Verification

- `mix test test/pumble_automation/workflows/path_test.exs`

##### Completion gate

- Compiler-produced valid paths resolve consistently.
- Invalid runtime data yields typed errors.
- No internal struct access is possible.

##### Dependencies

`P7-T05`, `P6-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P9-T02 — Implement deterministic template renderer

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Render bounded strings and JSON values from literal segments and safe references.

##### Why now

Pumble and HTTP actions need predictable interpolation without creating a programming language.

##### Files/modules

- `lib/pumble_automation/workflows/templates.ex`
- `test/pumble_automation/workflows/template_runtime_test.exs`

##### Changes

- Evaluate compiler-produced literal/reference segments.
- Define conversion rules for strings, numbers, booleans, null, arrays, and objects; require explicit JSON insertion for non-string values.
- Define missing-value modes: error by default, optional empty only when field schema permits.
- Enforce maximum input template, number of references, per-value, and final expansion sizes.
- Return rendered value plus a list of used paths for diagnostics, without values in logs.

##### Invariants

- Same context/template yields same bytes.
- No implicit locale/timezone formatting.
- Expansion cannot exceed configured bound.

##### Failure behavior

- Missing/type/size errors are permanent configuration/data errors unless node policy explicitly handles them.

##### Security considerations

- Do not include resolved secret values in the returned used-path diagnostics; secrets use separate write-only placeholders.

##### Tests

- String/JSON rendering.
- escaping.
- missing/null.
- large expansion.
- non-string insertion.
- determinism.

##### Verification

- `mix test test/pumble_automation/workflows/template_runtime_test.exs`

##### Completion gate

- Every compiled template form renders or fails with a stable code.
- Output bounds hold before network/persistence.

##### Dependencies

`P9-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P9-T03 — Implement condition and branch node

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Evaluate typed predicates and return exactly one compiled outcome edge.

##### Why now

Branch correctness is central to deterministic workflows.

##### Files/modules

- `lib/pumble_automation/executions/nodes/condition.ex`
- `lib/pumble_automation/workflows/expressions.ex`
- `test/pumble_automation/executions/nodes/condition_test.exs`

##### Changes

- Implement equality/inequality, ordered numeric/date comparisons where types are known, contains/starts/ends for strings, membership for bounded lists, exists/missing, AND, OR, and NOT only if in the approved contract.
- Use explicit type rules; do not coerce numeric strings or truthiness.
- Short-circuit logical forms while preserving deterministic diagnostics.
- Return success with `true` or `false` edge and a sanitized reason summary.
- Do not add regex unless product evidence explicitly approves a bounded safe engine.

##### Invariants

- Exactly one branch is selected.
- Unknown/missing follows validated policy.
- No external I/O.

##### Failure behavior

- Evaluation errors produce permanent step failure with field/path information, not arbitrary exception text.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Operator/type matrix.
- nested logical expressions.
- short-circuit.
- missing/null.
- branch reason redaction.

##### Verification

- `mix test test/pumble_automation/executions/nodes/condition_test.exs`

##### Completion gate

- Condition runtime matches activation validator semantics.
- Only selected branch becomes runnable.
- No implicit coercion exists.

##### Dependencies

`P9-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P9-T04 — Implement Pumble message, reply, and DM nodes

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Execute the primary proven Pumble communication actions through the narrow client.

##### Why now

These actions provide the first useful end-to-end workflows.

##### Files/modules

- `lib/pumble_automation/executions/nodes/pumble_send_message.ex`
- `pumble_reply.ex`
- `pumble_dm.ex`
- `lib/pumble_automation/pumble/blocks.ex`
- `test/**/pumble_message_nodes_test.exs`

##### Changes

- Render text/blocks with template limits and validate target IDs from trigger/config.
- Select bot token by default; allow user token only for an explicit node capability and authorization model.
- For reply, require a message/thread source supported by trigger data or configured ID.
- For DM, use adapter direct-channel lookup/create and send.
- Generate stable effect key and pass it to telemetry/ledger; include provider message/channel IDs in sanitized output.
- Classify pre-send failure, confirmed rejection, and timeout/connection loss after write dispatch according to P8 uncertainty policy.
- Dry-run returns request summary without credential resolution or network.

##### Invariants

- All network calls use Pumble client.
- Rendered payload is bounded.
- Unknown write outcome is not retried automatically.

##### Failure behavior

- 401/403 permanent/degraded; 429/5xx retry only when outcome is known safe; ambiguous write transitions uncertain.

##### Security considerations

- Escape/validate block content; do not permit user templates to set auth headers or arbitrary Pumble endpoints.

##### Tests

- Fake Pumble success/status/timeout cases.
- reply target validation.
- DM existing/create paths.
- dry-run no-network.
- duplicate worker/finalization.

##### Verification

- `mix test test/pumble_automation/executions/nodes/pumble_message_nodes_test.exs`

##### Completion gate

- Actions complete with provider IDs on success.
- All failure windows map to documented state.
- No raw token or private full payload is logged.

##### Dependencies

`P7-T08`, `P9-T02`, `P4-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P9-T05 — Implement reaction nodes

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Add and remove proven Pumble reactions with explicit target and retry semantics.

##### Why now

Reactions are a compact second Pumble action category and approval/status building block.

##### Files/modules

- `lib/pumble_automation/executions/nodes/pumble_add_reaction.ex`
- `pumble_remove_reaction.ex`
- `test/**/pumble_reaction_nodes_test.exs`

##### Changes

- Resolve target message from trigger/step/config.
- Validate reaction code and optional skin tone against documented limits.
- Call only adapter add/remove methods.
- Classify already-present/already-absent behavior from live evidence; until proven, preserve provider response rather than assuming idempotence.
- Record target/message and reaction code in sanitized output, not message text.
- Support dry-run.

##### Invariants

- Target belongs to current Pumble workspace context.
- No arbitrary API call.
- Retry safety follows proven provider behavior.

##### Failure behavior

- Ambiguous network outcome is uncertain unless live evidence proves idempotent convergence.
- Invalid reaction is permanent.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Success, invalid, 401/403/429/5xx/timeout.
- already state behavior fixture/probe.
- cross-context target.
- dry-run.

##### Verification

- `mix test test/pumble_automation/executions/nodes/pumble_reaction_nodes_test.exs`

##### Completion gate

- Reaction actions have explicit live-proven or conservative semantics.
- No blind automatic repeat after ambiguity.

##### Dependencies

`P9-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P9-T06 — Implement stop node and end-to-end dry-run

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Finish pure control flow and provide a side-effect-free execution preview.

##### Why now

Users and tests need to validate branches/templates before activation or live effects.

##### Files/modules

- `lib/pumble_automation/executions/nodes/stop.ex`
- `lib/pumble_automation/executions/dry_run.ex`
- `test/pumble_automation/executions/dry_run_test.exs`

##### Changes

- Stop node returns terminal success with configured safe reason.
- Dry-run executes pure nodes, renders effect summaries, simulates delay/approval boundaries, and uses supplied sample trigger data.
- It must not decrypt secrets, call Pumble, call external HTTP, insert production jobs, or mutate active workflow state.
- Return ordered trace: node, resolved references, branch, validation/runtime issues, and redacted would-send summary.
- Enforce the same limits and compiler version as live execution.

##### Invariants

- Dry-run has zero external side effects.
- Trace order matches compiled execution.
- Sensitive values remain redacted.

##### Failure behavior

- An effectful node that lacks enough sample data returns a preview issue, not an attempted call.

##### Security considerations

- Sample input is tenant-private; do not persist it by default or include raw content in logs.

##### Tests

- Network spy proves no calls.
- branch/stop trace.
- secret placeholder.
- delay/approval preview.
- large sample limits.
- compiled/live parity tests.

##### Verification

- `mix test test/pumble_automation/executions/dry_run_test.exs`

##### Completion gate

- A representative workflow can be previewed end to end.
- No credential access or production persistence occurs.
- Trace is usable by UI.

##### Dependencies

`P9-T05`, `P9-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P10 — Safe generic HTTP execution boundary

#### P10-T01 — Implement URL and IP policy

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Reject non-HTTP(S), local, private, link-local, metadata, and otherwise unsafe targets before any connection.

##### Why now

SSRF is the generic HTTP node's primary security risk.

##### Files/modules

- `lib/pumble_automation/connections/ip_policy.ex`
- `url_policy.ex`
- `test/pumble_automation/connections/ip_policy_test.exs`

##### Changes

- Parse URI strictly; default to HTTPS and allow HTTP only through an explicit deployment/product decision.
- Reject userinfo, fragments, invalid ports, non-ASCII confusion after IDNA normalization, and hosts outside length limits.
- Resolve DNS through an injectable resolver and inspect every A/AAAA result.
- Reject loopback, unspecified, multicast, private/RFC1918, CGNAT if policy requires, link-local, unique-local IPv6, mapped IPv4, documentation/reserved ranges, and cloud metadata addresses.
- Return an approved immutable target containing original hostname, port, scheme, and validated IP set with short expiry.
- Re-run policy for every request attempt and redirect.

##### Invariants

- All resolved addresses must be allowed, not just one.
- The hostname used for certificate/SNI remains original.
- A literal IP is checked by the same policy.

##### Failure behavior

- DNS failure is transient; mixed allowed/blocked answers are blocked; policy parsing errors are permanent.

##### Security considerations

- Do not use OS proxy environment variables for outbound workflow calls; reject proxy configuration from user input.

##### Tests

- Exhaustive table for IPv4/IPv6 classes.
- IPv4-mapped IPv6.
- localhost variants.
- decimal/hex/octal IP tricks.
- IDNA.
- mixed DNS answers.
- metadata names/IPs.

##### Verification

- `mix test test/pumble_automation/connections/ip_policy_test.exs`

##### Completion gate

- Known SSRF bypass forms are blocked.
- Allowed public host returns only validated targets.
- Policy is pure/injectable and independently testable.

##### Dependencies

`P5-T08`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P10-T02 — Implement DNS-pinned outbound transport

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Connect to an already validated IP while preserving original hostname for TLS SNI, certificate verification, and Host.

##### Why now

Resolving safely and then reconnecting by hostname would reopen DNS-rebinding/TOCTOU risk.

##### Files/modules

- `lib/pumble_automation/connections/safe_http.ex`
- `safe_http/transport.ex`
- `test/support/http_test_server.ex`
- `test/pumble_automation/connections/safe_http_transport_test.exs`

##### Changes

- Use Mint directly or a proven adapter that accepts IP tuple plus original hostname.
- Open TLS connection to selected validated IP with `hostname`/SNI and peer verification against original host; set correct Host header.
- Do not re-resolve inside the HTTP client.
- Stream request and response; cap response headers/body, duration, and decompressed bytes. Prefer `Accept-Encoding: identity` and reject unexpected compressed bodies unless a bounded decoder is implemented.
- Close connection after request initially; do not add complex pools until measured need.
- Implement cancellation/timeouts and return phase-aware transport errors, including whether request bytes may have been written.

##### Invariants

- Socket destination is one validated IP.
- Certificate is verified for original hostname.
- No automatic proxy or redirect exists.
- Memory use is bounded.

##### Failure behavior

- TLS/hostname mismatch fails closed.
- Timeout reports whether outcome may be ambiguous.
- Oversize closes connection and returns permanent/limit error.

##### Security considerations

- Never disable certificate verification; never fall back to hostname connect after pinned-IP failure.

##### Tests

- Local public-address harness or injectable connector tests for destination pinning, SNI/Host, timeout before/after write, chunked oversize, unexpected compression, TLS failure, IPv6.

##### Verification

- `mix test test/pumble_automation/connections/safe_http_transport_test.exs`

##### Completion gate

- A test proves DNS answer can change after validation without changing socket destination.
- TLS identity remains hostname-based.
- Response caps work during streaming.

##### Dependencies

`P10-T01`, `P1-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P10-T03 — Implement HTTP action request builder

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Render an approved HTTP node into a bounded request using connection policy and secret references.

##### Why now

Transport must receive a complete safe request, not arbitrary workflow maps.

##### Files/modules

- `lib/pumble_automation/executions/nodes/http_request.ex`
- `lib/pumble_automation/connections/resolver.ex`
- `test/**/http_request_builder_test.exs`

##### Changes

- Support approved methods, path/URL, query parameters, fixed/template headers, and body modes JSON/text/form only as contracted.
- Combine connection base origin/prefix and node path without origin escape.
- Render normal templates from execution context and resolve secret placeholders separately at the last moment.
- Block sensitive/hop-by-hop headers and cap count/name/value sizes.
- Assign content type explicitly and compute bounded body bytes before network.
- Produce redacted request summary and stable effect key/idempotency header where user/API configuration supports it.

##### Invariants

- Secret values never enter execution context or rendered diagnostic object.
- Final URI passes policy after rendering.
- Request is fully bounded before write.

##### Failure behavior

- Missing secret/path/type/size is permanent and no connection occurs.
- A templated host change must pass full policy and connection restrictions.

##### Security considerations

- Do not allow templates in scheme/credentials; either disallow host templates or require complete revalidation and connection policy.

##### Tests

- Method/body combinations.
- query encoding.
- JSON escaping.
- header blocklist.
- secret redaction.
- base-path escape.
- size boundaries.
- dry-run.

##### Verification

- `mix test test/pumble_automation/executions/nodes/http_request_builder_test.exs`

##### Completion gate

- All contracted request forms build deterministically.
- Unsafe headers/URLs never reach transport.
- Secret plaintext lifetime is restricted.

##### Dependencies

`P10-T02`, `P9-T02`, `P5-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P10-T04 — Implement redirect, response, extraction, and retry semantics

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Complete HTTP node behavior with manually validated redirects, bounded response capture, typed extraction, and honest effect guarantees.

##### Why now

The node is not production-safe until every response and failure window has defined behavior.

##### Files/modules

- `lib/pumble_automation/executions/nodes/http_request.ex`
- `lib/pumble_automation/connections/safe_http.ex`
- `lib/pumble_automation/workflows/http_extraction.ex`
- `test/**/http_request_node_test.exs`

##### Changes

- Handle at most three redirects and only for approved status codes; parse relative Location against current URL, then repeat URL/DNS/IP policy and strip credentials on origin change.
- Define whether method/body changes on 301/302/303; prefer explicit conservative behavior and preserve on 307/308.
- Accept configured success status ranges; capture selected safe headers and bounded body.
- Support response extraction from JSON using the same bounded path grammar; no JSONPath engine unless justified.
- Classify methods: GET/HEAD generally retryable before/after known no-response; writes retry automatically only with explicit remote idempotency key/header contract or proven idempotence.
- On timeout after possible write without idempotency, return uncertain.
- Persist only sanitized excerpts/hashes and extracted values.

##### Invariants

- Every redirect target is independently validated/pinned.
- Authorization/secrets never leak across origin.
- Response extraction cannot exceed context limits.

##### Failure behavior

- Malformed redirect/JSON/extraction is permanent or configured branchable result; ambiguous writes pause uncertain; retry exhaustion fails explicitly.

##### Security considerations

- Reject Set-Cookie persistence and do not maintain a cookie jar; block response header values from becoming outbound auth automatically.

##### Tests

- Redirect to private IP.
- DNS rebind on redirect.
- cross-origin secret stripping.
- 303/307 behavior.
- status range.
- JSON extraction.
- body cap.
- GET retry.
- POST with/without idempotency timeout.

##### Verification

- `mix test test/pumble_automation/executions/nodes/http_request_node_test.exs --trace`

##### Completion gate

- All redirect and failure windows have tests.
- No unsafe automatic write retry.
- Sanitized outputs support downstream steps.

##### Dependencies

`P10-T03`, `P7-T08`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P10-T05 — Complete adversarial HTTP security certification

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove the generic HTTP boundary against realistic SSRF, rebinding, size, timeout, redirect, and leakage attacks.

##### Why now

Unit tests of individual helpers are insufficient for the highest-risk feature.

##### Files/modules

- `test/security/http_action_adversarial_test.exs`
- `test/support/dns_resolver_fake.ex`
- `test/support/http_test_server.ex`
- `docs/security/http_action_review.md`

##### Changes

- Build an end-to-end harness with controllable DNS answers, IPv4/IPv6 servers, redirects, slow reads/writes, huge/chunked bodies, compressed bombs, and TLS names.
- Test loopback/private/link-local/metadata, mixed DNS, rebinding between validation/connect, redirect rebinding, Host/SNI, auth stripping, CRLF headers, path confusion, timeout ambiguity, and concurrent cancellation.
- Capture logs and stored execution rows to assert secret/body redaction.
- Run static security review focused on Mint usage and certificate options.
- Document residual risks and operational egress controls as defense in depth, not correctness dependency.

##### Invariants

- Security tests are deterministic and internet-independent.
- A blocked case opens no socket to the prohibited target.
- Residual risks are explicit.

##### Failure behavior

- Any unexplained connection to blocked space or secret leak is release-blocking.

##### Security considerations

- This task is itself a security gate; do not downgrade failures to warnings.

##### Tests

- Full adversarial suite and leak assertions.
- Optional container/network namespace test to prove destination addresses.

##### Verification

- `mix test test/security/http_action_adversarial_test.exs --trace`
- `mix sobelow --config`
- secret-pattern scan

##### Completion gate

- All mandated SSRF scenarios pass.
- DNS pinning is observed end to end.
- No secret appears in persisted/logged diagnostics.

##### Dependencies

`P10-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P11 — Durable delays, schedules, and approvals

#### P11-T01 — Implement durable delay node

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Pause an execution until a database-backed scheduled job resumes it after a bounded duration.

##### Why now

Delays must survive process death and deployment.

##### Files/modules

- `lib/pumble_automation/executions/nodes/delay.ex`
- `lib/pumble_automation/executions/engine.ex`
- `workers/advance_execution_worker.ex`
- `test/**/delay_node_test.exs`

##### Changes

- Resolve fixed/template duration validated within 1 second to 365 days or approved limits.
- Finalize the step to `WAITING` with `resume_at` and insert an Oban job scheduled for that timestamp in the same transaction.
- On wake, lock and verify execution/step/generation; early jobs reschedule, late jobs continue once.
- Cancellation/deactivation/uninstall behavior follows engine semantics.
- Do not use Process.sleep or long-lived timers.

##### Invariants

- Wait state and scheduled job commit together.
- Duplicate wake jobs resume at most once.
- Running execution remains bound to original version.

##### Failure behavior

- Missing job is repaired by reconciliation; invalid/overflow duration is permanent; uninstalled execution cancels before next effect.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Restart/deploy simulation.
- duplicate/early/late wake.
- job insertion rollback.
- 365-day boundary.
- cancel while waiting.

##### Verification

- `mix test test/pumble_automation/executions/nodes/delay_node_test.exs`

##### Completion gate

- Delay survives application restart in integration test.
- Only one next step becomes runnable.
- No volatile timer is authoritative.

##### Dependencies

`P7-T09`, `P9-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P11-T02 — Implement schedule calculator

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Compute deterministic next UTC instants for the approved once/interval/daily/weekly schedule types.

##### Why now

Schedule correctness must be pure and proven before dispatch machinery.

##### Files/modules

- `lib/pumble_automation/workflows/schedule_calculator.ex`
- `test/pumble_automation/workflows/schedule_calculator_test.exs`

##### Changes

- Use IANA timezone IDs through tzdata.
- Define interval schedules from prior scheduled instant, not worker completion, to prevent drift.
- Define daily/weekly local-time conversion with explicit DST gap/overlap policy from Section 23.
- Return next instant after an exclusive reference, or terminal for one-time completion.
- Bound minimum interval and next calculation horizon.

##### Invariants

- Same config/reference/tzdata version yields same result.
- UTC storage only.
- No server local timezone dependence.

##### Failure behavior

- Unknown timezone/invalid local time config is activation error; runtime tzdata failure pauses schedule and alerts.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- All schedule types.
- month/year boundaries.
- leap day.
- DST spring gap and fall overlap for multiple zones.
- minimum interval.
- no drift.

##### Verification

- `mix test test/pumble_automation/workflows/schedule_calculator_test.exs`

##### Completion gate

- DST policy is encoded in tests and docs.
- Calculator has no Repo/clock dependence beyond injected reference.

##### Dependencies

`P6-T02`, `P1-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P11-T03 — Implement due-schedule dispatcher

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Claim due schedules safely, create one execution per occurrence, and advance next run atomically.

##### Why now

User schedules require durable dispatch independent of web traffic.

##### Files/modules

- `lib/pumble_automation/executions/workers/schedule_dispatcher_worker.ex`
- `lib/pumble_automation/workflows/schedule.ex`
- `test/**/schedule_dispatcher_test.exs`

##### Changes

- Run a frequent system Oban job that selects a bounded batch where `enabled` and `next_run_at <= now`, using `FOR UPDATE SKIP LOCKED`.
- For each schedule, derive occurrence key from schedule ID + scheduled instant, create execution/initial job idempotently, update last/next run, and audit failures as needed in one transaction.
- Define misfire policy: process one most-recent or every missed occurrence up to a small cap; use the product contract's explicit choice.
- Reinsert/ensure dispatcher continuity without relying on volatile timers.
- Respect installation, workflow, and workspace concurrency status.

##### Invariants

- Two dispatchers cannot create duplicate occurrence executions.
- Next run advances from scheduled instant.
- Disabled/uninstalled schedules do not dispatch.

##### Failure behavior

- Partial batch failure affects only locked schedule transaction; repeated dispatcher converges.
- Excess misfires are summarized/skipped according to policy.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Two-dispatcher race.
- restart gap/misfires.
- job insert rollback.
- disable race.
- DST occurrence.
- one-time completion.

##### Verification

- `mix test test/pumble_automation/executions/workers/schedule_dispatcher_test.exs --trace`

##### Completion gate

- Each occurrence key creates at most one execution.
- Dispatcher resumes after restart.
- Misfire behavior is explicit and bounded.

##### Dependencies

`P11-T02`, `P7-T03`, `P2-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P11-T04 — Implement schedule edit, activation, and deactivation semantics

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Make schedule changes predictable across immutable workflow versions.

##### Why now

Users must know whether editing changes an already scheduled occurrence.

##### Files/modules

- `lib/pumble_automation/workflows/activation.ex`
- `schedule.ex`
- `test/pumble_automation/workflows/schedule_lifecycle_test.exs`

##### Changes

- Activation creates/replaces the schedule projection for the new immutable version and computes first `next_run_at` from activation time/config.
- Editing a draft changes nothing until activation.
- New activation disables old schedule and creates/updates new projection atomically; define whether an occurrence already transactionally claimed may still run.
- Deactivation prevents unclaimed future occurrences.
- Reactivation recalculates from reactivation time unless contract explicitly supports catch-up.
- Audit timezone/config changes.

##### Invariants

- Running executions keep old version.
- Only one enabled schedule projection per workflow trigger.
- No silent catch-up beyond misfire policy.

##### Failure behavior

- Concurrent activation/dispatcher resolves by row locks; an occurrence committed before deactivation may run and is documented.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Activation/dispatch race.
- draft edit no effect.
- timezone change.
- deactivate/reactivate.
- old execution version.

##### Verification

- `mix test test/pumble_automation/workflows/schedule_lifecycle_test.exs`

##### Completion gate

- Schedule lifecycle matches documented transaction boundary.
- No duplicate enabled projection.
- User-facing next run is correct.

##### Dependencies

`P11-T03`, `P6-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P11-T05 — Implement approval request and Pumble presentation

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Create a durable approval record, send a constrained Pumble approval message, and pause execution.

##### Why now

Approval is a first-class wait state, not an in-memory interaction.

##### Files/modules

- `lib/pumble_automation/executions/nodes/approval.ex`
- `lib/pumble_automation/pumble/blocks.ex`
- `lib/pumble_automation/executions/approval_service.ex`
- `test/**/approval_request_test.exs`

##### Changes

- Validate allowed approvers as explicit Pumble user IDs or approved role/group selection supported by product evidence.
- Generate opaque public approval ID and high-entropy action token stored only as hash; bind token to approval, action, workspace, and expiry.
- Inside finalization transaction create approval and timeout job, set execution awaiting approval, and prepare a send operation.
- Because sending the approval message is an external effect, use a separate effect step/attempt or outbox-like worker with the same ambiguity rules; do not hold DB transaction over network.
- Render Approve/Reject buttons with minimal opaque payload, deadline, workflow/execution summary, and no secrets.
- Store resulting message/channel IDs when confirmed.

##### Invariants

- Approval exists durably before interaction can succeed.
- Only allowed approvers may decide.
- Message-send ambiguity is handled honestly.

##### Failure behavior

- If approval message cannot be sent, bounded retry or uncertainty/failure occurs and execution does not wait invisibly forever.
- Timeout still has a durable job.

##### Security considerations

- Do not trust user ID from button payload alone; use the verified callback actor and approval tenant.

##### Tests

- Authorized/unauthorized setup.
- token hash.
- message send statuses/timeout.
- timeout job transaction.
- uninstall/cancel before send.
- redacted blocks.

##### Verification

- `mix test test/pumble_automation/executions/approval_request_test.exs`

##### Completion gate

- Execution enters awaiting state only with recoverable approval delivery state.
- Opaque interaction data cannot authorize another approval.
- Timeout is durable.

##### Dependencies

`P11-T01`, `P9-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P11-T06 — Implement approval decision and race handling

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Atomically accept one authorized approve/reject decision and resume the correct compiled branch.

##### Why now

Duplicate clicks, multiple approvers, timeouts, and restarts must converge.

##### Files/modules

- `lib/pumble_automation/executions/approval_service.ex`
- `lib/pumble_automation_web/controllers/pumble_callback_controller.ex`
- `test/**/approval_decision_test.exs`

##### Changes

- Verify signed Pumble callback, resolve installation, approval public ID, token hash, action, callback actor, expiry, and allowed-approver rule.
- Lock approval/execution/step; if pending, persist decision, finalize approval step outcome, enqueue next branch job, and audit in one transaction.
- Return success/no-op for duplicate same decision according to protocol UX; conflicting/stale decision returns safe message.
- Optionally update the Pumble message to final state as a separate best-effort effect that cannot change decision.
- Ensure decision path works after application restart.

##### Invariants

- Exactly one terminal approval decision wins.
- Decision actor comes from verified callback.
- Execution follows only compiled approve/reject edge.

##### Failure behavior

- DB failure nacks/does not claim success; message-update failure does not revert a committed decision and is observable.

##### Security considerations

- Use constant-time token-hash check and do not reveal whether a guessed approval ID exists across tenants.

##### Tests

- Two approvers race.
- same click twice.
- approve vs reject.
- unauthorized actor.
- expired/cancelled/uninstalled.
- restart before decision.
- message update failure.

##### Verification

- `mix test test/pumble_automation/executions/approval_decision_test.exs --trace`

##### Completion gate

- Concurrent decisions produce one winner and one safe stale result.
- Resume job commits with decision.
- No spoofed actor can decide.

##### Dependencies

`P11-T05`, `P4-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P11-T07 — Implement approval timeout, cancellation, and audit

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Resolve pending approvals at deadline and handle workflow/execution lifecycle without stranded waits.

##### Why now

A durable approval needs complete terminal semantics.

##### Files/modules

- `lib/pumble_automation/executions/workers/approval_timeout_worker.ex`
- `approval_service.ex`
- `test/**/approval_timeout_test.exs`

##### Changes

- Timeout worker locks approval and execution; if pending and deadline reached, choose compiled timeout branch or fail/stop according to node config, then enqueue next work atomically.
- Early timeout jobs reschedule; duplicate jobs no-op.
- Cancellation/uninstall marks pending approval cancelled and invalidates token; later clicks return stale message.
- Reconciliation repairs missing timeout jobs.
- Audit request, decision, timeout, cancellation, and rejected unauthorized attempts at an appropriate rate.

##### Invariants

- Approval cannot remain pending past deadline without a detectable repair condition.
- Only one terminal outcome.
- Cancelled token never resumes execution.

##### Failure behavior

- Clock/database issues leave pending state and alert; do not guess timeout early.
- Audit flooding is bounded.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Early/late/duplicate timeout.
- decision-timeout race.
- cancel/uninstall.
- missing job repair.
- timeout branch/terminal failure.

##### Verification

- `mix test test/pumble_automation/executions/approval_timeout_test.exs --trace`

##### Completion gate

- Timeout race is deterministic.
- No stranded approval after reconciliation.
- All terminal causes are visible in history.

##### Dependencies

`P11-T06`, `P7-T09`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P12 — Operational LiveView product UI

#### P12-T01 — Build application shell, design tokens, and onboarding

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide a polished, coherent, accessible UI foundation and guide a workspace from sign-in to first workflow.

##### Why now

A consistent shell prevents every LiveView from inventing layout, permissions, and error handling.

##### Files/modules

- `assets/css/app.css`
- `assets/js/app.js`
- `lib/pumble_automation_web/components/**`
- `live/onboarding_live.ex`
- `router.ex`
- `test/**/onboarding_live_test.exs`

##### Changes

- Create a restrained design system: spacing, type scale, surfaces, borders, statuses, focus states, buttons, forms, tables, cards, banners, empty/loading/error states.
- Build authenticated shell with workspace identity, role, primary navigation, connection status, and sign-out.
- Onboarding shows installation/scope status, supported capabilities, first-workflow action, and Pumble Home/setup state.
- Use server-rendered/LiveView components first; add JS hooks only for measured interaction gaps.
- Define responsive behavior from desktop to narrow viewport and dark-mode policy only if intentionally supported.

##### Invariants

- All protected pages use the authenticated tenant scope.
- Status colors are not the sole signal.
- No secret or token is rendered.

##### Failure behavior

- Missing installation/session shows a safe recovery screen; LiveView errors do not expose stack traces in production.

##### Security considerations

- Use escaped Phoenix templates; no raw user HTML; apply CSP-compatible assets and no inline secret-bearing scripts.

##### Tests

- Onboarding states: uninstalled, scope-degraded, installed/no workflows, installed/active.
- role/navigation tests.
- component snapshot/HTML semantics where useful.

##### Verification

- `mix test test/pumble_automation_web/live/onboarding_live_test.exs`
- `mix assets.build`

##### Completion gate

- A new authorized user can understand status and reach workflow creation.
- Shared components cover all base states.
- Keyboard focus is visible.

##### Dependencies

`P3-T06`, `P6-T06`, `P2-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P12-T02 — Implement workflow list and creation flow

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Let authorized members discover, filter, create, duplicate, deactivate, and inspect workflows safely.

##### Why now

The editor needs a stable entry point and lifecycle controls.

##### Files/modules

- `lib/pumble_automation_web/live/workflow_live/index.ex`
- `new.ex or modal component`
- `components/workflow_components.ex`
- `test/**/workflow_index_live_test.exs`

##### Changes

- List name, status, active version, trigger summary, last execution, validation state, updated actor/time, and next schedule.
- Support search/status filter and pagination without loading definitions.
- Create from blank or a small set of first-party templates encoded through the same AST constructors; no hidden special execution path.
- Duplicate as a new draft with new workflow/node IDs.
- Require confirmations for deactivate/delete-draft; surface running execution implications.
- Apply owner/editor/viewer policy to controls.

##### Invariants

- Lists are tenant-scoped and query-bounded.
- Templates produce ordinary editable definitions.
- Duplicate does not share node identity/version rows.

##### Failure behavior

- Conflicts/authorization show safe feedback and preserve form state.
- Delete blocked by active/running constraints follows documented behavior.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Role/cross-tenant.
- empty/pagination/filter.
- create/duplicate IDs.
- deactivate conflict.
- query-count test.

##### Verification

- `mix test test/pumble_automation_web/live/workflow_live/index_test.exs`

##### Completion gate

- An editor can create and find a draft.
- Viewer controls are absent/denied server-side.
- No N+1 list query.

##### Dependencies

`P12-T01`, `P5-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P12-T03 — Implement nested outline workflow editor

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide a reliable non-canvas editor for trigger and ordered branch-aware steps.

##### Why now

Workflow semantics should be usable before any optional visual canvas.

##### Files/modules

- `lib/pumble_automation_web/live/workflow_live/edit.ex`
- `components/editor_components.ex`
- `assets/js/hooks/reorder.js only if needed`
- `test/**/workflow_editor_live_test.exs`

##### Changes

- Render trigger card and ordered step cards with nesting/branch labels.
- Use P5 editing primitives for add before/after, delete, reorder within sequence, and branch insertion.
- Show stable step numbers for display but use node IDs for identity.
- Persist with draft revision; debounce or explicit save with clear saved/saving/conflict states.
- On revision conflict, reload/compare and never silently overwrite.
- Provide keyboard move buttons in addition to drag; drag hook sends only source/target IDs and branch path.
- Warn before deleting a subtree.

##### Invariants

- LiveView never mutates raw JSON directly.
- Every edit preserves stable IDs and limits.
- Server validates every client event.

##### Failure behavior

- Stale revision keeps local intent visible and prompts reload/reapply; malformed events are ignored/audited without crash.

##### Security considerations

- Never trust DOM positions or hidden tenant IDs; authorize workflow and validate IDs on every event.

##### Tests

- Every edit operation.
- two browser sessions conflict.
- limit/depth feedback.
- keyboard reorder.
- malicious event payload.
- reconnect state.

##### Verification

- `mix test test/pumble_automation_web/live/workflow_live/editor_test.exs`

##### Completion gate

- A complex nested workflow can be built without manual JSON.
- Concurrent edits do not lose data silently.
- Editor is usable by keyboard.

##### Dependencies

`P12-T02`, `P5-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P12-T04 — Implement node configuration forms

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Expose typed, node-specific forms for all contracted triggers, logic, Pumble actions, HTTP, delay, schedule, approval, and stop nodes.

##### Why now

The outline is not usable if configuration remains raw JSON.

##### Files/modules

- `lib/pumble_automation_web/live/workflow_live/node_form_component.ex`
- `node_forms/*.ex`
- `components/form_components.ex`
- `test/**/node_forms_test.exs`

##### Changes

- Build forms from the same embedded schemas/changesets used by AST decode.
- Show only supported fields, units, limits, reference pickers, connection/secret metadata, and scope requirements.
- Provide a path/template helper listing data available at that node/branch; insert references without inventing invalid paths.
- Secrets are selectable by name but never readable.
- HTTP form explains retry/idempotency and blocked targets; approval form explains allowed approvers/timeout.
- Schedule form previews next occurrences and DST policy.
- Persist only through editor primitives.

##### Invariants

- UI cannot create configuration the validator/runtime does not understand.
- Secret values never reach LiveView assigns.
- Reference suggestions are branch-correct.

##### Failure behavior

- Invalid input remains in form with stable issue codes/messages; missing dependency links to management page.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- One valid/invalid form per node.
- secret write-only.
- reference availability by branch.
- schedule preview/DST.
- HTTP header blocklist.

##### Verification

- `mix test test/pumble_automation_web/live/workflow_live/node_forms_test.exs`

##### Completion gate

- Every v1 node is configurable without JSON.
- Form output round-trips through AST.
- Limits and security warnings are visible.

##### Dependencies

`P12-T03`, `P6-T02`, `P5-T08`, `P11-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P12-T05 — Implement validation, dry-run, activation, and version controls

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Let users prove a draft, preview it, activate it, inspect versions, and roll back deliberately.

##### Why now

The product must make the compiler boundary visible and safe.

##### Files/modules

- `lib/pumble_automation_web/live/workflow_live/show.ex`
- `validation_component.ex`
- `version_component.ex`
- `test/**/workflow_activation_live_test.exs`

##### Changes

- Run validation on demand and optionally after save; group issues by node and focus the selected card.
- Build dry-run form with sanitized sample trigger data and render ordered trace from P9.
- Require explicit confirmation for live test and activation, showing required scopes, connections, warnings, and changed trigger/schedule behavior.
- Use expected draft revision during activation.
- Show immutable version history, hashes/creator/time, diff summary between source definitions, and reactivation action.
- Deactivate separately from canceling executions.

##### Invariants

- UI cannot bypass activation service.
- Warnings are not shown as proof of success.
- Live test is clearly distinct from dry-run.

##### Failure behavior

- Activation conflict or dependency loss leaves old active version intact and displays exact safe issues.

##### Security considerations

- Owner/editor authorization is enforced server-side; sample payload display is escaped and not retained unless explicitly saved.

##### Tests

- Validation navigation.
- dry-run no network.
- live-test confirmation/role.
- activation success/rollback.
- version reactivation.
- concurrent activation.

##### Verification

- `mix test test/pumble_automation_web/live/workflow_live/activation_test.exs`

##### Completion gate

- An editor can move from draft to proved active version.
- Failure never partially activates.
- Version history and rollback are understandable.

##### Dependencies

`P12-T04`, `P9-T06`, `P6-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P12-T06 — Implement execution history and operator controls

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Expose searchable execution timelines, sanitized step attempts, retries, waits, approvals, failures, cancellation, and uncertainty resolution.

##### Why now

Durability is useful only when operators can diagnose and safely act.

##### Files/modules

- `lib/pumble_automation_web/live/execution_live/index.ex`
- `show.ex`
- `components/execution_components.ex`
- `test/**/execution_live_test.exs`

##### Changes

- List by workflow/status/time with cursor pagination and summary-only queries.
- Timeline shows trigger summary, version, node, status, attempts, branch reason, wait/approval timestamps, provider IDs, sanitized output, and terminal reason.
- Offer cancel where allowed, safe retry only for explicitly retryable failed steps if the engine supports it, and owner-only uncertainty resolution from P8.
- Require confirmation and display duplicate-risk language for deliberate uncertain retry.
- Link to workflow version, not mutable draft.
- Provide copyable correlation/execution ID without private payload.

##### Invariants

- UI never edits execution rows directly.
- Secrets/raw message content are not shown by default.
- Cross-tenant IDs return not found.

##### Failure behavior

- Stale action gets conflict and refreshed state; failed best-effort Pumble message update does not hide committed state.

##### Security considerations

- Use allowlisted sanitized fields; never render arbitrary stored maps with raw inspection.

##### Tests

- Status/timeline rendering.
- pagination/query count.
- role controls.
- cancel race.
- uncertainty actions.
- redaction/cross-tenant.

##### Verification

- `mix test test/pumble_automation_web/live/execution_live/**`

##### Completion gate

- An operator can explain every acceptance scenario from history.
- Dangerous controls are role-gated/audited.
- Large histories remain paginated.

##### Dependencies

`P12-T05`, `P7-T09`, `P11-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P12-T07 — Implement secrets, connections, members, audit, and settings UI

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide complete tenant administration without exposing sensitive values.

##### Why now

Release requires operational self-service beyond the workflow editor.

##### Files/modules

- `lib/pumble_automation_web/live/secret_live/**`
- `connection_live/**`
- `member_live/**`
- `audit_live/**`
- `settings_live/**`
- `test/**/admin_live_test.exs`

##### Changes

- Secrets: create/replace/delete metadata with write-only value field and dependency display.
- Connections: CRUD, safe test request, enabled state, referenced workflows, and last safe outcome.
- Members: list Pumble identity, local role, invite/sign-in guidance, role changes, prevent last-owner removal.
- Audit: filter/paginate action, actor, resource, time, and safe metadata.
- Settings: installation/scopes/status, retention summary, webhook token rotation, uninstall/data deletion guidance, manifest/help links.
- All destructive actions use explicit confirmations and policies.

##### Invariants

- No secret value is ever prefilled/read back.
- At least one owner remains.
- Audit records are append-only through UI.

##### Failure behavior

- Dependency conflicts and stale role changes return safe errors; connection test cannot bypass SafeHttp.

##### Security considerations

- Use password inputs with autocomplete policy, clear assigns after submit, and never send decrypted values to browser.

##### Tests

- Write-only secret DOM test.
- role matrix/last owner.
- connection SSRF block.
- audit pagination.
- webhook rotation.
- cross-tenant.

##### Verification

- `mix test test/pumble_automation_web/live/secret_live test/pumble_automation_web/live/connection_live test/pumble_automation_web/live/member_live test/pumble_automation_web/live/audit_live`

##### Completion gate

- Owners can administer all required resources.
- Editors/viewers see only allowed controls.
- Sensitive fields never appear in rendered HTML.

##### Dependencies

`P12-T06`, `P5-T08`, `P5-T07`, `P3-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P12-T08 — Complete accessibility, responsive, and browser-state QA

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Verify the operational UI works with keyboard, screen readers, narrow screens, reconnects, and realistic error/loading states.

##### Why now

A crisp UI is a release requirement, not final cosmetic paint.

##### Files/modules

- `assets/css/app.css`
- `assets/js/app.js`
- `test/browser/**`
- `docs/product/ui_acceptance.md`

##### Changes

- Audit semantic headings, landmarks, labels, descriptions, error associations, focus management, modal behavior, table alternatives, contrast, reduced motion, and keyboard order.
- Test at representative desktop/tablet/mobile widths.
- Exercise LiveView disconnect/reconnect during edit, activation, execution update, and secret submit.
- Add skeleton/loading/empty/error states without layout jumps.
- Run visual review on all statuses and long names/messages.
- Keep JS hooks small and destroy/reconnect-safe.

##### Invariants

- All core tasks are keyboard-operable.
- Server remains source of truth after reconnect.
- Sensitive fields are cleared after submit/reconnect.

##### Failure behavior

- If a drag interaction fails, keyboard controls retain full functionality.
- Offline/reconnect never duplicates mutations without idempotency/revision checks.

##### Security considerations

- CSP and browser console must show no unsafe inline-script or mixed-content violations.

##### Tests

- Automated accessibility scan if approved.
- browser keyboard flows.
- viewport matrix.
- reconnect/conflict.
- long/translated-like text stress.

##### Verification

- `mix test test/browser/** or approved browser runner`
- `mix assets.build`
- manual accessibility checklist

##### Completion gate

- No critical accessibility issue.
- Core workflow works at narrow viewport.
- Reconnect cannot duplicate destructive action or reveal secret.

##### Dependencies

`P12-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P13 — Security, tenancy, limits, loops, and retention

#### P13-T01 — Enforce tenant scope across all contexts and jobs

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove every tenant-owned read, mutation, job, callback, and operator action resolves through installation scope.

##### Why now

Tenant isolation is a hard invariant and cannot rely on UI filtering.

##### Files/modules

- `lib/pumble_automation/scope.ex`
- `all context modules`
- `all workers`
- `test/support/tenant_assertions.ex`
- `test/security/tenant_isolation_test.exs`

##### Changes

- Inventory every public context function and worker perform callback.
- Require scope or installation ID derived from trusted job row, then include tenant predicate on every query/update.
- Validate parent-child tenant consistency before inserts.
- Make unsafe Repo helpers private; prohibit web-layer Repo access through Credo/custom check if practical.
- For jobs, load row by both ID and installation ID from args, then verify related version/workflow tenant.
- Return not-found for cross-tenant resource IDs.

##### Invariants

- No tenant-owned object is accessible by global ID alone.
- Job args cannot redirect work to another tenant.
- Admin/debug endpoints follow the same rule.

##### Failure behavior

- Mismatched tenant returns no data/change and emits bounded security telemetry.

##### Security considerations

- Treat any failure as release-blocking high severity.

##### Tests

- Automated matrix attempts workspace A IDs under B for every context/route/LiveView/job.
- malicious job arg tests.
- foreign-key mismatch tests.

##### Verification

- `mix test test/security/tenant_isolation_test.exs --trace`
- grep/custom lint for Repo use in web modules

##### Completion gate

- Isolation matrix covers every tenant resource.
- Zero cross-tenant disclosure/mutation.
- No unscoped public getter remains.

##### Dependencies

`P12-T07`, `P7-T09`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P13-T02 — Enforce resource and rate limits

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Apply conservative limits at validation, ingress, persistence, execution, and UI boundaries.

##### Why now

Unbounded workflows or callbacks can exhaust the service even without malicious code.

##### Files/modules

- `lib/pumble_automation/limits.ex`
- `ingress/rate_limiter.ex`
- `workflows/validator.ex`
- `executions/**`
- `config/runtime.exs`
- `test/security/limits_test.exs`

##### Changes

- Centralize defaults from Section 31 with typed runtime overrides and safe upper bounds.
- Enforce workflow/node/depth/template/context/HTTP/delay/lifetime/retry/workspace concurrency/schedule/history limits in owner modules.
- Implement simple database-backed or ETS-plus-safe-fallback rate limits for callback failures, generic webhooks, manual runs, and expensive UI actions; choose storage based on multi-node deployment assumptions.
- Use PostgreSQL/Oban queue controls for durable work; do not introduce Redis.
- Return clear 413/422/429 responses and retry metadata where appropriate.
- Track limit hits by tenant without logging payload.

##### Invariants

- Limits cannot be bypassed through alternate API/UI paths.
- Runtime overrides cannot exceed hard safety caps without ADR.
- Rate limiter failure defaults safely for internet-facing endpoints.

##### Failure behavior

- Over-limit input is rejected before expensive work; overload does not create partial execution.

##### Security considerations

- Use tenant and source dimensions without trusting spoofable forwarding headers; configure trusted proxies explicitly.

##### Tests

- Every boundary at limit and limit+1.
- concurrent webhook/manual rate.
- context growth across steps.
- schedule/workflow count race.
- limiter restart behavior.

##### Verification

- `mix test test/security/limits_test.exs`

##### Completion gate

- All Section 31 limits have one implementation owner and test.
- No unbounded collection/body/context path remains.
- Rate behavior is documented.

##### Dependencies

`P13-T01`, `P8-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P13-T03 — Implement workflow loop and lineage protection

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prevent workflows from recursively amplifying their own Pumble effects or nested manual/webhook triggers.

##### Why now

Pumble actions can create Pumble events and uncontrolled recursion is an operational/security risk.

##### Files/modules

- `lib/pumble_automation/executions/lineage.ex`
- `lib/pumble_automation/ingress/trigger_matcher.ex`
- `lib/pumble_automation/pumble/normalizer.ex`
- `test/security/loop_prevention_test.exs`

##### Changes

- Default event triggers ignore messages authored by the installation bot when proven via bot user ID.
- Offer an explicit advanced include-bot setting only if source/probe supports author identity and warns about loops.
- Propagate internal lineage for browser/manual/internal schedule starts and any controllable webhook chaining.
- Set maximum lineage depth three and maximum descendant executions per root/event window.
- Use provider metadata/correlation only if live-proven; otherwise do not claim causal suppression.
- Detect repeated workflow/version/resource patterns and pause/fail with loop classification.

##### Invariants

- Self-origin filtering is tenant-specific.
- Lineage cannot be supplied/forged by an external Pumble payload unless cryptographically bound.
- Limits stop amplification.

##### Failure behavior

- When causality is unavailable, conservative bot filtering and resource limits apply; suspected loops stop with diagnostic rather than run indefinitely.

##### Security considerations

- Loop events are security/abuse telemetry but avoid message-content logging.

##### Tests

- Own-bot message.
- human message.
- include-bot warning/limit.
- A→B→A lineage.
- forged metadata.
- depth/descendant cap.
- duplicate event interaction.

##### Verification

- `mix test test/security/loop_prevention_test.exs`

##### Completion gate

- Representative self-trigger loop terminates before repeated effects beyond documented bound.
- No unsupported metadata assumption remains.

##### Dependencies

`P13-T02`, `P9-T04`, `P8-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P13-T04 — Implement retention and tenant purge

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Delete ingress, execution detail, audit, session, OAuth state, and uninstalled-tenant data according to explicit policy.

##### Why now

Durable history must not become indefinite privacy and database risk.

##### Files/modules

- `lib/pumble_automation/executions/workers/retention_worker.ex`
- `lib/pumble_automation/retention.ex`
- `priv/repo/migrations/*retention_indexes*.exs`
- `test/**/retention_test.exs`

##### Changes

- Implement default retention: raw/normalized receipt detail 30 days, execution detail 90 days, audit 365 days, expired OAuth/session rows promptly, uninstalled tenant 30-day grace.
- Retain aggregate counters only if privacy policy supports them.
- Delete in small indexed batches with continuation and tenant filters.
- Preserve rows under explicit legal/support hold only if product policy implements and documents it; otherwise do not add holds.
- Purge credentials/secrets immediately on uninstall as already defined.
- Expose retention status/last run metrics.

##### Invariants

- Purge never crosses tenant or deletes active required rows.
- Batch restart is safe.
- Retention values match user-facing privacy documents.

##### Failure behavior

- Failure retries later and alerts; partial batch is acceptable and resumable.
- FK conflicts reveal a policy bug and block release.

##### Security considerations

- Purge logs counts and tenant ID/correlation only, not deleted content.

##### Tests

- Boundary-date tests.
- cross-tenant sentinels.
- partial failure/resume.
- active/waiting execution protection.
- uninstall full purge.
- large batch query plan.

##### Verification

- `mix test test/pumble_automation/retention_test.exs`

##### Completion gate

- Every sensitive table has retention/lifecycle.
- Purge is bounded and idempotent.
- Uninstall deletion proof is queryable.

##### Dependencies

`P13-T03`, `P3-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P13-T05 — Harden browser and HTTP security

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Apply secure headers, CSRF/session protections, origin policy, upload/body restrictions, and production route controls.

##### Why now

Framework defaults require explicit production verification.

##### Files/modules

- `lib/pumble_automation_web/endpoint.ex`
- `router.ex`
- `plugs/security_headers.ex`
- `config/runtime.exs`
- `test/security/web_security_test.exs`

##### Changes

- Configure HSTS, content-security-policy, frame policy compatible with intended embedding, referrer policy, nosniff, permissions policy, secure cookies, trusted proxy/HTTPS redirect, and host allowlist.
- Keep Phoenix CSRF on browser forms/LiveView; Pumble/webhook API routes use signature/token auth and are separated from browser session routes.
- Disable debug dashboard/routes/code reloader in production.
- Filter sensitive params/headers and cap all body parsers.
- Define CORS as deny/no cross-origin API by default; add none unless product requires it.
- Prevent open redirects and unsafe external links.

##### Invariants

- Production does not expose dev tools.
- Security headers are consistent.
- API callback authentication does not disable browser CSRF globally.

##### Failure behavior

- Misconfigured proxy/host fails readiness or rejects request; it does not trust arbitrary forwarded headers.

##### Security considerations

- Document any frame-ancestor allowance required by Pumble; do not use wildcard origins.

##### Tests

- Header/cookie tests.
- CSRF positive/negative.
- host spoofing.
- open redirect.
- production route absence.
- body limits.
- CSP browser console.

##### Verification

- `mix test test/security/web_security_test.exs`
- `mix sobelow --config`

##### Completion gate

- No high-confidence Sobelow issue remains.
- Headers/cookies pass expected assertions.
- Dev/admin surfaces are absent in production.

##### Dependencies

`P13-T01`, `P12-T08`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P13-T06 — Implement audit and protected support operations

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide tamper-evident-enough append-only audit records and narrowly scoped operational actions.

##### Why now

Sensitive lifecycle, role, secret, activation, cancellation, and uncertainty changes require accountability.

##### Files/modules

- `lib/pumble_automation/audit/audit_event.ex`
- `writer.ex`
- `lib/pumble_automation_web/live/audit_live/**`
- `lib/pumble_automation/operations.ex`
- `test/**/audit_test.exs`

##### Changes

- Create/complete audit schema with installation, actor type/ID, action code, resource type/ID, correlation, timestamp, safe metadata, and optional prior-event hash only if it provides real value without key-management theater.
- Make security-sensitive business transitions insert audit in the same transaction.
- Define system actor for workers and Pumble actor for approvals.
- Create explicit owner/support operations: requeue provably safe job, run reconciliation, export sanitized diagnostics, and initiate tenant deletion.
- Do not add arbitrary code/SQL consoles or global super-admin UI.
- Rate-limit repeated denied/invalid interaction audit to avoid flood.

##### Invariants

- Audit is append-only through application API.
- Metadata allowlist excludes secrets/private full payloads.
- Support operation names are finite and authorized.

##### Failure behavior

- Audit failure rolls back security-sensitive mutation; telemetry failure does not.
- Unsupported repair instructs operator rather than enabling SQL.

##### Security considerations

- Database superusers can alter rows; do not overclaim cryptographic immutability unless external anchoring is actually implemented.

##### Tests

- Atomic audit rollback.
- actor classifications.
- metadata redaction.
- cross-tenant support action.
- append-only API.
- flood limiting.

##### Verification

- `mix ecto.migrate`
- `mix test test/pumble_automation/audit/**`

##### Completion gate

- All critical actions emit audit proof.
- No generic admin backdoor exists.
- Audit UI is tenant-scoped.

##### Dependencies

`P13-T05`, `P5-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P13-T07 — Close threat model and dependency findings

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Run a focused security review and prove every release-blocking threat has implemented mitigation and test evidence.

##### Why now

Security documents are incomplete until mapped to executable proof.

##### Files/modules

- `docs/security/threat_model.md`
- `docs/security/review_results.md`
- `IMPLEMENTATION_LEDGER.md`
- `test/security/**`

##### Changes

- Update each threat row with code owner, test name, last passing evidence, and residual risk.
- Run Sobelow, Hex audit, secret scan, Credo security-related checks, and manual review of OAuth, signature, tenant, SafeHttp, session, approval, and uninstall boundaries.
- Review dependency lockfile/transitives and licenses.
- Search for raw Repo access, dynamic atom creation, `:erlang.binary_to_term` on untrusted data, TLS verification disables, shell execution, and debug routes.
- Open concrete remediation tasks for any finding; no blanket accepted-risk label for critical/high defects.

##### Invariants

- Evidence corresponds to current HEAD.
- High/critical findings block P16 release work.
- Residual risk statements are accurate.

##### Failure behavior

- A tool failure is not a clean result; record `BLOCKED` and rerun.

##### Security considerations

- This is a release gate, not advisory.

##### Tests

- All security suites and static tools.
- manual code checklist with file/line references.
- redacted secret scan of repository and generated release config.

##### Verification

- `./scripts/verify.sh`
- `mix sobelow --config`
- `mix hex.audit`
- secret scanner command selected in P2

##### Completion gate

- Zero unresolved critical/high findings.
- Every threat has mitigation and proof or explicit non-applicability.
- Review artifact names exact commit.

##### Dependencies

`P13-T06`, `P10-T05`, `P13-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P14 — Observability, maintenance, and operations

#### P14-T01 — Implement structured, redacted logging

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Emit useful machine-readable logs with correlation while minimizing private content.

##### Why now

Operators need diagnosis across callbacks, jobs, external calls, and UI actions.

##### Files/modules

- `config/*.exs`
- `lib/pumble_automation/logging.ex`
- `lib/pumble_automation_web/telemetry.ex`
- `test/observability/logging_test.exs`

##### Changes

- Choose JSON production logger or structured metadata supported by the platform.
- Standardize request ID, Pumble provider ID, installation ID, workflow/version/execution/step/attempt/job IDs, operation, duration, status, and error code.
- Implement metadata/parameter/header filters and a redaction helper for nested diagnostics.
- Do not log raw callback bodies, message text, templates after rendering, tokens, secret values, or HTTP response bodies by default.
- Use sampled/debug diagnostic mode only if tenant-authorized and automatically expiring; prefer hashes/lengths.

##### Invariants

- Every execution log can be correlated without content.
- Redaction occurs before formatting/serialization.
- Production level is configurable without code change.

##### Failure behavior

- Logger failure cannot crash business path; redaction failure defaults to replacement, not raw output.

##### Security considerations

- Treat logs as sensitive operational data and define retention/access outside application deployment.

##### Tests

- Capture logs for OAuth, callback, Pumble action, HTTP action, approval, uncertainty, and exception; assert forbidden values absent.

##### Verification

- `mix test test/observability/logging_test.exs`
- secret-pattern scan over captured logs

##### Completion gate

- Operational IDs are present.
- Forbidden secrets/private bodies are absent.
- Log schema is documented.

##### Dependencies

`P13-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P14-T02 — Implement telemetry and metric definitions

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Measure ingress, execution, queues, actions, retries, latency, failures, limits, and tenant usage without high-cardinality explosions.

##### Why now

Production behavior cannot be validated or alerted from logs alone.

##### Files/modules

- `lib/pumble_automation_web/telemetry.ex`
- `lib/pumble_automation/telemetry.ex`
- `docs/operations/metrics.md`
- `test/observability/telemetry_test.exs`

##### Changes

- Emit Telemetry events for callback verification/class/latency, event duplicate/new, trigger match count, execution/step duration, state transition, retry, uncertainty, approval time, Pumble/HTTP status class, queue depth/age, schedule lag, reconciliation, retention, and limit hits.
- Define low-cardinality metric labels: operation/type/status/error class; do not label by workflow/execution/user IDs.
- Attach IDs to traces/log metadata, not metric dimensions.
- Use Phoenix/Ecto/Oban telemetry before adding a vendor SDK.
- Document units, meaning, and alert candidates.

##### Invariants

- Metrics contain no secret/private content.
- Event names and measurements are stable.
- Cardinality is bounded.

##### Failure behavior

- Telemetry handler failure is isolated and never breaks execution.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Event emission assertions.
- no high-cardinality metadata in metric adapter.
- duration units.
- failure-path events.

##### Verification

- `mix test test/observability/telemetry_test.exs`

##### Completion gate

- All Section 32 metrics have source events or explicit deferral.
- Metric definitions are documented and testable.
- No vendor dependency is required.

##### Dependencies

`P14-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P14-T03 — Expose queue, schedule, and readiness diagnostics

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Make durable work health observable through protected UI/operations and deployment readiness.

##### Why now

A process can be alive while jobs are stuck or schedules are late.

##### Files/modules

- `lib/pumble_automation/operations/health.ex`
- `lib/pumble_automation_web/controllers/health_controller.ex`
- `live/settings_live/operations.ex`
- `test/observability/operations_health_test.exs`

##### Changes

- Compute bounded checks for database latency, migration version, Oban availability, oldest available job age, exhausted/discarded jobs, due schedule lag, stale attempts, missing jobs, and cleanup lag.
- Keep public readiness minimal; expose detailed diagnostics only to owner/support role.
- Define readiness thresholds that indicate inability to accept durable work, not transient one-job failures.
- Provide links/IDs for affected executions without exposing tenant-global data.
- Add alert threshold recommendations.

##### Invariants

- Health queries use indexes and strict timeouts.
- Detailed diagnostics are tenant-scoped or deployment-internal.
- Liveness remains simple.

##### Failure behavior

- Diagnostic query failure returns unknown/unhealthy safely and is logged; it does not hang readiness.

##### Security considerations

- Protect detailed operational endpoints and avoid exposing job arguments.

##### Tests

- DB down, Oban unavailable, old queue, late schedule, stale attempt, healthy baseline, authorization.

##### Verification

- `mix test test/observability/operations_health_test.exs`

##### Completion gate

- Operators can distinguish web-up from durable-work-ready.
- Checks are bounded.
- Public endpoint leaks no tenant data.

##### Dependencies

`P14-T02`, `P7-T09`, `P11-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P14-T04 — Complete reconciliation and maintenance scheduling

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Run reconciliation, retention, OAuth/session cleanup, and operational integrity checks on durable schedules.

##### Why now

Maintenance cannot depend on an operator remembering commands.

##### Files/modules

- `lib/pumble_automation/executions/workers/reconciliation_worker.ex`
- `retention_worker.ex`
- `installations/cleanup_worker.ex`
- `lib/pumble_automation/maintenance.ex`
- `config/*.exs`

##### Changes

- Schedule system jobs through Oban plugins or self-rescheduling workers with singleton uniqueness.
- Use small batches, indexes, time budgets, and continuation cursors.
- Add integrity checks for active workflow/binding/version consistency, waiting job presence, pending approval timeout, orphan secret references, and uninstalled cleanup.
- Repair only approved safe anomalies; emit alert records/telemetry for others.
- Provide pause/run-once commands and document expected duration.

##### Invariants

- One maintenance job of each type runs at a time.
- Work is restart-safe.
- No repair performs uncertain external effects.

##### Failure behavior

- Job exhaustion surfaces in health/alerts; it does not silently stop forever.

##### Security considerations

- Maintenance job args contain only cursor/IDs; owner run-once actions are audited.

##### Tests

- Duplicate scheduler.
- restart midway.
- batch continuation.
- safe repair and unsafe alert.
- pause/resume.
- tenant sentinel.

##### Verification

- `mix test test/pumble_automation/maintenance_test.exs`

##### Completion gate

- Maintenance jobs are durable, singleton, bounded, and observable.
- All cleanup/reconciliation policies have a scheduler.

##### Dependencies

`P14-T03`, `P13-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P14-T05 — Write operational runbooks

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Document routine deployment, incident diagnosis, queue recovery, uncertainty, revocation, backup restore, and rollback procedures.

##### Why now

A production system is not maintainable if recovery knowledge exists only in code.

##### Files/modules

- `docs/operations/local_development.md`
- `deployment.md`
- `incidents.md`
- `queues.md`
- `uncertain_effects.md`
- `oauth_revocation.md`
- `backup_restore.md`
- `rollback.md`

##### Changes

- Use ASD-STE100-style direct instructions and exact commands after they are proven.
- Include symptom → checks → safe action → stop/escalate conditions.
- Cover database unavailable, callbacks failing signatures, 401/403 scope loss, 429/5xx surge, stuck queues, schedule lag, stale attempts, uncertain effects, uninstall, secret-key rotation, migration failure, and rollback.
- Do not instruct direct SQL mutation for ordinary recovery; read-only diagnostic SQL may be included when safe.
- Mark commands that require production owner approval.

##### Invariants

- Runbooks match implemented commands and UI.
- No command prints secrets.
- Unsafe recovery has explicit stop condition.

##### Failure behavior

- An unproven command is labelled planned and blocks runbook completion.

##### Security considerations

- Separate public support docs from internal operational detail; redact infrastructure identifiers in shared artifacts.

##### Tests

- Execute runbooks in local/staging simulations.
- Peer/manual review for clarity and missing assumptions.

##### Verification

- documentation link check
- shellcheck for scripts if created
- runbook game-day evidence

##### Completion gate

- Every operational failure class has a bounded first-response path.
- Commands were executed against non-production environment.
- No manual DB surgery is routine.

##### Dependencies

`P14-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P14-T06 — Implement privacy-safe diagnostic export

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Generate a bounded support bundle for one tenant/execution without secrets or unnecessary content.

##### Why now

Support needs evidence without asking users to expose raw credentials or private messages.

##### Files/modules

- `lib/pumble_automation/diagnostics/export.ex`
- `lib/pumble_automation_web/live/settings_live/diagnostics.ex`
- `test/observability/diagnostic_export_test.exs`

##### Changes

- Export application/version, tenant installation status, scope names, workflow/version hashes, selected execution timeline, error codes, provider IDs, queue/job IDs, timings, and configuration limits.
- Exclude tokens, secret values, raw request/response bodies, message text by default, session/OAuth hashes, encryption metadata that aids attack, and other tenants.
- Require owner action and explicit execution/time selection.
- Produce JSON/ZIP only if necessary; sign or hash bundle and expire server-side artifact quickly if stored.
- Audit export and allow user preview of included field names.

##### Invariants

- Bundle is tenant-scoped and allowlist-built.
- No decrypted secret is accessed.
- Size/time range is bounded.

##### Failure behavior

- Generation failure leaves no partial public artifact; stored temporary file is deleted by cleanup.

##### Security considerations

- Never provide a global all-tenants export.

##### Tests

- Golden export.
- forbidden-value scan.
- cross-tenant.
- size/time limits.
- temporary cleanup.
- role/audit.

##### Verification

- `mix test test/observability/diagnostic_export_test.exs`

##### Completion gate

- Support bundle passes automated secret/private-content scan.
- Owner can obtain useful evidence without database access.
- Temporary artifacts expire.

##### Dependencies

`P14-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P15 — Adversarial test completion and offline acceptance

#### P15-T01 — Complete pure-domain test suite

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove AST, compiler, expressions, templates, graph traversal, state transitions, schedules, retry, and IP policy as deterministic units.

##### Why now

Pure logic should carry the largest, fastest invariant coverage.

##### Files/modules

- `test/pumble_automation/workflows/**`
- `test/pumble_automation/executions/state_machine_test.exs`
- `test/pumble_automation/connections/ip_policy_test.exs`

##### Changes

- Review the test matrix against Sections 15–31.
- Add missing boundary, malformed, and property-based cases only where they improve invariant coverage.
- Use seeded clocks/randomness and explicit timezone fixtures.
- Ensure tests assert outputs/state, not implementation call counts unless boundary-specific.
- Remove redundant tests that add maintenance cost without distinct behavior.

##### Invariants

- Pure tests do not use Repo/network.
- Randomized failures reproduce with seed.
- Every contracted node and state has behavior proof.

##### Failure behavior

- A discovered semantic mismatch is fixed in owner module and plan ledger, not patched in test expectation.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Run pure directories repeatedly and with randomized seed.
- coverage report may guide gaps but is not acceptance by itself.

##### Verification

- `mix test test/pumble_automation/workflows test/pumble_automation/executions/state_machine_test.exs test/pumble_automation/connections/ip_policy_test.exs --seed 0`
- `mix test --seed 12345`

##### Completion gate

- No missing invariant from pure-test matrix.
- Suite is deterministic and fast.
- No test depends on internet/timezone of host.

##### Dependencies

`P13-T07`, `P11-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P15-T02 — Complete database and race test suite

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove transactional boundaries, uniqueness, tenant isolation, activation, execution, approvals, schedules, cancellation, uninstall, and retention under concurrency.

##### Why now

The hardest correctness claims are database claims.

##### Files/modules

- `test/integration/database/**`
- `test/support/barrier.ex`
- `test/support/tenant_assertions.ex`

##### Changes

- Build deterministic barriers to race two processes at lock/insert/finalize points.
- Cover every transaction from Section 20.3 and lifecycle/deletion boundaries.
- Assert final rows, Oban jobs, attempts, audit records, and absence of orphan/duplicate records.
- Run tenant sentinel checks after destructive operations.
- Avoid sleeps for synchronization; use messages/barriers and SQL locks.

##### Invariants

- Races yield one documented winner/convergent result.
- No test passes only due to timing luck.
- DB constraints are exercised.

##### Failure behavior

- Deadlocks/timeouts are surfaced and investigated; tests do not increase timeouts to mask them.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Concurrent activation, dedup, claim, finalize, approval, schedule, first owner, role, uninstall, retention, reconciliation.

##### Verification

- `mix test test/integration/database --trace`
- repeat selected race tests 20 times via script

##### Completion gate

- All race outcomes match documented semantics repeatedly.
- No orphan/job gap in asserted transitions.
- Cross-tenant sentinels survive.

##### Dependencies

`P15-T01`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P15-T03 — Complete Pumble adapter contract fixtures and fake server

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Validate callback and API behavior offline against sanitized source-derived and live-validated fixtures.

##### Why now

Normal CI must not depend on Pumble internet access.

##### Files/modules

- `priv/pumble/fixtures/**`
- `test/support/pumble_fake.ex`
- `test/contract/pumble/**`
- `docs/evidence/pumble_source_matrix.md`

##### Changes

- Create fixture provenance metadata: source guide or live probe ID/date, fields sanitized, expected classifier/normalizer/response.
- Fake server verifies exact method/path/headers/body and can emit status, timeout, malformed, large, and rate-limit responses.
- Cover all retained operations, signatures, callback classes, lifecycle, and manifest stripping.
- Update fixtures only through reviewed protocol evidence; prevent real IDs/tokens.
- Test adapter against fake in both success and failure paths.

##### Invariants

- Fixtures are evidence, not invented convenience.
- Fake defaults fail on unexpected call.
- No live credentials in repository.

##### Failure behavior

- Unknown Pumble behavior remains probe-tagged; fixture cannot promote it to fact.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Full contract suite.
- secret scan fixtures.
- manifest schema/source matrix consistency.

##### Verification

- `mix test test/contract/pumble --trace`
- secret scanner on priv/pumble/fixtures

##### Completion gate

- Every Pumble dependency has offline fixture/expectation.
- Unexpected requests fail loudly.
- Fixture provenance is documented.

##### Dependencies

`P15-T02`, `P4-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P15-T04 — Complete failure-injection and crash-window suite

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove recovery semantics around process death, job duplication, persistence, and external-effect uncertainty.

##### Why now

Happy-path integration tests cannot validate durability.

##### Files/modules

- `test/support/failure_injector.ex`
- `test/integration/failure_windows/**`
- `docs/architecture/delivery_semantics.md`

##### Changes

- Add injectable hooks at named test-only boundaries: before claim commit, after claim, before network write, after write/timeout, before finalize, after finalize before job return, before next-job insert, approval decision, schedule dispatch.
- Kill worker/test process or force DB/network failure at each boundary.
- Restart application/Oban where practical and run reconciliation.
- Assert no corruption, documented duplicate/uncertain behavior, and diagnosable history.
- Compile test hooks out or keep inaccessible in production.

##### Invariants

- Failure injection cannot be triggered in production.
- Recovery follows the same code paths as real workers.
- No test asserts impossible exactly-once.

##### Failure behavior

- If an outcome cannot be proven, expected state is uncertainty/alert, not silent retry.

##### Security considerations

- Test hooks are guarded by Mix environment and absent from release module/function surface.

##### Tests

- All adversarial cases in source prompt plus P16 restart/deploy simulations.
- repeat with duplicate jobs/two workers.

##### Verification

- `mix test test/integration/failure_windows --trace`

##### Completion gate

- Every named crash window has an assertion and recovery rule.
- No execution becomes corrupt/stuck without reconciliation detection.
- Ambiguous writes pause.

##### Dependencies

`P15-T03`, `P7-T09`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P15-T05 — Complete security integration suite

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Run end-to-end tests for signature, OAuth state/session, tenant isolation, webhook abuse, approval spoofing, SSRF, limits, loops, and secret leakage.

##### Why now

Security properties span multiple modules and entry points.

##### Files/modules

- `test/security/**`
- `docs/security/review_results.md`

##### Changes

- Consolidate threat-model tests into discoverable scenarios.
- Test forged/malformed/replayed callbacks, invalid state, session fixation/revocation, cross-tenant routes/jobs, webhook brute force/rate, approval actor/token, SSRF/rebinding, payload bombs, recursion, log/export leakage, admin route absence, and uninstall credential blocking.
- Use captured logs/database rows/HTTP harness to assert negative properties.
- Mark test as release-blocking and deterministic.

##### Invariants

- A security test failure blocks release.
- Tests do not require public internet.
- Forbidden data assertions use generated unique canary secrets.

##### Failure behavior

- Test harness failure is not interpreted as attack blocked; verify harness controls.

##### Security considerations

- This task is the automated security release gate.

##### Tests

- Run all `test/security` with trace and a second seed.
- Static tools after integration suite.

##### Verification

- `mix test test/security --trace`
- `mix sobelow --config`
- `mix hex.audit`
- secret scan

##### Completion gate

- All threat-model automated proofs pass.
- Canary values absent from logs/history/exports.
- No critical/high static finding.

##### Dependencies

`P15-T04`, `P10-T05`, `P13-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P15-T06 — Complete LiveView/browser acceptance suite

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove real user flows, authorization, accessibility essentials, reconnects, and server-side mutation behavior.

##### Why now

Component tests alone miss browser/LiveView integration defects.

##### Files/modules

- `test/browser/**`
- `test/pumble_automation_web/live/**`
- `docs/product/ui_acceptance.md`

##### Changes

- Use the approved browser test runner only if it provides real value; otherwise combine LiveView tests with a small Playwright/Wallaby suite.
- Cover sign-in callback via fake Pumble, onboarding, create/edit nested workflow, conflict, validation, dry-run, activation, execution timeline, cancel, uncertainty, secret/connection, roles, audit, and sign-out.
- Test keyboard-only primary flow and narrow viewport.
- Test LiveView reconnect during save and action confirmation.
- Assert no browser console errors, failed assets, or CSP violations.

##### Invariants

- Tests use fake services and isolated tenants.
- Destructive actions remain server-authorized.
- No secret appears in DOM snapshots.

##### Failure behavior

- A flaky browser test is fixed or removed with replacement proof; it is not blindly retried until green.

##### Security considerations

- Use generated canary secret and assert it never appears in HTML, LiveView diff logs, or screenshots.

##### Tests

- Full browser suite.
- accessibility scan if selected.
- console/network error assertions.
- two-session conflict.

##### Verification

- `mix test test/pumble_automation_web/live`
- browser runner command documented in scripts/verify-ui.sh

##### Completion gate

- Core user journey passes at desktop and narrow viewport.
- Keyboard path works.
- Zero app console/CSP errors.

##### Dependencies

`P15-T05`, `P12-T08`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P15-T07 — Create full offline acceptance gate

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Provide one command that proves the release candidate offline before any deployment or live Pumble mutation.

##### Why now

The implementer needs a mechanical stop/go gate.

##### Files/modules

- `scripts/verify.sh`
- `scripts/verify-ui.sh`
- `.github/workflows/ci.yml`
- `docs/engineering/verification.md`

##### Changes

- Integrate format, warnings-as-errors, unit/integration/security/browser tests, Credo, Dialyzer, Sobelow, Hex audit, assets, migrations-from-empty, release build, Docker build if available, secret scan, and diff check.
- Record exact tool versions and test counts in a machine-readable receipt.
- Fail on skipped/only tests unless explicitly allowlisted with reason.
- Keep live certification excluded and separately named.
- Run from clean checkout in CI and locally.

##### Invariants

- One failing subgate yields nonzero exit.
- Receipt corresponds to exact Git SHA and lockfile.
- No external credentials required.

##### Failure behavior

- Unavailable required tool is failure/block, not skip.
- A known flaky test blocks candidate until resolved.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Execute in clean clone/container.
- verify receipt schema.
- intentionally fail one temporary gate then restore.

##### Verification

- `./scripts/verify.sh`
- `./scripts/verify-ui.sh`
- `git status --short`

##### Completion gate

- Clean exact commit passes every offline gate.
- Receipt is stored as CI artifact.
- No untracked/generated residue.

##### Dependencies

`P15-T06`, `P2-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P16 — Production deployment, restore, and rollback

#### P16-T01 — Build reproducible Phoenix release container

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Package the exact application and assets into a minimal non-root production image.

##### Why now

Deployment proof needs a deterministic artifact.

##### Files/modules

- `Dockerfile`
- `.dockerignore`
- `rel/**`
- `mix.exs`
- `config/runtime.exs`
- `scripts/container-smoke.sh`

##### Changes

- Use a pinned multi-stage Elixir/OTP build image and compatible minimal runtime base.
- Install dependencies with lockfile, compile assets and release under `MIX_ENV=prod`, copy only runtime artifacts/certs/tzdata needs.
- Run as numeric non-root user with read-only filesystem except explicit temp path if required.
- Set signal handling/entrypoint and expose the configured port.
- Add OCI labels for Git SHA/version and produce image digest.
- Do not bake secrets or source `.env` into layers.

##### Invariants

- Same source/lock/toolchain produces equivalent release contents.
- Runtime image contains no build credentials.
- Process is non-root.

##### Failure behavior

- Build failure stops release; missing runtime config fails at startup with redacted error.

##### Security considerations

- Pin base image by digest for release candidate after update policy; scan image for critical/high vulnerabilities.

##### Tests

- Container build.
- run as non-root.
- read-only filesystem.
- inspect layers/env for canary secret.
- basic health with test DB.

##### Verification

- `docker build --pull --no-cache -t pumble-automation:<sha> .`
- `docker inspect`
- `./scripts/container-smoke.sh`

##### Completion gate

- Image builds from clean checkout.
- Release boots with runtime config.
- No secret/source residue and non-root UID verified.

##### Dependencies

`P15-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P16-T02 — Implement release migration strategy

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Run database migrations safely once per deployment and preserve one-release rollback compatibility.

##### Why now

Schema rollout is the highest deployment consistency boundary.

##### Files/modules

- `rel/overlays/bin/migrate`
- `lib/pumble_automation/release.ex`
- `docs/operations/migrations.md`
- `test/release/migration_test.exs`

##### Changes

- Create a release task using Ecto migrator and explicit Repo startup.
- Deployment runs migration as a separate one-shot step before new instances become ready.
- Use advisory lock/provider single-run guarantee.
- Test expand-contract compatibility: prior release can run against expanded schema during rollback window.
- Do not auto-run destructive migrations on every web process boot.
- Record applied versions in deployment receipt.

##### Invariants

- Only one migration runner applies a version.
- New app is not ready before required schema.
- Rollback image remains compatible for declared window.

##### Failure behavior

- Migration failure leaves old release serving and new release unready; operator follows rollback/runbook.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Two migration runners.
- failure midway transaction/nontransaction.
- old/new app compatibility fixture.
- empty DB release migrate.

##### Verification

- `MIX_ENV=prod mix release`
- `_build/prod/rel/pumble_automation/bin/pumble_automation eval 'PumbleAutomation.Release.migrate()'`
- release migration integration script

##### Completion gate

- Migration is reproducible and single-run.
- Failure behavior is proved.
- No destructive change violates rollback window.

##### Dependencies

`P16-T01`, `P2-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P16-T03 — Configure production deployment and health

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Define one boring web/worker deployment with managed PostgreSQL, HTTPS, runtime secrets, and meaningful probes.

##### Why now

The app needs a concrete deployable topology before live certification.

##### Files/modules

- `deployment manifests/config for selected platform`
- `docs/operations/deployment.md`
- `config/runtime.exs`
- `scripts/production-smoke.sh`

##### Changes

- Deploy one Phoenix release instance or small replica set running web and Oban; do not split workers until evidence.
- Provision managed PostgreSQL with SSL, backups, connection limits, and appropriate timezone/encoding.
- Inject secrets through platform secret store.
- Configure canonical HTTPS host, trusted proxy, raw-body preserving proxy, liveness/readiness, startup grace, and rolling/recreate strategy appropriate to singleton work.
- Set Oban concurrency and DB pool conservatively.
- Document DNS/callback URLs and environment mapping.

##### Invariants

- No local filesystem is durable truth.
- HTTPS terminates without changing body bytes.
- Readiness blocks traffic when DB/schema unavailable.

##### Failure behavior

- Missing DB/secret/config keeps instance unready.
- Old instance remains until new readiness passes under rollback strategy.

##### Security considerations

- Restrict database network/access, require TLS, and expose only HTTPS application port; no public Oban/admin dashboard.

##### Tests

- Staging deployment.
- DB-down readiness.
- raw-body HMAC through proxy.
- secret rotation restart.
- multiple-instance Oban safety if replicas.

##### Verification

- platform deploy command
- `curl /health/live and /health/ready`
- signed callback proxy smoke
- `./scripts/production-smoke.sh`

##### Completion gate

- Staging instance is healthy with exact image digest.
- Raw signature survives proxy.
- No split architecture/unneeded service exists.

##### Dependencies

`P16-T02`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P16-T04 — Verify graceful shutdown and zero-loss durable work

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove deploy/restart termination stops accepting work, drains bounded operations, and preserves jobs/waits.

##### Why now

Deployments must not lose or duplicate durable progression beyond documented semantics.

##### Files/modules

- `lib/pumble_automation/application.ex`
- `config/runtime.exs`
- `scripts/shutdown-test.sh`
- `test/release/shutdown_test.exs`

##### Changes

- Configure server termination/grace period and Oban shutdown timeout.
- On SIGTERM, stop new HTTP acceptance through platform drain, allow short DB finalization, and let Oban return interrupted jobs to durable queue.
- Do not wait indefinitely for external calls; phase-aware interruption may produce retry or uncertainty.
- Run tests with active pure step, Pumble/HTTP mock call, delay, approval, schedule dispatcher, and migration/maintenance job.
- Restart same image and verify convergence/history.

##### Invariants

- Durable rows/jobs survive process replacement.
- No in-memory timer/state is required.
- Ambiguous interrupted writes use uncertainty policy.

##### Failure behavior

- Forced SIGKILL still recovers through leases/reconciliation; it may not complete graceful log but cannot corrupt state.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- SIGTERM and SIGKILL at each representative state.
- rolling replacement if multiple instances.
- same image restart.
- duplicate job check.

##### Verification

- `./scripts/shutdown-test.sh`
- platform replacement logs/receipt

##### Completion gate

- Delay/approval/schedule survive.
- Interrupted jobs resume or pause uncertain as documented.
- No orphaned runnable execution.

##### Dependencies

`P16-T03`, `P15-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P16-T05 — Configure and prove backup restore

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Create recoverable PostgreSQL backups and restore an exact release into isolation.

##### Why now

Backups are unproved until a restore succeeds.

##### Files/modules

- `docs/operations/backup_restore.md`
- `scripts/restore-verify.sh`
- `deployment provider backup configuration`
- `test/release/restore_checks.sql or Elixir checks`

##### Changes

- Enable encrypted automated backups and PITR if the provider supports it; document retention and RPO/RTO targets.
- Create representative staging data including encrypted tokens/secrets, active versions, running/waiting execution, Oban jobs, schedule, approval, audit.
- Restore to isolated database, point exact image at it with same encryption read keys, run migration policy, and execute integrity checks without making real external calls.
- Verify counts/foreign keys/version hashes/job presence/decryption ability through safe boolean checks.
- Destroy restore environment and record receipt.

##### Invariants

- Restore test never contacts production Pumble/external endpoints.
- Encryption keys needed for recovery are backed up separately and securely.
- Oban state is included.

##### Failure behavior

- Any undecryptable credential or missing durable job fails the gate; do not expose plaintext in receipt.

##### Security considerations

- Restrict restored database access and destroy it promptly; never download unencrypted production backup to developer machine.

##### Tests

- Full restore drill.
- wrong/missing key failure.
- PITR point selection if available.
- integrity and cleanup.

##### Verification

- `./scripts/restore-verify.sh <isolated-db>`
- provider backup/restore commands documented

##### Completion gate

- A dated restore receipt names backup, image digest, schema, and checks.
- Representative durable states survive.
- No live effects occurred.

##### Dependencies

`P16-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P16-T06 — Prove deployment smoke and rollback

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Validate the release candidate in staging and roll back application/image safely.

##### Why now

Marketplace/live certification should not be the first deployment exercise.

##### Files/modules

- `scripts/production-smoke.sh`
- `scripts/rollback-smoke.sh`
- `docs/operations/rollback.md`
- `release evidence folder`

##### Changes

- Run health/readiness, authenticated UI, DB write/read, Oban trivial job, signed callback fixture, fake Pumble action, webhook, delay/restart, approval wait, schedule dispatch, retention dry check, and diagnostics.
- Deploy a second compatible candidate, then roll back to prior image without schema downgrade.
- Verify old image serves and processes durable jobs against expanded schema.
- Record image digest, Git SHA, migration versions, config names, tests, and timestamps.
- Leave staging clean.

##### Invariants

- Smoke uses non-production/fake external effects.
- Rollback does not mutate source or secretly rebuild image.
- Evidence matches exact digest.

##### Failure behavior

- Any mismatch between source SHA/image/config blocks live certification.
- Rollback failure is release-blocking.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Staging smoke.
- rollback under active delay/job.
- post-rollback callback/UI/queue.
- cleanliness check.

##### Verification

- `./scripts/production-smoke.sh`
- `./scripts/rollback-smoke.sh`
- `git status --short`

##### Completion gate

- Candidate deploys and rolls back using documented commands.
- Durable work remains correct.
- Evidence is complete and clean.

##### Dependencies

`P16-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P17 — Live Pumble certification and Marketplace readiness

#### P17-T01 — Prepare sacrificial Pumble workspace and exact manifest

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Create an isolated developer workspace, production-like app registration, and traceable live-test manifest.

##### Why now

Live probes must not affect customer or personal production workspaces.

##### Files/modules

- `priv/pumble/manifest.template.json`
- `generated release manifest outside source secrets`
- `docs/evidence/live_certification_plan.md`
- `certification/evidence/**`

##### Changes

- Use a sacrificial workspace/channel/users and unique test prefix.
- Generate manifest from approved static entries, fixed HTTPS URLs, minimal current scope matrix, Home/listing/help URLs, and documented seven event subscriptions with only selected user triggers exposed.
- Strip appKey/clientSecret/signingSecret from public manifest.
- Record app/workspace identifiers in protected evidence, not public docs; store credentials only in secret manager.
- Define cleanup for messages, channels if created, reactions, workflows, webhooks, and app uninstall.

##### Invariants

- Manifest source is reproducible from repository/config.
- No secret is in served/uploaded public manifest.
- Workspace is non-customer.

##### Failure behavior

- Missing owner access or inability to isolate workspace marks certification blocked; do not substitute production.

##### Security considerations

- Use least-privilege test users and rotate/remove credentials after certification as appropriate.

##### Tests

- Manifest JSON/schema validation.
- GET served manifest and secret scan.
- URL/HTTPS checks.
- scope diff review.

##### Verification

- manifest generation command
- `curl production manifest`
- secret scan

##### Completion gate

- Exact candidate manifest is approved and maps to source matrix.
- All live tests have cleanup.
- No customer data involved.

##### Dependencies

`P16-T06`, `P4-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P17-T02 — Certify OAuth, sessions, reinstall, unauthorized, and uninstall

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Verify the complete installation lifecycle against actual Pumble behavior.

##### Why now

Offline fixtures cannot prove consent, token shapes, scope changes, or lifecycle delivery.

##### Files/modules

- `test/live/pumble/oauth_lifecycle_test.exs or scripted checklist`
- `certification/evidence/oauth/**`
- `docs/evidence/pumble_probe_register.md`

##### Changes

- Run install from clean state and capture redacted callback/status evidence.
- Verify bot/user identity, browser session, first owner, minimal scopes, and Home/onboarding.
- Sign in a second user and verify role assignment policy.
- Reinstall with a controlled scope change; verify atomic token replacement and workflow revalidation.
- Trigger/remove authorization and verify session/token behavior.
- Uninstall and verify signed lifecycle event, immediate blocking/credential purge, queued/running behavior, and reinstall recovery policy.
- Resolve all relevant probe items with exact observed fields/timing.

##### Invariants

- No token/code/signing secret in evidence.
- Uninstall produces no new effects.
- Observed behavior updates source matrix without retroactive assumptions.

##### Failure behavior

- Any identity/scope/lifecycle mismatch blocks release and opens remediation; do not hand-edit DB to pass.

##### Security considerations

- Owner must approve live app mutations; evidence contains only hashes/opaque IDs and redacted screenshots/logs.

##### Tests

- Live lifecycle scenarios with unique IDs.
- Post-uninstall database assertions via safe admin/test interface.
- cleanup/reinstall.

##### Verification

- manual/live test command documented and explicitly excluded from CI
- production logs/DB safe assertions

##### Completion gate

- Install/reinstall/unauthorized/uninstall all pass on exact candidate.
- Probe register is updated.
- Workspace can be returned to clean state.

##### Dependencies

`P17-T01`, `P3-T07`, `P8-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P17-T03 — Certify event delivery, signatures, identity, and deduplication

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Verify every retained Pumble event trigger and lifecycle event payload against the live adapter.

##### Why now

The seven-event corpus may omit delivery/retry nuances required for production semantics.

##### Files/modules

- `test/live/pumble/events_test.exs`
- `certification/evidence/events/**`
- `priv/pumble/fixtures/callbacks/**`

##### Changes

- Trigger NEW_MESSAGE, UPDATED_MESSAGE, REACTION_ADDED, CHANNEL_CREATED, WORKSPACE_USER_JOINED in controlled channels/users; observe envelope, body field types, request IDs, author/bot identity, timestamps, and delivery count.
- Verify valid signature through production proxy and invalid signature rejection using an isolated replay harness only where allowed.
- Replay an exact captured sanitized event through local/staging adapter to prove dedup.
- Observe callback retry behavior by intentionally returning a controlled failure in a dedicated probe if safe.
- Verify APP_UNAUTHORIZED/UNINSTALLED separately without user workflow execution.
- Update sanitized fixtures/provenance.

##### Invariants

- Only supported events become selectable.
- Raw captured live payloads are protected/sanitized before repository.
- Dedup key uses observed stable identity.

##### Failure behavior

- Missing stable IDs or unexpected retry behavior leads to conservative documented fallback/remediation, not a false exactly-once claim.

##### Security considerations

- Do not retain real message/user content; replace values while preserving shape and cryptographic fixtures only when allowed.

##### Tests

- One live scenario per event.
- duplicate/replay.
- bot-origin detection.
- invalid signature local/staging test.

##### Verification

- live certification script/checklist
- offline fixture suite rerun after sanitization

##### Completion gate

- All retained payload mappings are live-verified.
- Dedup semantics match observed IDs/retries.
- No lifecycle event triggers user workflow.

##### Dependencies

`P17-T02`, `P8-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P17-T04 — Certify interactive acknowledgement and response flows

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove slash command, global/message shortcut, approval button, view action, and any used modal response behavior within Pumble deadlines.

##### Why now

The source corpus contains response/ack examples that need live reconciliation.

##### Files/modules

- `test/live/pumble/interactions_test.exs`
- `certification/evidence/interactions/**`
- `docs/evidence/pumble_probe_register.md`

##### Changes

- Measure end-to-end acknowledgement for fixed slash/global/message shortcuts and approval buttons.
- Verify whether ack then modal/response is accepted, whether one HTTP response may open a modal, and exact error UX for nack/timeout.
- Select and lock the weakest protocol-safe manual picker flow; remove dead alternate code.
- Verify message shortcut source IDs/content availability, actor/workspace identity, duplicate clicks, stale approval, and unauthorized approver.
- Verify any retained Home/modal/view action callbacks and loading behavior.
- Record p50/p95/max under controlled runs with margin below three seconds.

##### Invariants

- Each interaction has one proven response sequence.
- Durable state precedes success where designed.
- No long work before ack.

##### Failure behavior

- Any timeout or double-response ambiguity blocks the affected feature; degrade to simpler ack/asynchronous message flow if supported.

##### Security considerations

- Interaction payloads are signed; actor identity and opaque tokens are verified; screenshots redact IDs/content.

##### Tests

- Live interactions repeated.
- intentional slow/failure probe.
- duplicate/stale approval.
- restart before click.

##### Verification

- live interaction certification command/checklist
- production latency telemetry query

##### Completion gate

- All shipped interactions complete without Pumble timeout.
- Source conflict is resolved in probe register/adapter tests.
- Unused dynamic/modal behavior is absent.

##### Dependencies

`P17-T03`, `P11-T07`, `P8-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P17-T05 — Certify Pumble actions, scopes, errors, and rate limits

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Verify every retained API operation, minimal scope, and failure classification against live Pumble.

##### Why now

The Node SDK documents methods but not all current production semantics.

##### Files/modules

- `test/live/pumble/actions_test.exs`
- `certification/evidence/actions/**`
- `docs/evidence/pumble_source_matrix.md`

##### Changes

- Run post message, reply, DM, add/remove reaction, Home publish, and approval message/update if retained.
- For each, record bot/user token required, exact minimal scope, response IDs, limits, and already-present/absent behavior.
- Use controlled missing-scope/revoked-token tests to confirm 401/403.
- Probe 429/retry headers only through a safe bounded method and stop before disruptive volume; use vendor-provided/dev mechanisms if available.
- Test a controlled 5xx/timeout through proxy/fake, not by attacking Pumble.
- Compare results to adapter classification and update scope map/fixtures.

##### Invariants

- No action outside product catalog is probed.
- Scope set remains minimal.
- Rate probe is bounded and owner-approved.

##### Failure behavior

- Unexpected response/retry safety blocks automatic retry and may force uncertainty until resolved.

##### Security considerations

- Use sacrificial content and cleanup; never include tokens in HTTP traces.

##### Tests

- One success and relevant failure per operation.
- missing scope.
- revoked token.
- already reaction state.
- rate metadata.

##### Verification

- live action certification command/checklist
- offline contract suite after fixture updates

##### Completion gate

- Every shipped operation and scope is live-proven.
- 401/403/429 behavior maps correctly.
- No uncontrolled rate test or residue remains.

##### Dependencies

`P17-T04`, `P9-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P17-T06 — Run full live end-to-end acceptance suite

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prove the product scenarios across real Pumble callbacks, deployed app, PostgreSQL, Oban, and UI.

##### Why now

Subsystem probes do not prove the assembled release.

##### Files/modules

- `test/live/pumble/end_to_end_test.exs or operator checklist`
- `certification/evidence/e2e/**`
- `Section 42 acceptance matrix`

##### Changes

- Run Scenarios A–Q from the canonical acceptance matrix where live Pumble is required, using fake external HTTP server for deterministic branches/failures.
- Include durable delay with deployment/restart, HTTP branch, approval restart, bounded retry, permanent failure, duplicate callback replay, two-worker race in staging, tenant isolation, SSRF block, install lifecycle, interactive timing, uncertain write simulation, session revocation, DST schedule, backup restore evidence, and loop prevention.
- Verify execution timeline explains each outcome.
- Clean all probe content and assert no prefixed residue.
- Capture exact Git SHA/image digest/config/migration versions and test results.

##### Invariants

- Live tests run exact release candidate.
- No skipped core scenario.
- Cleanup is verified, not assumed.

##### Failure behavior

- A failed scenario blocks Marketplace/release; rerun only after code change creates a new candidate receipt.

##### Security considerations

- Use owner-controlled approvals for live mutations and redact exported evidence.

##### Tests

- Acceptance matrix execution and cleanup queries.
- source/image fingerprint comparison.

##### Verification

- live suite command/checklist
- deployment receipt
- cleanup verification

##### Completion gate

- All mandatory scenarios pass with evidence.
- No Pumble/workspace residue.
- Candidate fingerprint remains unchanged through certification.

##### Dependencies

`P17-T05`, `P16-T06`, `P15-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P17-T07 — Complete Marketplace and publication readiness

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Prepare truthful listing, support/privacy documents, manifest, review evidence, rollback, and release decision.

##### Why now

A technically working app is not ready for public installation without lifecycle and policy materials.

##### Files/modules

- `priv/pumble/manifest.template.json`
- `docs/public/privacy.md`
- `terms.md if needed`
- `support.md`
- `data_deletion.md`
- `marketplace_checklist.md`
- `certification/evidence/release/**`

##### Changes

- Generate final public manifest with absolute HTTPS callbacks/redirects, minimal scopes, listing/help/privacy/support/deletion URLs, welcome/offline messaging, and no secrets.
- Write concise user docs for install, workflow semantics, supported triggers/actions, retries/uncertainty, secrets, data retention/deletion, and support.
- Run Pumble pre-publish/Marketplace validation using current official process proven from live tools/docs.
- Prepare reviewer test account/workspace instructions without credentials in repository.
- Document rollback and incident contact.
- Create go/no-go checklist requiring P17-T06, security, restore, deployment, and cleanup evidence.

##### Invariants

- Listing claims only shipped/live-proven behavior.
- Privacy policy matches actual retention and logs.
- Manifest contains no secret/private host.

##### Failure behavior

- Marketplace tool/process change becomes an updated task/evidence item; do not fabricate submission success.

##### Security considerations

- Public docs disclose data use and deletion accurately without revealing infrastructure security details.

##### Tests

- Manifest secret/URL/scope checks.
- link checks.
- fresh install from published candidate.
- documentation review against implementation.

##### Verification

- pre-publish command proven by current Pumble tooling
- secret scan
- link checker
- `./scripts/verify.sh`

##### Completion gate

- Submission package is complete and truthful.
- All go/no-go gates pass.
- Rollback/support paths exist.

##### Dependencies

`P17-T06`, `P14-T05`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


### Phase P18 — Final polish, proof, release, and handoff

#### P18-T01 — Perform final visual and content QA

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Refine visual hierarchy, interaction clarity, user-facing language, and edge states without changing engine semantics.

##### Why now

Polish belongs after semantics are stable and should not introduce architectural risk.

##### Files/modules

- `assets/**`
- `lib/pumble_automation_web/components/**`
- `lib/pumble_automation_web/live/**`
- `docs/product/ui_acceptance.md`

##### Changes

- Review every page/state with representative long names, failures, waits, uncertainty, empty data, permissions, and narrow screens.
- Apply ASD-STE100 principles to labels, validation, errors, confirmations, onboarding, and docs.
- Remove inconsistent components/styles and dead CSS/JS.
- Ensure status/action hierarchy prevents accidental destructive choices.
- Do not add a graph canvas unless usability evidence proves the outline blocks release; any canvas is a separate post-release ADR.

##### Invariants

- Polish does not bypass services or alter protocol/execution semantics.
- User messages remain accurate about delivery guarantees.
- No new dependency without policy.

##### Failure behavior

- Visual changes that break accessibility/browser tests are reverted or fixed before merge.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- Visual regression/manual matrix.
- browser/accessibility suite.
- content review for ambiguous promises such as exactly-once.

##### Verification

- `mix assets.build`
- `mix test test/pumble_automation_web/live test/browser/**`
- manual UI checklist

##### Completion gate

- Consistent high-quality UI across all core states.
- No dead CSS/JS.
- No false reliability/security claim.

##### Dependencies

`P17-T07`, `P12-T08`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P18-T02 — Run focused performance and capacity proof

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Verify obvious high-volume paths meet conservative targets without premature architecture changes.

##### Why now

Release should prove indexed matching, bounded queues, and usable UI on realistic data.

##### Files/modules

- `test/performance/**`
- `scripts/load-smoke.*`
- `docs/operations/capacity.md`
- `database EXPLAIN evidence`

##### Changes

- Define modest targets for signed callback acceptance, trigger match, execution creation, workflow list/history pagination, scheduler batch, and queue latency.
- Seed representative large tenant within configured limits and multiple tenants.
- Measure database query plans, pool use, N+1, lock contention, payload/context growth, and Oban concurrency.
- Run bounded webhook/callback load against staging with fake Pumble actions.
- Optimize only demonstrated bottlenecks using indexes/query/preload/concurrency tuning; no Redis/microservice/cache tier without evidence.
- Record capacity assumptions and alert thresholds.

##### Invariants

- Tests remain within resource limits.
- Performance changes preserve semantics/tests.
- Metrics do not expose tenant content.

##### Failure behavior

- A target miss creates a measured remediation; do not hide it by raising limits/timeouts.

##### Security considerations

- No task-specific security change beyond preserving existing boundaries.

##### Tests

- EXPLAIN plans.
- load smoke.
- concurrent tenant fairness.
- UI query counts.
- scheduler/retention batch.

##### Verification

- performance script command
- database EXPLAIN artifacts
- `./scripts/verify.sh after optimization`

##### Completion gate

- No sequential workflow scan/N+1/unbounded query.
- Conservative target met or release decision explicitly blocked.
- No speculative infrastructure added.

##### Dependencies

`P18-T01`, `P14-T03`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P18-T03 — Run final security, dependency, and secret review

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Reverify the exact release candidate after all polish/performance changes.

##### Why now

Earlier security evidence becomes stale when the tree changes.

##### Files/modules

- `docs/security/review_results.md`
- `release evidence`
- `mix.lock`
- `Docker image/SBOM if used`

##### Changes

- Run full offline gate, security suite, Sobelow, Hex audit, dependency/license review, source/generated-file/image secret scans, and container vulnerability scan.
- Review the final diff from last security-reviewed commit.
- Verify production manifest and runtime config names contain no values.
- Confirm test hooks/debug routes are absent.
- Generate SBOM only if supported by chosen tool/platform and useful; do not add bloat solely for appearance.

##### Invariants

- Evidence names exact Git SHA and image digest.
- No high/critical finding or secret leak.
- Lockfile is unchanged after verification.

##### Failure behavior

- Tool outage is blocked/not verified.
- Any source change after review invalidates the receipt.

##### Security considerations

- This is the final security gate for the exact artifact.

##### Tests

- All security commands and clean-tree/hash checks.

##### Verification

- `./scripts/verify.sh`
- `mix sobelow --config`
- `mix hex.audit`
- secret scan source/image
- container scan
- `git diff --check && git status --short`

##### Completion gate

- Exact candidate passes.
- No unresolved critical/high.
- No code/config change after evidence capture.

##### Dependencies

`P18-T02`, `P13-T07`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P18-T04 — Execute final production acceptance and cleanup

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Run the complete acceptance matrix, rollback, restore evidence checks, live smoke, and residue cleanup on the final candidate.

##### Why now

Release requires one coherent final proof, not a collection of stale partial passes.

##### Files/modules

- `certification/evidence/final/**`
- `IMPLEMENTATION_LEDGER.md`
- `Section 42 matrix`
- `release checklist`

##### Changes

- Re-run offline gate and only live scenarios affected by final changes, while ensuring the full matrix has current candidate evidence.
- Verify deployment image/Git/migrations/config fingerprint.
- Run production smoke on approved workspace, then verify no probe messages/reactions/channels/workflows/webhooks/secrets remain.
- Verify no pending test Oban jobs, approvals, schedules, or prefixed database rows.
- Confirm backup/restore and rollback receipts are within release policy.
- Mark ledger tasks complete only with linked evidence.

##### Invariants

- Final candidate source is frozen during proof.
- Cleanup is an explicit tested phase.
- No stale evidence from another SHA counts.

##### Failure behavior

- Any mutation/change creates a new candidate and invalidates downstream evidence.
- Cleanup failure blocks release.

##### Security considerations

- Redact final evidence package before sharing; keep credentials only in secret manager.

##### Tests

- Acceptance matrix, residue queries, clean-tree/hash, deployment smoke, evidence consistency script.

##### Verification

- `./scripts/verify.sh`
- live smoke command
- cleanup verifier
- `git rev-parse HEAD && git status --short`

##### Completion gate

- Every mandatory gate is current and green.
- Zero test residue.
- Ledger/evidence refer to one exact candidate.

##### Dependencies

`P18-T03`, `P17-T06`, `P16-T06`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.


#### P18-T05 — Create release candidate, publish, and hand off

**Status:** `NOT STARTED`  
**Existing state:** `NOT VERIFIED` until Phase 0 evidence updates the ledger.

##### Objective

Commit/tag/push/deploy/submit the proved artifact using controlled release authority and leave a maintainable handoff.

##### Why now

The perfect end state includes actual release readiness and clear ownership, not only code completion.

##### Files/modules

- `CHANGELOG.md`
- `README.md`
- `release notes`
- `IMPLEMENTATION_LEDGER.md`
- `release evidence`
- `repository tag/branch`

##### Changes

- Prepare concise changelog and release notes with supported features, limits, known honest semantics, migrations, and rollback.
- Ensure repository is clean; create intentional commit/tag only after all gates.
- Push/deploy/publish or submit to Marketplace only when credentials, owner approval, and repository policy permit; never fabricate external mutation.
- Record commit SHA, tag, pushed ref, image digest, deployment ID, manifest hash, migration versions, certification receipt, and submission status.
- Hand off architecture, local setup, runbooks, support/incident path, dependency update policy, and post-release backlog.
- Monitor initial release metrics and define rollback trigger; do not promise asynchronous monitoring from the coding agent.

##### Invariants

- Published artifact equals proved candidate.
- No uncommitted changes or secret files.
- Release notes make no unsupported claims.

##### Failure behavior

- If push/deploy/submission authority is unavailable, stop at a complete signed release package and mark external step `BLOCKED`; do not claim release.

##### Security considerations

- Use least-privilege release credentials; never place tokens in shell history/evidence; verify public manifest one final time.

##### Tests

- Fresh clone verification.
- tag/image/manifest hash match.
- post-deploy smoke.
- Marketplace status evidence.
- clean tree.

##### Verification

- `git status --short`
- `git show --stat <tag>`
- `./scripts/verify.sh`
- deployment/publication commands selected by repository/platform

##### Completion gate

- Release is either externally proven complete or precisely blocked at an owner-controlled step.
- Handoff is sufficient for a new engineer/agent.
- No core correctness TODO remains.

##### Dependencies

`P18-T04`

##### Completion evidence

When complete, update `IMPLEMENTATION_LEDGER.md` with the exact Git SHA, commands, results, test names, migration versions where relevant, and links/paths to live or deployment evidence. A code path or passing-looking test name is not evidence by itself.

## 40. Implementation session protocol

At the start of every implementation session:

1. Read this canonical plan and `IMPLEMENTATION_LEDGER.md`.
2. Run `git status --short`, record `HEAD`, and inspect changes made by other agents.
3. Reverify the completion evidence of direct prerequisites for the next task.
4. Select the first incomplete task whose dependencies are complete.
5. Mark only that task `IN PROGRESS`.
6. Inspect existing code before editing. Preserve correct behavior.
7. Implement the smallest complete change for that task.
8. Run the task-specific tests, then the relevant phase gate.
9. Review the diff for unrelated changes, dead code, accidental secrets, and architecture drift.
10. Mark the task `COMPLETE` only with exact evidence. Otherwise use `BLOCKED`, `REVERIFY`, or leave it incomplete.
11. Commit only coherent proved work. Do not mix unrelated tasks to hide failures.
12. Continue to the next unblocked task. Stop only for a real external dependency, owner-controlled approval, missing credential, safety boundary, or unrecoverable evidence conflict.

### Change-control rules

- A task may refine implementation details inside its approved boundary.
- A change to product contract, states, delivery semantics, tenant model, security policy, data lifecycle, dependency set, or phase order requires an ADR.
- A live observation that contradicts the supplied Pumble corpus updates the probe register, source matrix, adapter tests, and affected ADR before feature work continues.
- Never weaken a completion gate merely to make a task pass.
- Never delete a failing test until the intended behavior has been re-established and the replacement proof is at least as strong.
- Never run destructive production or Marketplace mutations without the required owner authority.
- Never claim a push, deploy, live certification, or publication that did not produce verifiable external evidence.

---

## 41. Phase verification gates and progress ledger

### 41.1 Phase gates

| Phase | Scope | Completion gate | Minimum proof |
|---|---|---|---|
| P0 | Evidence/current state | Inventory, baseline, source matrix, probe register, ledger exist; no unproved current-state claim. | Read-only inventory; baseline commands; ID/dependency check. |
| P1 | Contract/architecture | Finite v1 contract, ADRs, threat model, dependency policy approved; unknowns remain probes. | Documentation review; official-version revalidation; dependency compatibility spike. |
| P2 | Foundation | App boots; DB/Oban/audit migrations replay; strict config and complete local/CI verification path pass. | `./scripts/verify.sh` subset, fresh DB migrate, health/audit tests. |
| P3 | Identity | Install/sign-in/reinstall/revoke/uninstall/session behavior passes offline with encrypted credentials. | Identity contract suite; redaction scan; concurrency tests. |
| P4 | Pumble boundary | Raw signatures, callback classes, response dispatch, API operations, error/scope maps pass offline. | Pumble contract tests; valid/invalid signature fixtures; fake server. |
| P5 | Workflow/dependencies | Tenant-scoped drafts, typed AST, immutable versions, bindings/schedules, secrets/connections, and CRUD invariants pass. | Workflow/dependency schema/editor/context tests; migration replay. |
| P6 | Compiler/activation | Invalid drafts are rejected; valid drafts compile deterministically; activation/deactivation is atomic. | Validator/compiler/activation race tests. |
| P7 | Execution engine | Claim/finalize/retry/cancel/reconcile/uncertainty semantics survive duplicate jobs and races. | Execution database/race/failure-window tests. |
| P8 | Ingress | Callbacks/webhooks deduplicate and create the documented executions/jobs through indexed lookup. | Ingress transaction, dedup race, webhook abuse, matcher plan tests. |
| P9 | Core nodes | Paths, templates, conditions, Pumble actions, stop, and dry-run match compiler semantics. | Pure/node/fake-Pumble tests; no-network dry-run proof. |
| P10 | Safe HTTP | SSRF/DNS pinning/redirect/retry/uncertainty suite passes and connection secrets remain isolated. | Full HTTP adversarial security suite; leak scan. |
| P11 | Durable waits | Delay, schedule, and approval survive restart, races, cancellation, and timeout. | Restart/race/DST/approval suites. |
| P12 | UI | Authorized users can create, validate, activate, operate, and diagnose workflows with accessible UI. | LiveView/browser/role/accessibility/reconnect tests. |
| P13 | Hardening | Tenant matrix, limits, loop protection, retention, web security, audit, and threat closure pass. | `test/security`; Sobelow; Hex audit; secret scan. |
| P14 | Operations | Structured logs/metrics/health/maintenance/runbooks/diagnostics are useful and privacy-safe. | Observability tests; runbook game day; diagnostic canary scan. |
| P15 | Offline candidate | Exact clean commit passes complete offline acceptance and produces a receipt. | `./scripts/verify.sh`; UI gate; release/container build. |
| P16 | Deployment | Exact image deploys, migrates, drains, restores, and rolls back in staging. | Deployment, shutdown, restore, rollback receipts. |
| P17 | Live certification | Exact candidate passes Pumble lifecycle, events, interactions, actions, E2E, cleanup, and publication preparation. | Owner-controlled live suite; manifest/pre-publish; residue verification. |
| P18 | Release | Final exact candidate passes visual, capacity, security, acceptance, cleanup, publication, and handoff gates. | Final receipts, clean tree, tag/image/manifest fingerprints, post-deploy smoke. |

### 41.2 Canonical progress ledger seed

Copy this table into `IMPLEMENTATION_LEDGER.md`. Preserve completed evidence rather than rewriting history.

| Task | Title | Initial status | Dependencies | Completion evidence |
|---|---|---:|---|---|
| P0-T01 | Inventory repository and preserve evidence | `NOT STARTED` | — | — |
| P0-T02 | Establish reproducible baseline | `NOT STARTED` | P0-T01 | — |
| P0-T03 | Create source-evidence matrix | `NOT STARTED` | P0-T01 | — |
| P0-T04 | Create protocol probe register | `NOT STARTED` | P0-T03 | — |
| P0-T05 | Create progress ledger and ADR skeleton | `NOT STARTED` | P0-T01 | — |
| P1-T01 | Freeze product contract and non-goals | `NOT STARTED` | P0-T03, P0-T04 | — |
| P1-T02 | Approve manifest trigger model | `NOT STARTED` | P1-T01 | — |
| P1-T03 | Approve workflow representation and execution semantics | `NOT STARTED` | P1-T01 | — |
| P1-T04 | Approve threat model and data classification | `NOT STARTED` | P1-T03 | — |
| P1-T05 | Freeze dependency and coding policy | `NOT STARTED` | P1-T04 | — |
| P2-T01 | Scaffold or reconcile Phoenix application | `NOT STARTED` | P1-T05 | — |
| P2-T02 | Implement strict runtime configuration | `NOT STARTED` | P2-T01 | — |
| P2-T03 | Configure PostgreSQL and migration discipline | `NOT STARTED` | P2-T01, P2-T02 | — |
| P2-T04 | Install and configure Oban | `NOT STARTED` | P2-T03 | — |
| P2-T05 | Add quality gates and continuous integration | `NOT STARTED` | P2-T04 | — |
| P2-T06 | Create health, readiness, and typed error foundation | `NOT STARTED` | P2-T03, P2-T05 | — |
| P2-T07 | Create append-only audit foundation | `NOT STARTED` | P2-T03, P2-T06 | — |
| P3-T01 | Create installation and identity schemas | `NOT STARTED` | P2-T03, P1-T04 | — |
| P3-T02 | Implement credential encryption and redaction | `NOT STARTED` | P3-T01, P1-T05 | — |
| P3-T03 | Implement OAuth state service | `NOT STARTED` | P3-T02 | — |
| P3-T04 | Implement install and sign-in OAuth flow | `NOT STARTED` | P3-T03, P2-T07 | — |
| P3-T05 | Implement revoke, unauthorized, and uninstall lifecycle | `NOT STARTED` | P3-T04 | — |
| P3-T06 | Implement browser sessions and membership roles | `NOT STARTED` | P3-T04 | — |
| P3-T07 | Add installation and identity contract suite | `NOT STARTED` | P3-T06 | — |
| P4-T01 | Capture bounded raw callback bodies | `NOT STARTED` | P2-T01, P2-T02 | — |
| P4-T02 | Verify Pumble callback signatures | `NOT STARTED` | P4-T01 | — |
| P4-T03 | Classify and decode Pumble payloads | `NOT STARTED` | P4-T02, P0-T03 | — |
| P4-T04 | Normalize Pumble events and identities | `NOT STARTED` | P4-T03, P3-T01 | — |
| P4-T05 | Implement protocol-correct response dispatch | `NOT STARTED` | P4-T04, P2-T06 | — |
| P4-T06 | Build Pumble API transport and error classifier | `NOT STARTED` | P3-T02, P2-T06 | — |
| P4-T07 | Implement product-required Pumble operations and scope map | `NOT STARTED` | P4-T06, P0-T03 | — |
| P5-T01 | Create workflow and draft persistence | `NOT STARTED` | P3-T01, P2-T03 | — |
| P5-T02 | Implement typed editable AST | `NOT STARTED` | P5-T01, P1-T03 | — |
| P5-T03 | Implement AST editing primitives and limits | `NOT STARTED` | P5-T02 | — |
| P5-T04 | Create immutable workflow versions | `NOT STARTED` | P5-T02 | — |
| P5-T05 | Create trigger bindings and schedules schema | `NOT STARTED` | P5-T04 | — |
| P5-T06 | Implement tenant-scoped workflow context and audit | `NOT STARTED` | P5-T05, P3-T06, P2-T07 | — |
| P5-T07 | Create encrypted secrets context | `NOT STARTED` | P3-T02, P5-T04 | — |
| P5-T08 | Create HTTP connections context | `NOT STARTED` | P5-T07 | — |
| P6-T01 | Implement structural workflow validator | `NOT STARTED` | P5-T03 | — |
| P6-T02 | Implement expressions, templates, and semantic validation | `NOT STARTED` | P6-T01 | — |
| P6-T03 | Implement compiler and canonical executable graph | `NOT STARTED` | P6-T02 | — |
| P6-T04 | Calculate required scopes and dependencies | `NOT STARTED` | P6-T03, P4-T07, P5-T08 | — |
| P6-T05 | Implement atomic activation | `NOT STARTED` | P6-T04, P5-T06 | — |
| P6-T06 | Implement deactivation and version reactivation | `NOT STARTED` | P6-T05 | — |
| P7-T01 | Create execution, step, attempt, and approval schemas | `NOT STARTED` | P5-T04, P3-T01 | — |
| P7-T02 | Implement pure execution state machine | `NOT STARTED` | P7-T01, P1-T03 | — |
| P7-T03 | Implement atomic execution creation | `NOT STARTED` | P7-T02, P2-T04, P6-T03 | — |
| P7-T04 | Implement worker claim protocol | `NOT STARTED` | P7-T03 | — |
| P7-T05 | Define node runner protocol and registry | `NOT STARTED` | P7-T04 | — |
| P7-T06 | Implement finalize-and-advance transaction | `NOT STARTED` | P7-T05 | — |
| P7-T07 | Implement retry and error policy | `NOT STARTED` | P7-T06, P4-T06 | — |
| P7-T08 | Implement uncertain-effect pause and operator resolution | `NOT STARTED` | P7-T07, P3-T06 | — |
| P7-T09 | Implement cancellation, concurrency limits, and reconciliation | `NOT STARTED` | P7-T08, P2-T04 | — |
| P8-T01 | Create received-event and inbound-webhook schemas | `NOT STARTED` | P5-T05, P3-T02 | — |
| P8-T02 | Implement deduplication-key strategy | `NOT STARTED` | P8-T01, P0-T04 | — |
| P8-T03 | Implement indexed trigger matcher | `NOT STARTED` | P8-T01, P6-T05 | — |
| P8-T04 | Implement Pumble event ingestion transaction | `NOT STARTED` | P8-T03, P7-T03, P4-T05 | — |
| P8-T05 | Wire lifecycle callbacks | `NOT STARTED` | P3-T05, P8-T02, P4-T05 | — |
| P8-T06 | Implement manual Pumble and browser trigger ingestion | `NOT STARTED` | P8-T02, P7-T03, P3-T06 | — |
| P8-T07 | Implement authenticated generic inbound webhooks | `NOT STARTED` | P8-T02, P7-T03, P6-T05 | — |
| P9-T01 | Implement runtime path resolver | `NOT STARTED` | P7-T05, P6-T02 | — |
| P9-T02 | Implement deterministic template renderer | `NOT STARTED` | P9-T01 | — |
| P9-T03 | Implement condition and branch node | `NOT STARTED` | P9-T02 | — |
| P9-T04 | Implement Pumble message, reply, and DM nodes | `NOT STARTED` | P7-T08, P9-T02, P4-T07 | — |
| P9-T05 | Implement reaction nodes | `NOT STARTED` | P9-T04 | — |
| P9-T06 | Implement stop node and end-to-end dry-run | `NOT STARTED` | P9-T05, P9-T03 | — |
| P10-T01 | Implement URL and IP policy | `NOT STARTED` | P5-T08 | — |
| P10-T02 | Implement DNS-pinned outbound transport | `NOT STARTED` | P10-T01, P1-T05 | — |
| P10-T03 | Implement HTTP action request builder | `NOT STARTED` | P10-T02, P9-T02, P5-T07 | — |
| P10-T04 | Implement redirect, response, extraction, and retry semantics | `NOT STARTED` | P10-T03, P7-T08 | — |
| P10-T05 | Complete adversarial HTTP security certification | `NOT STARTED` | P10-T04 | — |
| P11-T01 | Implement durable delay node | `NOT STARTED` | P7-T09, P9-T02 | — |
| P11-T02 | Implement schedule calculator | `NOT STARTED` | P6-T02, P1-T05 | — |
| P11-T03 | Implement due-schedule dispatcher | `NOT STARTED` | P11-T02, P7-T03, P2-T04 | — |
| P11-T04 | Implement schedule edit, activation, and deactivation semantics | `NOT STARTED` | P11-T03, P6-T06 | — |
| P11-T05 | Implement approval request and Pumble presentation | `NOT STARTED` | P11-T01, P9-T04 | — |
| P11-T06 | Implement approval decision and race handling | `NOT STARTED` | P11-T05, P4-T05 | — |
| P11-T07 | Implement approval timeout, cancellation, and audit | `NOT STARTED` | P11-T06, P7-T09 | — |
| P12-T01 | Build application shell, design tokens, and onboarding | `NOT STARTED` | P3-T06, P6-T06, P2-T05 | — |
| P12-T02 | Implement workflow list and creation flow | `NOT STARTED` | P12-T01, P5-T06 | — |
| P12-T03 | Implement nested outline workflow editor | `NOT STARTED` | P12-T02, P5-T03 | — |
| P12-T04 | Implement node configuration forms | `NOT STARTED` | P12-T03, P6-T02, P5-T08, P11-T02 | — |
| P12-T05 | Implement validation, dry-run, activation, and version controls | `NOT STARTED` | P12-T04, P9-T06, P6-T06 | — |
| P12-T06 | Implement execution history and operator controls | `NOT STARTED` | P12-T05, P7-T09, P11-T07 | — |
| P12-T07 | Implement secrets, connections, members, audit, and settings UI | `NOT STARTED` | P12-T06, P5-T08, P5-T07, P3-T06 | — |
| P12-T08 | Complete accessibility, responsive, and browser-state QA | `NOT STARTED` | P12-T07 | — |
| P13-T01 | Enforce tenant scope across all contexts and jobs | `NOT STARTED` | P12-T07, P7-T09 | — |
| P13-T02 | Enforce resource and rate limits | `NOT STARTED` | P13-T01, P8-T07 | — |
| P13-T03 | Implement workflow loop and lineage protection | `NOT STARTED` | P13-T02, P9-T04, P8-T04 | — |
| P13-T04 | Implement retention and tenant purge | `NOT STARTED` | P13-T03, P3-T05 | — |
| P13-T05 | Harden browser and HTTP security | `NOT STARTED` | P13-T01, P12-T08 | — |
| P13-T06 | Implement audit and protected support operations | `NOT STARTED` | P13-T05, P5-T06 | — |
| P13-T07 | Close threat model and dependency findings | `NOT STARTED` | P13-T06, P10-T05, P13-T04 | — |
| P14-T01 | Implement structured, redacted logging | `NOT STARTED` | P13-T07 | — |
| P14-T02 | Implement telemetry and metric definitions | `NOT STARTED` | P14-T01 | — |
| P14-T03 | Expose queue, schedule, and readiness diagnostics | `NOT STARTED` | P14-T02, P7-T09, P11-T03 | — |
| P14-T04 | Complete reconciliation and maintenance scheduling | `NOT STARTED` | P14-T03, P13-T04 | — |
| P14-T05 | Write operational runbooks | `NOT STARTED` | P14-T04 | — |
| P14-T06 | Implement privacy-safe diagnostic export | `NOT STARTED` | P14-T05 | — |
| P15-T01 | Complete pure-domain test suite | `NOT STARTED` | P13-T07, P11-T07 | — |
| P15-T02 | Complete database and race test suite | `NOT STARTED` | P15-T01 | — |
| P15-T03 | Complete Pumble adapter contract fixtures and fake server | `NOT STARTED` | P15-T02, P4-T07 | — |
| P15-T04 | Complete failure-injection and crash-window suite | `NOT STARTED` | P15-T03, P7-T09 | — |
| P15-T05 | Complete security integration suite | `NOT STARTED` | P15-T04, P10-T05, P13-T07 | — |
| P15-T06 | Complete LiveView/browser acceptance suite | `NOT STARTED` | P15-T05, P12-T08 | — |
| P15-T07 | Create full offline acceptance gate | `NOT STARTED` | P15-T06, P2-T05 | — |
| P16-T01 | Build reproducible Phoenix release container | `NOT STARTED` | P15-T07 | — |
| P16-T02 | Implement release migration strategy | `NOT STARTED` | P16-T01, P2-T03 | — |
| P16-T03 | Configure production deployment and health | `NOT STARTED` | P16-T02 | — |
| P16-T04 | Verify graceful shutdown and zero-loss durable work | `NOT STARTED` | P16-T03, P15-T04 | — |
| P16-T05 | Configure and prove backup restore | `NOT STARTED` | P16-T04 | — |
| P16-T06 | Prove deployment smoke and rollback | `NOT STARTED` | P16-T05 | — |
| P17-T01 | Prepare sacrificial Pumble workspace and exact manifest | `NOT STARTED` | P16-T06, P4-T07 | — |
| P17-T02 | Certify OAuth, sessions, reinstall, unauthorized, and uninstall | `NOT STARTED` | P17-T01, P3-T07, P8-T05 | — |
| P17-T03 | Certify event delivery, signatures, identity, and deduplication | `NOT STARTED` | P17-T02, P8-T04 | — |
| P17-T04 | Certify interactive acknowledgement and response flows | `NOT STARTED` | P17-T03, P11-T07, P8-T06 | — |
| P17-T05 | Certify Pumble actions, scopes, errors, and rate limits | `NOT STARTED` | P17-T04, P9-T05 | — |
| P17-T06 | Run full live end-to-end acceptance suite | `NOT STARTED` | P17-T05, P16-T06, P15-T07 | — |
| P17-T07 | Complete Marketplace and publication readiness | `NOT STARTED` | P17-T06, P14-T05 | — |
| P18-T01 | Perform final visual and content QA | `NOT STARTED` | P17-T07, P12-T08 | — |
| P18-T02 | Run focused performance and capacity proof | `NOT STARTED` | P18-T01, P14-T03 | — |
| P18-T03 | Run final security, dependency, and secret review | `NOT STARTED` | P18-T02, P13-T07 | — |
| P18-T04 | Execute final production acceptance and cleanup | `NOT STARTED` | P18-T03, P17-T06, P16-T06 | — |
| P18-T05 | Create release candidate, publish, and hand off | `NOT STARTED` | P18-T04 | — |

### 41.3 Expected verification commands after scaffolding

The final repository can use equivalent wrapper scripts, but these commands must remain available or be mapped explicitly:

```bash
mix deps.get
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
mix test
mix credo --strict
mix dialyzer
mix sobelow --config
mix hex.audit
mix assets.build
MIX_ENV=prod mix release
docker build -t pumble-automation:"$(git rev-parse --short HEAD)" .
git diff --check
git status --short
```

Rules:

- Do not invent a command before its tool exists.
- Do not treat a skipped or unavailable required command as success.
- Live Pumble tests require an explicit, separate command and sacrificial workspace.
- A release receipt must bind command results to the exact Git SHA and container digest.

---

## 42. Full production acceptance matrix

### Scenario A — Pumble event trigger

**Setup:** Activate a workflow: `NEW_MESSAGE -> condition(text contains "urgent") -> add reaction -> send message`.

**Execution:**

1. Post one controlled human message.
2. Verify signature acceptance and normalized event.
3. Verify one received-event row and indexed trigger match.
4. Verify execution binds the active immutable version.
5. Verify condition branch and both Pumble effects.
6. Verify final state and timeline.

**Pass:**

- one documented execution;
- correct provider IDs;
- no secret/private raw-body log;
- execution timeline explains the branch and effects.

### Scenario B — durable delay through deployment

**Setup:** `manual trigger -> delay -> send message`.

**Execution:**

1. Start workflow.
2. Confirm durable `WAITING` state and scheduled Oban job.
3. terminate/replace the application;
4. restart/deploy exact compatible release;
5. wait past deadline.

**Pass:**

- no volatile timer is required;
- the workflow resumes once according to documented semantics;
- duplicate wake jobs no-op;
- history shows scheduled and actual resume times.

### Scenario C — HTTP request and branch

**Setup:** `webhook -> GET controlled public test server -> condition(response.status/body) -> true/false Pumble messages`.

**Execution:** Run one success and one nonmatching response.

**Pass:**

- URL passes SafeHttp policy;
- response is bounded/extracted;
- exactly the selected branch runs;
- unselected branch has no step/effect.

### Scenario D — durable approval

**Setup:** `manual trigger -> approval -> approved message`.

**Execution:**

1. Create approval.
2. Confirm durable pending record, timeout job, and Pumble buttons.
3. Restart application.
4. Approve as an authorized user.
5. Repeat the click and attempt as an unauthorized user.

**Pass:**

- first valid decision wins;
- duplicate/stale click is safe;
- unauthorized user cannot decide;
- execution follows the approve branch once.

### Scenario E — bounded transient retry

**Setup:** HTTP action with a controlled endpoint that fails safely twice, then succeeds, using a proven idempotency contract or safe method.

**Pass:**

- attempts and backoff are recorded;
- retry count is bounded;
- one completed step/output exists;
- no duplicate completed effect.

### Scenario F — permanent failure

**Setup:** Action returns a confirmed non-retryable configuration/provider error.

**Pass:**

- no infinite retry;
- step/execution reaches explicit failure state;
- safe diagnostic and remediation are visible;
- no next node runs.

### Scenario G — duplicate Pumble event

**Execution:** Deliver the exact same stable provider event concurrently and again after the first commits.

**Pass:**

- one received-event identity;
- documented number of executions/effects, normally one per matching binding;
- duplicates are observable without replaying effects.

### Scenario H — worker race

**Execution:** Two workers claim/finalize the same current node using a deterministic test barrier.

**Pass:**

- one attempt owns finalization;
- stale worker no-ops;
- graph/context is not corrupted;
- no duplicate external write beyond documented ambiguity semantics.

### Scenario I — tenant isolation

**Execution:** Authenticate as workspace B and supply IDs for workspace A across every UI route, context function, webhook, approval, job, secret, workflow, and execution.

**Pass:**

- not found/denied;
- no data, timing-dependent detail, or mutation disclosure;
- security telemetry contains no private data.

### Scenario J — SSRF and rebinding

**Execution:** Attempt localhost, RFC1918, link-local, metadata, IPv4-mapped IPv6, mixed DNS, DNS rebind, and redirect into blocked space.

**Pass:**

- blocked before prohibited socket connection;
- redirect repeats validation;
- DNS-pinned transport retains approved destination;
- original hostname still controls TLS/Host validation.

### Scenario K — installation lifecycle

**Execution:** Install, authorize, sign in a second member, run a workflow, reinstall with scope change, revoke one authorization, uninstall, and optionally reinstall during grace period.

**Pass:**

- credentials and roles are correct;
- token replacement is atomic;
- missing scopes degrade only affected workflows;
- uninstall blocks new work and purges credentials immediately;
- retention/deletion state matches policy.

### Scenario L — interactive timing

**Execution:** Exercise slash command, global/message shortcut, approval button, and retained modal/view interaction through the production proxy.

**Pass:**

- each uses its live-proven response sequence;
- required response completes within the Pumble deadline with operational margin;
- accepted state is durable where required;
- no double response or timeout UI.

### Scenario M — ambiguous external write

**Execution:** Force a connection loss after a non-idempotent write may have reached a controlled server.

**Pass:**

- no automatic blind retry;
- execution enters `PAUSED_UNCERTAIN`;
- owner sees sanitized evidence;
- mark-success, stop, and deliberate-retry paths each behave once and audit the decision.

### Scenario N — browser session and role revocation

**Execution:** Sign in as editor, open LiveView, revoke/downgrade membership from another authorized session, then reconnect/attempt mutation.

**Pass:**

- revoked session or capability is enforced server-side;
- reconnect does not retain unauthorized access;
- workflow data from other workspaces is never exposed.

### Scenario O — schedule, DST, and misfire

**Setup:** Daily/weekly workflow in a zone with DST transition.

**Execution:** Verify normal occurrence, spring gap, fall overlap, application downtime, restart, and deactivation race.

**Pass:**

- documented DST policy is followed;
- occurrence key prevents duplicates;
- misfire policy is bounded;
- next run derives from scheduled instant;
- deactivation blocks unclaimed future occurrences.

### Scenario P — backup restore

**Execution:** Restore a backup containing an active version, waiting delay, pending approval, due schedule, execution history, Oban jobs, and encrypted credentials to isolation.

**Pass:**

- exact release boots;
- integrity checks pass;
- encrypted data can be safely resolved with recovery keys;
- no live external effect occurs;
- durable jobs/states are present.

### Scenario Q — automation loop protection

**Execution:** Activate a message-triggered workflow that sends a message matching its own trigger, then test a controlled A→B→A lineage.

**Pass:**

- own-bot/default filtering and lineage/resource ceilings stop amplification;
- diagnostic identifies loop protection;
- no unbounded executions, messages, or jobs.

### Matrix evidence rule

Each scenario record must contain:

- exact Git SHA and image digest;
- workflow/version IDs or sanitized hashes;
- relevant execution/job IDs;
- command or operator steps;
- assertions and results;
- timestamps;
- cleanup proof;
- links/paths to logs, screenshots, or database-safe evidence;
- explicit `PASS`, `FAIL`, or `BLOCKED`.

A scenario is not passed by a checklist tick without evidence.

---

## 43. Rollback and recovery procedures

### 43.1 Bad application release

1. Stop rollout or remove new instances from traffic.
2. Keep PostgreSQL and Oban data intact.
3. Deploy the previously proved image digest.
4. Confirm the prior image supports current expanded schema.
5. Run readiness, callback, UI, queue, delay, and approval smoke checks.
6. Record affected executions and reconciliation results.
7. Do not roll back the database destructively during the ordinary application rollback window.

### 43.2 Failed migration

1. Keep the old application serving.
2. Prevent the new image from becoming ready.
3. Capture migration version and redacted error.
4. Correct the forward migration or restore only when corruption requires it.
5. Do not manually mark migrations applied.
6. Re-run on a restored/staging database before production.

### 43.3 Signature verification outage

1. Confirm raw bytes through proxy and configured signing-secret version.
2. Do not disable verification to restore traffic.
3. Compare a controlled signed fixture at proxy and app boundary.
4. Correct proxy/config/secret deployment.
5. Reconcile only callbacks Pumble proves it retried or that can be safely replayed.

### 43.4 Pumble credential revocation or scope loss

1. Stop using the affected credential immediately.
2. Mark authorization/installation degraded or revoked.
3. Disable workflows with known missing scopes.
4. Direct an owner through reinstall/authorization.
5. Revalidate active versions after new scope snapshot.
6. Never copy tokens manually into the database.

### 43.5 Queue backlog or exhausted jobs

1. Inspect queue age, error classes, database health, and concurrency.
2. Pause the affected queue if repeated effects may be unsafe.
3. Fix the root cause.
4. Requeue only steps whose retry safety is proved.
5. Move ambiguous write attempts to uncertainty.
6. Run bounded reconciliation and confirm queue recovery.

### 43.6 Uncertain external effect

1. Stop automatic progression.
2. Gather provider correlation/effect key and sanitized evidence.
3. Check the remote system through an authorized independent method where available.
4. Owner selects assume success, stop/fail, or deliberate retry.
5. Audit the choice and preserve prior attempts.
6. Never edit the state directly in SQL.

### 43.7 Bad workflow activation

1. Deactivate the workflow to stop new triggers.
2. Do not mutate the bad immutable version.
3. Let existing executions follow documented continue/cancel policy.
4. Correct the draft or reactivate a prior valid version.
5. Verify bindings/schedules and run dry/live test.

### 43.8 Broken schedule

1. Disable the schedule/workflow.
2. Inspect timezone, next/last occurrence, dispatcher lag, and occurrence keys.
3. Correct and activate a new version.
4. Apply the documented misfire policy; do not create ad hoc catch-up executions.
5. Verify next occurrences.

### 43.9 Data loss or corruption

1. Stop writes when continued operation could worsen damage.
2. Preserve logs, image digest, schema version, and backup identifiers.
3. Restore to isolation and verify integrity.
4. Select restore/PITR point under owner incident authority.
5. Reconcile Pumble/external effects using durable ledgers and uncertainty semantics.
6. Do not overwrite the only remaining backup.

### 43.10 Encryption-key rotation or loss

- Rotation: configure new primary plus old read key, deploy, batch-reencrypt, verify counts, then remove old key only after rollback window.
- Loss: encrypted credentials/secrets are unrecoverable without the key; require reinstall/re-entry. Do not invent a bypass.
- Never print keys during diagnosis.

### 43.11 Uninstall and deletion recovery

- During 30-day non-secret grace period, reinstall may reconnect retained workflows only through the documented policy and fresh credentials.
- After purge, recovery requires a new tenant unless a separately approved backup/legal process applies.
- Credentials and user secrets are never retained for grace-period convenience.

---

## 44. Remaining post-release opportunities

These are not part of the perfect production core and must not block release:

1. A visual graph canvas backed by the same AST/compiler, only after usability data proves the outline editor is inadequate.
2. Additional proven Pumble actions such as edit message, channel management, files, or scheduled-message features.
3. Native connectors for Clockify, Plaky, Linear, GitHub, Google services, or others, each implemented as a normal validated node.
4. Natural-language workflow drafting that produces the same AST and passes the same validator; it never executes directly.
5. Workflow import/export with signed/redacted secret references and compatibility validation.
6. Reusable templates and tenant-local template library.
7. Richer usage analytics, billing, and plan quotas after real demand.
8. Controlled loops/iteration only with a clear product need, explicit finite bounds, and new execution semantics.
9. Web/worker deployment separation only after measured contention.
10. Multi-node/region scaling only after real capacity, latency, and availability evidence.
11. Advanced approval groups/escalations only after Pumble identity/group behavior is proven.
12. Additional external HTTP authentication schemes and certificate options only after a concrete customer need and security review.

Each opportunity requires a new contract decision, threat-model update, migration/rollback plan, tests, and acceptance scenarios.

---

## 45. Final definition of done

### Product

- A workspace can install and sign in through Pumble.
- Local owner/editor/viewer authorization is enforced.
- Users can create, edit, validate, dry-run, activate, deactivate, version, and inspect workflows.
- Fixed Pumble events and manual entry points trigger the correct active version.
- Conditions, branches, delays, schedules, approvals, Pumble actions, generic HTTP, and stop behave as documented.
- Execution history is understandable and sanitized.
- Connections, secrets, members, audit, and settings are operable.
- Reinstall, unauthorized, uninstall, retention, and deletion behavior is correct.

### Durability and correctness

- PostgreSQL is authoritative.
- Every runnable transition has durable work.
- Delays, schedules, approvals, and queued work survive restart/deployment.
- Duplicate callbacks/jobs and worker races preserve invariants.
- Executions bind immutable versions.
- Retries are bounded and classified.
- Ambiguous non-idempotent writes pause uncertain.
- Cancellation and reconciliation require no routine SQL surgery.

### Security

- Pumble signatures use exact raw bytes and constant-time comparison.
- OAuth state is single-use and sessions are secure/revocable.
- Credentials and secrets use authenticated encryption and are redacted.
- Tenant isolation passes the complete matrix.
- Generic HTTP passes SSRF/DNS-rebinding/redirect/size/timeout tests.
- Webhooks, approvals, loops, payloads, and rates are bounded.
- Production exposes no debug/admin backdoor.
- Zero unresolved critical/high security or dependency findings.

### Operations

- Configuration fails closed.
- Health/readiness distinguish process, database, schema, and durable-work health.
- Logs and metrics diagnose behavior without leaking content.
- Maintenance, retention, and reconciliation are durable and observable.
- Container/release/migrations are reproducible.
- Graceful and forced shutdown recovery is proved.
- Backup restore and application rollback are proved.
- Runbooks are executed in staging.

### UI and documentation

- The workflow outline editor is polished and complete without a required canvas.
- Core paths work by keyboard and at narrow viewport.
- Role and error states are clear.
- No secret is rendered or readable after write.
- User-facing text does not overpromise exactly-once behavior.
- Local development, architecture, semantics, deployment, backup, Marketplace, privacy, and troubleshooting docs match the implementation.

### Quality

- Exact clean Git commit passes the full offline gate.
- No warning, failing, skipped core test, dead production code, speculative abstraction, placeholder correctness TODO, or unnecessary dependency remains.
- Migrations replay from empty database.
- Static analysis, security audit, asset build, release build, container build, and secret scans pass.
- Repository is understandable to a new engineer and a weak implementation model.

### Release

- Exact candidate passes live Pumble install, events, interactions, actions, lifecycle, and end-to-end certification.
- Production deployment and rollback pass.
- Backup restore evidence is current.
- Public manifest is HTTPS, minimal-scope, and secret-free.
- Marketplace/pre-publication package is truthful and complete.
- Test residue is zero.
- Commit, tag, pushed ref, image digest, deployment, manifest, migrations, certification, and submission state are recorded.
- If an external owner-controlled release step is unavailable, the only remaining status is precisely `BLOCKED`; the implementation itself has no unresolved core production requirement.

The system is complete only when this definition and all applicable task completion gates are supported by current evidence for one exact release candidate.
