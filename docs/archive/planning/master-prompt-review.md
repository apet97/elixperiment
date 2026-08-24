# Master Prompt Review and Revised Planning Prompt

> [!WARNING]
> Historical planning record from before the application was implemented.
> It does not describe current status and grants no authority for external
> actions. See the [current documentation](../../README.md).

## Verdict

The supplied master prompt is already unusually strong. It defines the product, source hierarchy, durability model, failure windows, security boundaries, implementation granularity, progress ledger, and release gates. Its strongest feature is that it refuses false “exactly once” claims and requires the planner to distinguish facts, inferences, unknowns, and proof.

The prompt is not weak because it lacks detail. Its main problem is that it contains too much repeated instruction, while a few high-impact product and protocol decisions remain implicit. A strong planning model can work through the repetition. A weaker planning model may instead optimize for checklist completion, repeat the prompt back, or produce a huge but internally inconsistent document.

The revised prompt below keeps the original standard while making the execution contract clearer and adding the missing boundaries.

## What the original prompt gets right

### Evidence before architecture

The prompt requires the planner to inspect the current state before planning work. It also gives a useful hierarchy: supplied Pumble material, repository source, executable tests, current official dependency documentation, and then labelled inference. This prevents a greenfield rewrite when code already exists.

### Correct durability model

The statement “PostgreSQL is durable truth” is the right center of gravity. The prompt correctly rejects sleeping processes, long-lived timers, and volatile BEAM state as the source of truth for workflow progress, schedules, and approvals.

### Precise treatment of delivery semantics

The prompt explicitly lists the important crash windows around external side effects. That is much better than vague “make it idempotent” language. It also forbids unprovable exactly-once claims.

### Appropriate architecture bias

A Phoenix modular monolith, Ecto, PostgreSQL, and Oban are a good default. The prompt correctly rejects Redis, Kafka, Temporal, Kubernetes, microservices, and similar infrastructure unless requirements prove the need.

### Good implementer constraints

The prompt understands that a weak coding model cannot invent transaction boundaries, retry semantics, module ownership, or completion gates. It requires tasks to carry the reasoning.

### Production scope

The prompt does not stop at an MVP. It covers OAuth, uninstall, deployment, backup and restore, observability, marketplace preparation, live certification, and rollback.

## Problems that reduce effectiveness

### 1. Repetition competes with the actual decisions

The prompt repeats “do not overengineer,” “do not invent capabilities,” “do not stop at MVP,” and similar rules many times. These are correct, but repetition consumes attention that should be reserved for the hard decisions.

**Correction:** keep one engineering-principles section and make every later section refer to it instead of repeating it.

### 2. The output contract is too large without a two-pass method

The prompt asks for source reconstruction, dependency research, architecture, threat modelling, persistence modelling, failure-window modelling, and a 45-part final artifact in one pass. A model may start writing the final document before it has resolved the architecture.

**Correction:** require an internal decision pass first, then the final plan. The final artifact must include the evidence and decisions, but the planner must not draft the task list before the architecture and invariants are stable.

### 3. Static Pumble manifest constraints are not converted into a product rule

Pumble slash commands, shortcuts, event subscriptions, block interaction URLs, view action URLs, and dynamic-menu registrations are manifest-level declarations. A workflow product cannot safely promise that users may create arbitrary new slash-command names or arbitrary new Pumble shortcuts at runtime.

**Correction:** make the initial product use a fixed shared slash command, fixed global/message shortcuts, and static subscribed events. User workflows route through aliases or selections inside those fixed entry points.

### 4. Web-application identity and authorization are missing

The prompt describes a workflow-management web UI but does not define how a Pumble user authenticates to it, how a workspace is selected, how sessions are revoked, or who may create and activate workflows.

**Correction:** require an explicit browser authentication and authorization design. The default should use Pumble OAuth or one-time Pumble-issued launch links, durable revocable sessions, and simple workspace roles.

### 5. “Unknown outcome” needs a first-class durable state

The prompt discusses a process dying immediately after an external side effect, but the conceptual state machine only shows completed, failed, and cancelled states. For non-idempotent Pumble and HTTP writes, retrying after an ambiguous timeout may duplicate the effect.

**Correction:** require an explicit `PAUSED_UNCERTAIN` or equivalent state, an operator resolution path, and per-action retry-safety classification.

### 6. The workflow representation can be simpler than a general graph

The prompt permits an AST or graph, but several sections assume general graph validation. A free-form node graph creates unnecessary complexity: cycles, fan-in, graph editing, merge semantics, and hard-to-explain execution pointers.

**Correction:** prefer a structured, loop-free workflow AST for v1. Compile it into a normalized execution graph. Conditions and approvals own nested branches. This gives deterministic semantics and a simpler outline editor.

### 7. The generic HTTP action needs a concrete DNS-rebinding design

The prompt lists SSRF and DNS rebinding, but it does not require address pinning. Resolving a host, validating the IP, and then connecting by hostname leaves a rebinding window.

**Correction:** resolve once, reject all blocked addresses, choose a validated address, connect to that IP while preserving the original hostname for TLS SNI and certificate verification, and repeat the process for every redirect.

### 8. Data retention and privacy defaults are unspecified

The product will process message text, user identifiers, request bodies, HTTP responses, execution inputs, and tokens. “Do not leak secrets” is necessary but not enough.

**Correction:** require a data classification, field-level redaction rules, default retention periods, uninstall retention, deletion execution, and backup-expiry behavior.

### 9. The plan needs an explicit change-control mechanism

A weak implementer may discover a conflict and silently alter the architecture.

**Correction:** require an architecture decision log. A plan-changing decision must cite evidence, explain the smallest change, update dependent tasks, and preserve completed evidence.

### 10. Version research should produce a dated snapshot, not permanent truth

The prompt asks for current dependency versions. A reusable plan may be executed months later.

**Correction:** record the version snapshot date and require one revalidation task before scaffolding or upgrading. Do not allow opportunistic upgrades during unrelated tasks.

### 11. UI quality is underspecified

The prompt correctly defers a visual canvas, but “usable UI” can still result in a rough internal tool.

**Correction:** add accessibility, responsive behavior, empty/error/loading states, keyboard operation, execution-status clarity, and a small visual acceptance gate. Keep the implementation LiveView-first.

### 12. External mutation authority is unclear

The planning prompt says not to implement. The later implementation prompt must separately define whether the agent may edit, commit, push, deploy, and release.

**Correction:** keep the planning prompt read-only. Put mutation authority only in the implementation prompt.

## Changes applied in the revised prompt

The revised version:

- keeps the supplied five-file corpus as the primary Pumble evidence;
- retains evidence-first, state-aware, idempotent planning;
- turns static manifest behavior into a product constraint;
- adds browser authentication, workspace authorization, and session lifecycle;
- makes uncertain external outcomes a first-class state;
- chooses a structured AST compiled into a graph;
- requires DNS pinning for the generic HTTP action;
- adds data classification and retention;
- adds architecture-decision change control;
- separates planning authority from implementation authority;
- preserves the weak-implementer task format;
- reduces repeated prohibitions.

---

# Revised Master Planning Prompt

## Role and mission

Act as the senior Elixir/Phoenix engineer responsible for producing the canonical implementation plan for a production Pumble workflow-automation add-on.

The product is:

> When a supported trigger occurs, evaluate deterministic logic and perform one or more durable actions.

The result is a focused, Pumble-native automation product. It is not a clone of Zapier and it must not depend on AI, arbitrary user code, plugins, microservices, or distributed infrastructure.

Do not implement the application in this planning session.

Create one canonical file:

`PUMBLE_WORKFLOW_AUTOMATION_PERFECT_END_STATE_IMPLEMENTATION_PLAN.md`

The file must be sufficient for a weaker coding model to continue from any repository state without inventing architecture or core semantics.

## Mandatory source material

Read these files completely and in order:

1. `01-overview-and-project-map.md`
2. `02-core-framework-auth-and-runtime.md`
3. `03-api-clients-and-v1-type-system.md`
4. `04-events-contexts-interactivity-and-blocks.md`
5. `05-cli-examples-docs-and-deployment.md`

Treat the supplied Pumble corpus as the primary evidence for Pumble behavior.

Also inspect all available project files, repository source, tests, prior plans, and deployment artifacts.

Do not assume greenfield and do not assume implementation exists.

## Evidence hierarchy

Use this order:

1. supplied Pumble corpus for Pumble-specific behavior;
2. current repository source for implemented behavior;
3. tests and executable evidence;
4. current official Elixir, Erlang/OTP, Phoenix, LiveView, Ecto, Postgrex, PostgreSQL, Oban, Req/Mint, and selected dependency documentation;
5. current official Pumble material where a supplied fact needs verification;
6. clearly labelled inference.

Record conflicts. Do not silently choose a convenient source.

For every important conclusion, distinguish:

- `FACT`
- `INFERENCE`
- `UNKNOWN / REQUIRES PROBE`

## State-aware planning rule

For every capability:

- if absent, plan its implementation;
- if present but unproved, plan verification before replacement;
- if present and wrong, plan the smallest remediation;
- if present and proved correct, mark it complete;
- never rewrite working code merely because another design is possible.

The plan must remain reusable after some phases have been completed.

## Engineering principles

Apply these in order:

1. correctness;
2. simplicity;
3. durability;
4. security;
5. testability;
6. maintainability;
7. operational clarity;
8. product quality.

Use a modular monolith unless evidence disproves it.

Prefer boring infrastructure.

Do not add speculative abstractions, dead code, unused extension points, arbitrary interfaces, generic frameworks, or infrastructure for hypothetical scale.

Every dependency and abstraction must solve a current demonstrated problem.

Use ASD-STE100 principles for user-facing text.

Use evidence-backed hypotheses and the weakest valid hypothesis.

## Default technical direction

Start from this hypothesis and change it only with evidence:

- Elixir;
- Phoenix;
- Phoenix LiveView;
- Ecto;
- PostgreSQL;
- Oban;
- one deployable application;
- one PostgreSQL database;
- HTTP callbacks for production Pumble transport;
- no Redis, Kafka, RabbitMQ, Temporal, Kubernetes, Elasticsearch, or microservices.

PostgreSQL is durable truth.

BEAM processes coordinate work but do not own durable workflow state.

Oban executes durable asynchronous work. Insert jobs transactionally with related database changes.

Record a dated dependency-version snapshot and include a revalidation gate before implementation pins versions.

## Pumble protocol facts that must shape the architecture

Account explicitly for:

- the seven documented Pumble subscribed events;
- the distinction between Pumble events, slash commands, global shortcuts, message shortcuts, block interactions, view actions, dynamic menus, internal schedules, and generic inbound webhooks;
- the three-second acknowledgement requirement for slash commands, shortcuts, block interactions, and view actions;
- dynamic menus returning an options response rather than a normal acknowledgement;
- raw-body HMAC-SHA256 signature verification and constant-time comparison;
- OAuth state/CSRF protection;
- bot and user credentials;
- durable multi-workspace token storage;
- `token` and `x-app-token` API headers;
- 401, 403, 404, 429, 5xx, and timeout handling;
- manifest secret stripping;
- production HTTPS;
- reinstall, authorization change, revocation, and uninstall;
- HTTP being the default production transport unless evidence proves Socket Mode is required.

Do not clone the TypeScript SDK. Implement a narrow Elixir adapter for only the product-required Pumble behavior.

## Static manifest constraint

Treat Pumble manifest registrations as static product capabilities.

Do not promise runtime creation of arbitrary Pumble slash-command names, shortcuts, event subscription types, or callback registrations.

The default product design should use:

- one fixed workflow slash command;
- one fixed global shortcut;
- one fixed message shortcut;
- fixed interaction and view callback routes;
- a fixed set of subscribed supported events.

User-created workflows may use aliases or selections behind these fixed entry points.

If evidence supports a different mechanism, document it.

## Product contract

The production system must support:

### Triggers

- supported Pumble events;
- the fixed slash-command/manual entry point;
- the fixed global/message shortcuts where useful;
- schedules;
- secure generic inbound webhooks;
- explicit test/manual execution.

Treat `APP_UNINSTALLED` and `APP_UNAUTHORIZED` as lifecycle control events, not ordinary user workflow triggers, unless evidence proves a product need.

### Logic

- condition;
- AND, OR, NOT;
- true/false branch;
- delay;
- approval branches;
- stop.

Do not add loops in v1.

### Actions

Start with a small proven set:

- send Pumble message;
- reply to a triggering or referenced message;
- direct-message a user;
- add reaction;
- remove reaction;
- generic external HTTP request.

Add edit-message or channel-management actions only after scope and idempotency behavior are proven.

### Management

- browser workflow UI;
- Pumble-native onboarding and quick entry points;
- draft editing;
- validation;
- activation and deactivation;
- immutable executable versions;
- execution history;
- safe retry and cancellation;
- uncertain-outcome resolution;
- secrets and connections;
- role-based workspace access;
- audit trail.

## Browser identity and authorization

Design explicitly:

- how a Pumble user signs in to the web UI;
- OAuth and one-time launch-link behavior;
- durable revocable sessions;
- session expiry and rotation;
- workspace selection;
- the initial workspace owner;
- simple roles such as owner, editor, and viewer;
- who may create, activate, deactivate, retry, cancel, resolve uncertain steps, manage secrets, and view payloads;
- how uninstall and authorization revocation invalidate sessions;
- CSRF protection and LiveView authorization checks.

Do not assume Pumble role strings until verified.

## Workflow representation

Prefer a structured, typed, loop-free AST for the editable definition.

Example shape:

- one trigger;
- ordered steps;
- condition nodes with true and false child sequences;
- approval nodes with approved, rejected, and timeout child sequences;
- delay, action, and stop nodes.

Every node has a stable ID.

Compile the AST into a normalized immutable executable graph. The compiler must produce explicit node lookup, edges, required scopes, trigger bindings, and a definition hash.

Do not create a general free-form graph editor in the production core.

## Validation and activation

Activation must:

1. load the latest draft revision;
2. validate the full definition;
3. compile it;
4. calculate required scopes and referenced secrets/connections;
5. persist a new immutable workflow version;
6. replace active trigger bindings and schedule bindings atomically;
7. set the workflow active version;
8. enqueue any required durable work inside the same transaction;
9. emit an audit event.

Reject unsupported nodes, malformed branches, duplicate node IDs, missing references, impossible templates, invalid schedules, missing secrets, missing connections, known missing scopes, oversized definitions, and unreachable compiled nodes.

## Durable execution model

Design exact states for executions, steps, attempts, approvals, and jobs.

The execution state machine must include an explicit uncertain state, such as:

- queued;
- running;
- waiting for delay;
- waiting for approval;
- paused uncertain;
- completed;
- failed;
- cancelled.

An execution always references one immutable workflow version.

Each logical step has one durable step record. Each try has a separate attempt record.

Use a claim-execute-finalize pattern:

1. transactionally claim the expected current step;
2. execute pure logic or the external operation;
3. transactionally persist the outcome and enqueue the next job.

A stale or duplicate job must become a no-op.

## Delivery, idempotency, and uncertain effects

Assume queues and callbacks are at least once.

Design for duplicate events, duplicate jobs, races, process death, timeouts, and ambiguous external outcomes.

Use:

- durable ingress deduplication keys;
- unique execution keys;
- unique `(execution, node)` step records;
- stable per-step effect keys;
- attempt records;
- row locks or optimistic locks;
- Oban uniqueness as an optimization, not the only invariant.

Do not claim exactly once.

Classify every external action as:

- safe to retry;
- safe only with a remote idempotency key;
- unsafe after an ambiguous outcome.

If a write may have succeeded but cannot be proved, move the step and execution to `PAUSED_UNCERTAIN`. Do not automatically repeat the effect. Provide an audited operator path to mark it succeeded, mark it failed, or retry explicitly.

## Event ingestion and trigger matching

Keep controllers and plugs as transport boundaries.

The intended flow is:

1. apply size limit;
2. retain raw bytes;
3. verify signature or webhook secret;
4. parse and validate the envelope;
5. normalize Pumble wire fields;
6. derive a durable deduplication key;
7. persist the received event;
8. find indexed active trigger bindings for the workspace and trigger kind;
9. create executions and enqueue first jobs transactionally;
10. acknowledge according to the Pumble interaction contract.

For interactive requests, keep the durable pre-ack transaction small enough to meet the three-second deadline. If durable acceptance cannot be recorded, return an explicit failure rather than a false success.

Do not scan every workflow in a workspace.

## Templates and conditions

Do not create a programming language.

Use structured condition JSON produced by the UI.

Support a small operator set:

- equality and inequality;
- numeric and datetime comparison;
- contains, starts-with, ends-with;
- membership;
- presence;
- AND, OR, NOT.

Use deterministic path references such as `trigger.message.text` and `steps.<node_id>.output.<field>`.

Template strings may interpolate path references and secret references. Missing-value behavior must be explicit. Bound expression depth, template size, output expansion, and context size.

## Delays and schedules

Delays must use durable database state and scheduled Oban jobs.

Recurring schedules should use a small typed schedule model rather than arbitrary cron text unless requirements prove cron is necessary.

Define:

- supported schedule types;
- timezone;
- DST gap behavior;
- DST ambiguity behavior;
- next-run calculation;
- duplicate-run key;
- pause, resume, edit, deactivate, and cancellation semantics;
- maximum delay and execution lifetime.

A deployment or process restart must not lose delayed or scheduled work.

## Approval

Approval is durable execution state.

Define:

- Pumble message and buttons;
- opaque signed decision payload;
- stored one-time decision nonce or digest;
- allowed approvers;
- authorization check;
- duplicate decision behavior;
- approved, rejected, and timeout branches;
- expiry;
- restart behavior;
- cancellation;
- audit history.

## Generic HTTP action

Support only HTTP and HTTPS.

Define method, URL, query, headers, JSON or text body, timeouts, maximum sizes, status handling, output extraction, retry policy, and secret interpolation.

SSRF protection must:

1. parse and normalize the URL;
2. reject userinfo and unsupported schemes;
3. resolve all A and AAAA addresses;
4. reject loopback, private, link-local, multicast, unspecified, documentation, carrier-grade NAT, and cloud metadata ranges;
5. select a validated public address;
6. connect to that IP while preserving the original hostname for the Host header, TLS SNI, and certificate verification;
7. stream the response with a hard byte cap;
8. disable automatic decompression;
9. disable automatic redirects;
10. revalidate and repin every redirect;
11. limit redirects;
12. block sensitive hop-by-hop and proxy headers.

Do not rely on a resolve-then-connect-by-hostname sequence.

## Secrets and data handling

Workflow definitions reference secret IDs, never secret values.

Use authenticated encryption with versioned keys.

Jobs contain IDs only, not credentials or message bodies unless necessary.

Define a data classification for:

- credentials and secrets;
- message content;
- webhook bodies;
- HTTP request/response bodies;
- execution context;
- audit metadata;
- logs and metrics.

Define default retention and deletion behavior for received events, execution history, audit history, revoked credentials, uninstalled workspaces, and backups.

## Multi-tenancy

Workspace isolation is a hard invariant.

Every tenant object contains the installation/workspace key.

Every context API receives a trusted workspace scope.

Queries, mutations, jobs, LiveViews, approval callbacks, webhook endpoints, secrets, audit records, and support tools must enforce it.

Do not rely on UI filtering and do not use unscoped primary-key fetches for tenant objects.

Include adversarial cross-workspace tests.

## Loop protection

By default, ignore events authored by the installation bot.

Use bot tokens for workflow Pumble actions unless a user token is explicitly required.

Track execution lineage and enforce a hard depth ceiling.

If the user enables app-generated-message triggers, show a warning and retain the hard ceiling.

Use only Pumble metadata that is actually documented or live-proved.

## UI strategy

Use Phoenix LiveView for the initial management UI.

Build an outline editor for the structured workflow AST, not a canvas.

The UI must include:

- workflow list and status;
- create/edit draft;
- trigger configuration;
- ordered step insertion;
- nested condition and approval branches;
- validation errors linked to nodes;
- test mode;
- activation and deactivation;
- version history;
- execution list and detail;
- sanitized step and attempt history;
- retry, cancel, and uncertain-outcome resolution;
- secrets and connections;
- workspace members and roles;
- onboarding.

Include keyboard behavior, labels, focus management, loading, empty, failure, and responsive states. Add a graph/canvas only after semantics are stable and user evidence justifies it.

## Dependencies

For each non-core dependency, record:

- exact version snapshot;
- purpose;
- why standard Elixir/OTP/Phoenix is insufficient;
- maintenance and compatibility evidence;
- removal or fallback strategy.

Prefer mature dependencies. Do not add libraries for trivial code.

## Repository boundaries

Derive exact names from the repository, but the expected domains are:

- Installations;
- Pumble;
- Workflows;
- Ingress;
- Executions;
- Connections;
- Audit;
- Web boundary.

Define allowed dependencies and persistence ownership.

Avoid both a giant service module and an interface for every module.

Use behaviours only for real substitution boundaries, especially external Pumble and HTTP transports in tests.

## Observability and operations

Plan structured logs, correlation IDs, execution IDs, step IDs, job IDs, error classes, queue health, retries, uncertain effects, Pumble latency/failures, HTTP latency/failures, and per-workspace usage.

Do not log tokens, secret values, raw authorization headers, or full private payloads by default.

Define:

- liveness;
- readiness with database and queue checks;
- graceful shutdown;
- migration strategy;
- backup and restore;
- retention jobs;
- deployment rollback;
- workflow-version rollback;
- support diagnostics with audited access.

## Testing

Tests must prove invariants.

Include:

- pure compiler, condition, template, schedule, and transition tests;
- database and transaction tests;
- tenant-isolation tests;
- Pumble adapter contract fixtures;
- a fake Pumble API;
- generic HTTP SSRF tests;
- LiveView authorization tests;
- Oban testing;
- process-death and duplicate-job tests;
- approval races;
- uncertain-outcome tests;
- restart/deploy delay tests;
- live certification against a sacrificial Pumble workspace.

Normal CI must not need live Pumble access.

## Required probes

Create an explicit probe matrix for all unproved Pumble behavior, including:

- OAuth token expiry and refresh behavior;
- reinstall token replacement;
- authorization and uninstall event ordering;
- stable delivery IDs for every callback type;
- signature header details;
- interaction acknowledgement bodies;
- rate-limit headers and retry guidance;
- Pumble write idempotency support;
- bot-message identity and loop metadata;
- exact scopes for each selected action;
- payload and file limits;
- user role values;
- marketplace callback and launch behavior.

Unknowns must not silently become architecture.

## Plan-writing method

Before writing detailed tasks:

1. reconstruct current state;
2. write source coverage;
3. write fact/inference/unknown matrix;
4. freeze product contract and non-goals;
5. freeze architecture decisions;
6. define schemas and invariants;
7. define state machines and failure semantics;
8. define threat model;
9. define phase dependency graph;
10. only then write tasks.

## Task format

Use stable IDs such as `P4-T03`.

Each major task must include, where relevant:

- status;
- objective;
- why now;
- existing state;
- exact files/modules to inspect, add, change, or delete;
- implementation changes;
- invariants;
- failure behavior;
- security considerations;
- tests;
- verification commands or live proof;
- completion gate;
- dependencies;
- evidence field for future updates.

Do not create thousands of tiny tasks. Use the smallest useful reasoning unit.

## Progress ledger and change control

Include a ledger with:

- task ID;
- status: `NOT STARTED`, `IN PROGRESS`, `BLOCKED`, `COMPLETE`, `REVERIFY`;
- dependency IDs;
- evidence;
- commit or artifact reference;
- notes.

A task becomes complete only after its gate passes.

Add an architecture decision log. If implementation evidence requires changing the plan, the implementer must:

1. record the conflict;
2. cite evidence;
3. choose the smallest correction;
4. update affected tasks and acceptance tests;
5. preserve completed evidence;
6. never silently drift.

## Required final structure

The canonical plan must contain:

1. executive summary;
2. source coverage;
3. current-state assessment;
4. fact/inference/unknown matrix;
5. product contract;
6. explicit non-goals;
7. architecture decision log;
8. dated dependency snapshot;
9. final architecture;
10. repository boundaries;
11. browser identity and authorization;
12. Pumble protocol and client design;
13. OAuth and installation lifecycle;
14. data model and retention;
15. workflow AST and compiler;
16. validation and activation;
17. ingress and trigger matching;
18. execution, step, and attempt state machines;
19. idempotency and uncertain-outcome semantics;
20. Oban job model and transaction boundaries;
21. conditions and templates;
22. delays and schedules;
23. approvals;
24. Pumble actions;
25. generic HTTP action and SSRF design;
26. multi-tenancy;
27. loop protection;
28. error taxonomy and retry matrix;
29. resource limits;
30. security threat model;
31. UI/UX plan;
32. observability;
33. testing architecture;
34. deployment and migrations;
35. backup, restore, and rollback;
36. live Pumble certification;
37. marketplace and release process;
38. phase dependency graph;
39. detailed ordered tasks;
40. acceptance matrix;
41. progress ledger;
42. final definition of done;
43. post-release opportunities that are not on the critical path.

## Final standard

The plan is defective if the implementer must invent:

- a domain boundary;
- a database owner;
- a state transition;
- a transaction boundary;
- a retry rule;
- an uncertain-outcome rule;
- a security decision;
- an authorization rule;
- a test oracle;
- a completion gate;
- a dependency order.

Do not optimize for an impressive architecture.

Produce the smallest coherent production system whose important behavior is durable, secure, understandable, and proved.
