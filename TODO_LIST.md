---
title: "TODOs"
---

# Right Now

1. Availability table bugs (see `BUG_LIST.md`): beginning-hour adjuster not reacting to taps; reinstate adjuster on the next-week availability table without coupling it to the default template.
2. Wire employees to device contacts / WhatsApp / phone number for bulk messaging.
3. Refine the week-generation error messages produced by `run_schedule`.
4. Export history / export analytics (surface analytics + edit log data in the export sheet).
5. Tighten the Exceptions (overrides) UX for date ranges — still tedious.

# Done since last sweep

- Analytics dashboard (`AnalyticsView` + `AnalyticsViewModel`)
- History tab flattened assignments (spec `2026-04-09-history-tab-flat-assignments-design.md`)
- Manual "commit" workflow replaced by auto-save + Edit Log (spec `2026-04-17-auto-save-activity-log-design.md`)
- Wildcard (null-role) shifts and wildcard employee role coverage
- Employee shift history view
- PDF export (weekly, by-role, per-employee)

# Local, by-device, pay-once service

- Icon
- CI/CD runner with Xcode 26 available (currently `macos-15` is too old for Swift jobs)
- UX polish on onboarding

# Fully fledged rota service (future)

- Security review
- Linux desktop target

# Cross-cutting

- More extensible theming
- Onboarding setup + instruction service
- Additional analytics (cost forecasting, utilisation)
- Export → auto CSV → PDF print pipeline
