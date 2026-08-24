# ADR-0007: Fixed Pumble command and shortcuts

**Status:** Accepted
**Plan decision:** ADR-007 in plan Section 7

## Context

Users create and delete workflows at any time. Pumble manifest entries are
installation configuration and are registered when the app is installed. The two
lifetimes are different.

## Evidence

- Plan Section 7, row ADR-007: "Fixed Pumble command and shortcuts — manifest
  registrations are static".
- Plan Section 5.1, "Manual Pumble entry": static manifest entries are one slash
  command (proposed `/workflow`), one global shortcut (proposed `Run workflow`), and
  one message shortcut (proposed `Run workflow on message`). An active workflow may
  declare a unique manual alias and whether it appears in each picker.
- Plan Section 12.2: callback classes include slash command, global shortcut,
  message shortcut, block interaction, view action, and dynamic menu.
- Plan Section 12.2: dynamic-menu handling stays synchronous and bounded and is used
  for product UI selection.

## Decision

The Pumble manifest registers exactly one slash command, one global shortcut, and
one message shortcut. These entries never change when a user creates, edits,
renames, activates, or deletes a workflow.

User workflows route behind those fixed entries. An active workflow may declare a
manual alias that is unique within a workspace and trigger type, and may declare
whether it appears in each picker. Selection is served by the dynamic menu and the
view/block callback classes.

## Alternatives

- Register one slash command per workflow. Rejected: the manifest is installation
  configuration, so each workflow change would need a manifest change and a
  reinstall.
- No manual entry point at all. Rejected: manual entry is part of the frozen product
  contract (plan Section 5.1).

## Consequences

- Alias uniqueness must be enforced per workspace and trigger type.
- Alias collision behavior and picker visibility are product rules, not manifest
  rules.
- A manifest version or scope change requires a reinstall, so it is never silent.
- If a proposed command name is unavailable, the change needs a new ADR and a
  manifest migration plan (plan task P1-T02).

## Reversal condition

Reconsider only if Pumble supports dynamic per-workspace command registration
without reinstall, proved by a probe.
