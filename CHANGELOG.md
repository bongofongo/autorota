# Changelog

All notable changes to autorota.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- release-plz will populate entries here from conventional-commit messages. -->

## [0.9.2] - 2026-07-23

### Added

- Edit Log rework: collapsible week/month/year island groups; a full-detail page
  for every save (saved time, day(s) affected, diff-scoped summary, tags,
  restore, complete change list) with abbreviated summary-only entries in the
  list; save source badges (Generation / Regeneration) backed by a new `source`
  column, with generation saving immediately; diff enrichment — assignment
  changes carry shift times, and mirrored moves collapse into a single swap
  shown with both shifts and counted once.

### Fixed

- Edit Log now refreshes live via data-change notifications instead of only on
  open/pull-to-refresh.
- "View full details" was hard to tap (top-level tap gesture swallowed child
  taps; NavigationLink nested in a multi-button row).

### Internal

- Wired previously-orphaned migration 026 (saves rota_id index); new migration
  027 (save source).
