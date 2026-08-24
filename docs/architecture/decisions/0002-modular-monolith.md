# ADR-0002: Modular monolith

**Status:** Accepted
**Plan decision:** ADR-001 in plan Section 7

## Context

The add-on must ingest Pumble callbacks, persist workflow state, run durable
executions, and serve a browser UI. The deployment must stay simple and must hold
a strong transaction boundary between ingestion and execution state.

## Evidence

- Plan Section 7, row ADR-001: "Modular monolith — simplest deployable architecture
  and strongest transaction boundary".
- Plan Section 9: one Phoenix endpoint, one Ingress path, one PostgreSQL database,
  one execution path, and one LiveView UI in a single application.
- Plan Section 9.2: allowed domain dependencies are expressed as in-application
  context boundaries, not as network services.
- Plan Section 6: microservices, distributed BEAM clustering, Kubernetes, Redis,
  Kafka, RabbitMQ, and Temporal are explicit non-goals.

## Decision

Build one Elixir/Phoenix application with internal context boundaries. Ingress,
Workflows, Executions, Installations, Connections, Pumble, Audit, and Web are
modules in one deployable unit that share one PostgreSQL database.

Cross-context calls follow the allowed dependency list in plan Section 9.2. The
forbidden edges in that section are forbidden at any time.

## Alternatives

- Microservices per context. Rejected: it removes the single transaction boundary
  and adds operational cost with no proven need.
- Distributed BEAM cluster with cross-node coordination. Rejected: durability comes
  from PostgreSQL, not from process state (see ADR-0005).

## Consequences

- Event ingestion and job insertion can share one `Ecto.Multi`.
- Module boundaries are a code-review and static-check duty, not a network duty.
- Horizontal scaling is by stateless application replicas over one database.
- Any move to a separate deployable unit requires a new ADR.

## Reversal condition

Reconsider if one context needs an isolated runtime, an isolated datastore, or an
independent release cadence that the single database and single release cannot
serve, and the need is shown by measurement rather than by prediction.
