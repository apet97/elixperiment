# ADR-0008: LiveView outline editor

**Status:** Accepted
**Plan decision:** ADR-008 in plan Section 7

## Context

Users must build, validate, activate, operate, and diagnose workflows in a browser.
The editor must show the workflow structure and must not add a second front-end
stack before it is proved necessary.

## Evidence

- Plan Section 7, row ADR-008: "LiveView outline editor — product quality without
  premature React/canvas complexity".
- Plan Section 9: LiveView UI is a component of the single application.
- Plan Section 6: free-form canvas editing is an explicit non-goal.
- Plan Section 8: Phoenix LiveView is in the dated dependency snapshot.
- Plan Section 33: UI and UX plan.
- Plan phase gate P12 (Section 41.1): authorized users can create, validate,
  activate, operate, and diagnose workflows with an accessible UI, proved by
  LiveView, browser, role, accessibility, and reconnect tests.

## Decision

Build the workflow editor and the operations UI with Phoenix LiveView. The editor
presents the workflow as an ordered outline of steps with nested named branches,
which matches the AST of ADR-0004.

There is no drag-and-drop canvas, no separate single-page application, and no
client-side workflow engine. Validation and compilation stay on the server.

## Alternatives

- A React or Svelte single-page application. Rejected: it adds a second stack, a
  second state model, and a second authorization surface with no proved need.
- A free-form graph canvas. Rejected: it is a non-goal, and it does not match a
  tree AST with no merges or jumps.

## Consequences

- The UI needs LiveView reconnect behavior and server-side authorization on every
  event, because a hidden field or a route prefix is never authorization.
- Rendering of stored content must be escaped, and a content security policy is
  required (plan Section 27, stored content injection).
- Accessibility and browser tests belong to phase P12.
- Adding a client-side framework requires a new ADR.

## Reversal condition

Reconsider if a contract-approved editing interaction cannot reach an acceptable
latency or accessibility standard in LiveView, shown by a measurement.
