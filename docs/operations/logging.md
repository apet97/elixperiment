# Structured logging

Application logs are operational data. They correlate a request or job
without copying private content. Retention, access, and export live in the
log drain — not in this application.

## Production format

One JSON object per line. The production handler uses
`PumbleAutomation.Logging` as the Erlang logger formatter. `LOG_LEVEL`
selects the level (`debug`, `info`, `notice`, `warning`, `error`, …) without
a code change. The default is `info`.

Dev and test keep Elixir’s text formatter.

## Schema

Every field below is optional. Absent and null values are omitted. Values are
scalars: strings, or integers for `duration_ms` and `content_bytes`.

| Field | Meaning |
|---|---|
| `ts` | UTC timestamp, ISO-8601 with microseconds |
| `level` | Logger level |
| `msg` | Short event name (`oauth.callback`, `pumble.callback`, `pumble.action`, `http.action`, `approval.decision`, `execution.uncertain`, `health.ready`, `health.check`, `exception`) |
| `request_id` | HTTP `Plug.RequestId` |
| `correlation_id` | Domain correlation (OAuth audit id, Pumble client correlation) |
| `provider_id` | Pumble `x-request-id` / provider request id |
| `installation_id` | Tenant |
| `workflow_id` | Workflow |
| `version_id` | Immutable workflow version |
| `execution_id` | Run |
| `step_id` | Step execution |
| `attempt_id` | Attempt |
| `job_id` | Oban job id |
| `operation` | Named action (`post_message`, `GET`, `oauth.callback`, …) |
| `duration_ms` | Elapsed milliseconds |
| `status` | Outcome (`ok`, `error`, `approved`, `paused_uncertain`, …) |
| `error_code` | Stable code or class |
| `error_class` | Error taxonomy class |
| `event_type` | Callback class, node type, or domain label |
| `content_bytes` | Diagnostic mode only: byte length of a hashed payload |
| `content_sha256` | Diagnostic mode only: SHA-256 of that payload |

No other keys are written. Redaction runs before JSON encoding.

## Never logged

- OAuth codes, state tokens, session tokens, client secrets
- App key, signing secret, bot/user access tokens
- Workflow secret values
- `Authorization` / `token` / cookie / webhook signature headers
- Raw callback bodies, Pumble message text, rendered templates
- HTTP request or response bodies

Phoenix `filter_parameters` covers framework request logs. Callback and
webhook routes also set `log: false`.

## Diagnostic mode

`PumbleAutomation.Logging.enable_diagnostics/2` requires a tenant actor id
(`:authorized_by`) and expires automatically (15 minutes default, one hour
maximum). While it is on, logs may add `content_bytes` and `content_sha256`.
They still never add the content.

## Retention and access

Treat the drain as sensitive operational data. This application does not
store log lines. Platform IAM, retention (suggested 30 days), and export
policy are defined outside the release.
