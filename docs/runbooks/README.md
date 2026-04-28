# Operational runbooks

One-page playbooks for incidents and rare maintenance tasks. Keep each runbook
**actionable** (commands, file paths, decision points) — not a tutorial. Link
to it from CLAUDE.md, GitHub issue templates, or chat when the situation
applies.

| Runbook | When to reach for it |
|---|---|
| [db-corruption-recovery.md](db-corruption-recovery.md) | App fails to launch with a database error, or `DatabaseRecoveryView` is shown on launch. |
| [sync-divergence.md](sync-divergence.md) | Two devices show different employees / shifts / assignments and sync is enabled. |
| [hot-fix-release.md](hot-fix-release.md) | A correctness bug is in production and we need to ship a patch outside the normal release-plz cadence. |
| [customer-data-extraction.md](customer-data-extraction.md) | A user needs their data exported from a corrupted DB or an old schema. |
