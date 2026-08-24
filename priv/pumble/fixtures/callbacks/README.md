# Callback fixtures

One sanitized callback envelope per class, exactly as it arrives on the wire:
the JSON object Pumble POSTs to `/pumble/callbacks`, with an event's `body` kept
as the JSON **string** it really is (evidence section 2.3), so a test that
encodes a fixture produces bytes of the same shape a real callback has.

Every identifier is obviously fake (`W_FAKE001`, `U_FAKE001`, `TRIG_FAKE001`,
`example.invalid`). No fixture contains a token, a signature, or a real
workspace.

## Provenance

Shapes come from `docs/evidence/pumble_source_matrix.md`. The matrix rows below
are SDK-source-verified (`SUPPORTED`): they prove the field **names and types**
of each class. They do not prove which optional fields a live server actually
sends, or what a value looks like, so every concrete *value* here is `INFERRED`
by this plan and every fixture is a shape test rather than a recording.

| File | Class | Matrix rows |
|---|---|---|
| `event_new_message.json` | `C-1` event, `NEW_MESSAGE` | `C-1`, `E-1`, envelope 2.3 |
| `event_updated_message.json` | `C-1` event, `UPDATED_MESSAGE` | `C-1`, `E-2` |
| `event_reaction_added.json` | `C-1` event, `REACTION_ADDED` | `C-1`, `E-3` |
| `event_channel_created.json` | `C-1` event, `CHANNEL_CREATED` | `C-1`, `E-4` |
| `event_workspace_user_joined.json` | `C-1` event, `WORKSPACE_USER_JOINED` | `C-1`, `E-5` |
| `event_app_uninstalled.json` | `C-1` event, `APP_UNINSTALLED` | `C-1`, `L-1` |
| `event_app_unauthorized.json` | `C-1` event, `APP_UNAUTHORIZED` | `C-1`, `L-2` |
| `slash_command.json` | `C-2` slash command | `C-2`, `I-3` |
| `global_shortcut.json` | `C-3` global shortcut | `C-3`, `M-4`, `I-4` |
| `message_shortcut.json` | `C-4` message shortcut | `C-4`, `M-4`, `I-4` |
| `block_interaction_view.json` | `C-5` block interaction, `VIEW` | `C-5`, `I-5`, `X-6` |
| `block_interaction_message.json` | `C-6` block interaction, `MESSAGE` | `C-6`, `I-5` |
| `block_interaction_ephemeral_message.json` | `C-7` block interaction, `EPHEMERAL_MESSAGE` | `C-7`, `I-5` |
| `view_action_submit.json` | `C-8` view action, `SUBMIT` | `C-8`, `I-6` |
| `view_action_close.json` | `C-8` view action, `CLOSE` | `C-8`, `I-6` |
| `dynamic_menu.json` | `C-9` dynamic menu | `C-9`, `K-4`, `I-7` |

## Deliberate choices in the values

- The two lifecycle bodies use full field names and the five trigger bodies use
  the abbreviated ones. That difference is real (`L-1`, `L-2` notes) and the
  fixtures keep it, because an adapter that assumes one naming style passes a
  test suite built on either style alone.
- `event_app_uninstalled.json` encodes `uninstalledAt` as epoch milliseconds.
  The SDK types it `Date` and the wire encoding is **not proven** (`L-1` note),
  so the normalizer accepts an ISO 8601 string too and falls back to the receive
  time for anything else.
- `messageType` is `PUMBLE_EVENT` on the trigger events and `APP_EVENT` on the
  lifecycle events. Which value the server uses for which event is
  `PROBE REQUIRED` (`PR-16`, `X-3`); both classify identically, and the split
  here exists so that both values stay exercised.
- Every block interaction carries `loadingTimeout: 0`, which is the value this
  application emits on the elements it produces (`X-6`).
- `event_new_message.json` carries both `ts` and `tsm`. `tsm` is the field the
  normalizer reads; `ts` is present so a change that starts reading it is
  visible in a test rather than in production.
