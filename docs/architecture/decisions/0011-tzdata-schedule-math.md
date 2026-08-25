# ADR-0011: tzdata for schedule timezone math

**Status:** Accepted
**Date:** 2026-08-18

## Context

Schedule triggers fire at local times in an IANA timezone. Interval clocks must
not drift when a worker runs late. Daily and weekly clocks must have an explicit
policy for DST gaps and overlaps. Elixir's standard library can convert zones
only through a `Calendar.TimeZoneDatabase`, and the default database is UTC-only.

## Evidence

- `docs/contract/dependency_policy.md` permits the pinned tzdata runtime dependency.
- `PumbleAutomation.Workflows.ScheduleCalculator` stores IANA timezone IDs, uses
  the first valid instant after a gap, and uses the earlier occurrence once for an
  ambiguous local time.
- Schedule calculator tests prove that the same config, reference, and tzdata
  version yield the same UTC result without server-local timezone dependence.

## Decision

Schedule next-instant calculation uses the `tzdata` Hex package, pinned at
**1.1.4** (IANA release **2026b**), as Elixir's `Calendar.TimeZoneDatabase`.

Automatic IANA downloads are disabled. The packaged database is the only source
of zone data, so a given config, reference, and tzdata version stay deterministic
across nodes and restarts.

tzdata declares a hard dependency on hackney for those downloads. This
application never calls that client. hackney is overridden to **4.0.3** so that
`mix hex.audit` does not fail on the 1.x line tzdata asks for, or on the
vulnerable `quic` that hackney 4.0.1 pulled.

## Alternatives

- Keep the UTC-only Calendar database and store only UTC instants. Rejected:
  daily/weekly local times and DST policy cannot be computed.
- Enable tzdata autoupdate. Rejected: a mid-run IANA download would change
  results for the same config and reference.
- Vendor IANA files and implement `Calendar.TimeZoneDatabase` locally. Rejected:
  a hand-rolled parser would be a second timezone database.

## Consequences

- `PumbleAutomation.Workflows.ScheduleCalculator` is the only module that
  performs timezone arithmetic. Activation and the dispatcher consume it later.
- Unknown timezones and invalid local-time configuration are validation errors.
  A runtime tzdata failure is a retryable dependency error.
- hackney, h2, and quic enter the lockfile as unused-at-runtime transitive
  dependencies of tzdata. They must stay pinned to advisory-clean releases.
- Updating tzdata or its IANA release is a dedicated dependency change with
  changelog review, because DST results can change.

## Reversal condition

Reconsider if a maintained timezone library provides IANA data without a
vulnerable HTTP client, or if Elixir ships a non-UTC Calendar database that
covers the documented DST policy. Revalidate the dependency pin and schedule
tests after a change.
