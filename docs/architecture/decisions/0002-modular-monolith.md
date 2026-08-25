# ADR-0002: Modular monolith

**Status:** Accepted

## Context

The add-on must ingest Pumble callbacks, persist workflow state, run durable
executions, and serve a browser UI. The deployment must stay simple and must hold
a strong transaction boundary between ingestion and execution state.

## Evidence

- `docs/contract/product_contract.md` defines one cohesive add-on with callback,
  workflow, execution, and browser interfaces.
- `lib/pumble_automation/application.ex` supervises the endpoint, repository, and
  durable job runtime as one application.
- `docs/contract/dependency_policy.md` and `mix.exs` keep PostgreSQL and Oban as
  the durable infrastructure dependencies; Redis, Kafka, RabbitMQ, and Temporal
  are not runtime dependencies.

## Decision

Build one Elixir/Phoenix application with internal context boundaries. Ingress,
Workflows, Executions, Installations, Connections, Pumble, Audit, and Web are
modules in one deployable unit that share one PostgreSQL database.

Cross-context calls follow the context boundaries recorded in this ADR and the
product contract. Browser and callback callers do not bypass tenant-scoped
contexts to query tenant tables directly.

## Alternatives

- Microservices per context. Rejected: it removes the single transaction boundary
  and adds operational cost with no proven need.
- Distributed BEAM cluster with cross-node coordination. Rejected: durability comes
  from PostgreSQL, not from process state (see ADR-0005).

## Consequences

- Event ingestion and job insertion can share one `Ecto.Multi`.
- Module boundaries are enforced by interfaces and static checks, not by a network.
- Horizontal scaling is by stateless application replicas over one database.
- A move to a separate deployable unit must update this architecture record and
  its tests.

## Reversal condition

Reconsider if one context needs an isolated runtime, an isolated datastore, or an
independent release cadence that the single database and single release cannot
serve, and the need is shown by measurement rather than by prediction.
