# ADR-0007: Fixed Pumble command and shortcuts

**Status:** Accepted

## Context

Users create and delete workflows at any time. Pumble manifest entries are
installation configuration and are registered when the app is installed. The two
lifetimes are different.

## Evidence

- `docs/contract/product_contract.md` defines one slash command, one global
  shortcut, and one message shortcut whose registrations do not vary per workflow.
- `PumbleAutomation.Pumble.Manifest` defines the fixed entries and callback URLs.
- The callback classifier covers slash command, global shortcut, message shortcut,
  block interaction, view action, and bounded dynamic-menu handling.

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
- No manual entry point at all. Rejected: manual entry is part of the product
  contract.

## Consequences

- Alias uniqueness must be enforced per workspace and trigger type.
- Alias collision behavior and picker visibility are product rules, not manifest
  rules.
- A manifest version or scope change requires a reinstall, so it is never silent.
- If the command name is unavailable, use another fixed name and document the
  manifest migration path.

## Reversal condition

Reconsider only if Pumble supports dynamic per-workspace command registration
without reinstall, proved by a probe.
