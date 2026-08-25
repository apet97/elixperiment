# ADR-0008: LiveView outline editor

**Status:** Accepted

## Context

Users must build, validate, activate, operate, and diagnose workflows in a browser.
The editor must show the workflow structure and must not add a second front-end
stack before it is proved necessary.

## Evidence

- `docs/contract/product_contract.md` defines the browser workflow editor and
  excludes a free-form graph canvas.
- Phoenix LiveView is the browser stack in `mix.exs`; editor events call the
  tenant-scoped workflow contexts.
- LiveView and role tests cover the tenant-scoped server-rendered workflow
  journeys. Structural accessibility checks and reconnect tests are automated.
  Real-browser keyboard, viewport, screen-reader, axe, and console checks remain
  unverified in `docs/product/ui_acceptance.md`.

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
  required (`docs/security/threat_model.md`).
- LiveView and structural accessibility tests are local gates. The manual
  browser matrix remains explicit in `docs/product/ui_acceptance.md`.
- Adding a client-side framework must update this architecture record and its
  tests.

## Reversal condition

Reconsider if a supported editing interaction cannot reach an acceptable
latency or accessibility standard in LiveView, shown by a measurement.
