# ADR-0001: Record template

**Status:** Template (not a decision)

Copy this file to `NNNN-short-title.md`. Use the next free number. Keep the record
short. Keep each section present, even when the answer is one line.

---

# ADR-NNNN: <short decision title>

**Status:** Proposed | Accepted | Superseded by ADR-NNNN
**Date:** YYYY-MM-DD

## Context

State the problem and the constraints. Name the system boundary that the decision
affects. Do not describe the solution here.

## Evidence

List the sources that support the decision. Cite probe IDs, measurements, current
source code, tests, or contract documents. State unproved items as open probes,
not as facts.

## Decision

State the decision in the present tense. One decision per record. State what the
decision forbids as well as what it allows.

## Alternatives

List the alternatives that were considered. For each one, state why it was rejected.

## Consequences

State the results of the decision. Include the costs and the new obligations, not
only the benefits. Name the tests, interfaces, or documents that the decision constrains.

## Reversal condition

State the exact condition under which this decision must be reconsidered. The
condition must be observable, for example a failed probe, a measured limit, or a
platform change. Update the record or add a replacement when that condition occurs.
