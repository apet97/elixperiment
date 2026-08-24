# Documentation

Technical documentation for the independent Pumble Workflow Automation
experiment. References to Pumble or CAKE.com describe compatibility only; they
do not imply affiliation, endorsement, sponsorship, or maintenance.

For current behavior, use the source, tests, accepted architecture decisions,
and the product contract. Files under [`archive/`](archive/) preserve build
history and may describe earlier or superseded states.

## Product and contract

- [Product contract](contract/product_contract.md) — supported triggers, nodes,
  management capabilities, and non-goals.
- [Delivery semantics](architecture/delivery_semantics.md) — at-least-once
  behavior, retries, and `PAUSED_UNCERTAIN`.
- [Retention model](product/retention.md) — data lifetimes and deletion rules.
- [UI acceptance criteria](product/ui_acceptance.md) — automated coverage and
  remaining manual browser checks.

## Architecture and engineering

- [Architecture decisions](architecture/decisions/README.md)
- [Dependency and coding policy](contract/dependency_policy.md)
- [Verification model](engineering/verification.md)

## Operations

- [Operations index](operations/README.md)
- [Local development](operations/local_development.md)
- [Deployment boundary](operations/deployment.md)
- [Migration](operations/migrations.md) and
  [rollback](operations/rollback.md)
- [Incidents](operations/incidents.md) and
  [uncertain external effects](operations/uncertain_effects.md)

## Security

- [Threat requirements](contract/threat_model.md)
- [Implemented threat closure](security/threat_model.md)
- [Security review record](security/review_results.md)
- [Guarded HTTP action review](security/http_action_review.md)

## Evidence

- [Evidence index](evidence/README.md)
- [Pumble source matrix](evidence/pumble_source_matrix.md)
- [Protocol probe register](evidence/pumble_probe_register.md)
- [Read-only API-key contract snapshot](evidence/pumble_api_key_live_contract.md)
- [Runbook game day](evidence/runbook_game_day.md)

## Historical records

The [archive](archive/) contains the initial assessment, implementation plan,
agent prompt, initial-state inventory, and implementation ledger. These files
are retained for traceability; they are not current product status and grant no
authority to change, publish, deploy, or submit anything.
