# UI acceptance criteria

This document separates executable UI coverage from checks that still require a
real browser or assistive technology. An unchecked box means **not manually
verified**; it is not an automated-test result.

| Proof layer | Status | Evidence |
| --- | --- | --- |
| LiveView interaction and browser-state fixtures | Automated | `./scripts/verify-ui.sh` and `test/browser/` |
| Keyboard, viewport, and screen-reader spot checks in a real browser | Not verified | Manual criteria below |
| axe-core or equivalent scan | Not run | No scanner was added |
| Real Chromium console review | Not verified | Remains outside the offline gate |

Representative viewports: **360** (mobile), **768** (tablet), **1280** (desktop).
The authenticated shell stacks the sidebar above content below `lg` (1024px).

## Keyboard

- [ ] Skip link (`#skip-to-main`) is the first focusable control and moves
      focus to `#main-content`.
- [ ] Primary navigation is a `nav` with `aria-label="Primary"`. Current page
      uses `aria-current="page"`.
- [ ] Theme buttons are a labelled group; the active choice has `aria-pressed`.
- [ ] Every form control has a visible label (`<label for>` / `<.input>`).
- [ ] Destructive actions open a dialog. Escape and the cancel control dismiss
      it without mutating. Confirm is a separate control.
- [ ] Outline reorder has visible **Up** / **Down** buttons. Drag is optional;
      if drag fails, keyboard reorder still works.
- [ ] Focus rings use the copper `--color-focus` token (`:focus-visible`).

## Screen reader and semantics

- [ ] One `h1` per page (via `<.header>`). Section titles are `h2`/`h3`.
- [ ] Landmarks: `aside#app-shell-sidebar` (Workspace), `header#app-shell-topbar`,
      `main#main-content`, `nav#app-shell-nav`.
- [ ] Status uses a text label plus a colour dot (`aria-hidden` on the dot).
- [ ] Field errors are `role="alert"` and referenced from the control with
      `aria-describedby` / `aria-invalid`.
- [ ] Modals are `role="dialog"` + `aria-modal="true"` + `aria-labelledby`.
- [ ] Decorative icons are `aria-hidden="true"`.
- [ ] Tables (if used) have a visually hidden caption and an Actions column
      header for screen readers.
- [ ] Flash and reconnect banners are polite live regions; client/server
      disconnect copy does not expose stack traces.

## Viewport and motion

- [ ] 360px: sidebar stacks, headers wrap, cards wrap actions, pagination wraps,
      long names truncate (`truncate` / `pa-break`), no horizontal page scroll.
- [ ] 768px: filters go two-column where marked `sm:`; dialogs sit centered.
- [ ] 1280px: sidebar is a left rail (`lg:grid-cols-[15rem_minmax(0,1fr)]`).
- [ ] Empty, loading, and error states share `min-height` (`.pa-state`) so the
      layout does not jump.
- [ ] `prefers-reduced-motion: reduce` disables decorative animation and the
      topbar progress animation.

## Reconnect and secrets

- [ ] Disconnect banner appears; reconnect remounts from the server.
- [ ] Unsaved editor outline is discarded on remount; saved outline is restored.
- [ ] Activation / cancel / delete confirmations do not survive remount and do
      not fire the mutation.
- [ ] Secret values are write-only: absent after submit, absent after remount,
      `autocomplete="new-password"`, never in list HTML.
- [ ] CSP: `script-src 'self'` only. No inline scripts. No mixed content.

## Visual statuses

Spot-check Connected / Limited / Disconnected, Draft / Active / Inactive,
Queued / Running / Waiting / Paused / Failed / Cancelled / Completed, and
Saved / Saving / Unsaved / Conflict. Colour is never the only signal.

Long and translated-like names must remain in one column without covering
actions.

## P15-T06 automated acceptance

The UI runner is `Phoenix.LiveViewTest`. Command: `./scripts/verify-ui.sh`
(`mix test test/pumble_automation_web/live --trace` then
`mix test test/browser --trace`). Discoverable journeys live in
`test/browser/acceptance_journey_test.exs`. Unique canaries are
`CANARY-P15T06-…`. Axe was not selected. Wallaby/Playwright were not added.

Automated proofs (desktop layout classes plus the stacked `lg:` narrow shell):

- Fake-Pumble install callback → `#onboarding-page[data-state=installed_empty]`
- Keyboard create, nested condition/stop edit, two-session conflict, remount
- Validate, dry-run, activate, execution timeline, cancel
- Owner uncertainty resolve; viewer cancel denied server-side
- Canary secret absent from HTML and captured logs
- Connections, members, audit, sign-out
- Skip link, primary nav, CSP `script-src 'self'`, `/assets/js/app.js` and
  `/assets/css/app.css` HTTP 200, no inline `<script>`

Colour-only visual statuses and a real Chromium console remain P18-T01.
