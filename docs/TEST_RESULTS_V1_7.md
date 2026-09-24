# Focusdesk 1.7 validation

Validated locally on 2026-09-24. No real OpenAI requests, Telegram messages, account changes, or production deployment were performed. API provider tests use mocks; SQL uses PGlite; screenshots use demo data.

- 50 Node unit/API tests passed: existing auth/task/PIC/report/recurrence/scheduler behavior; AI disabled/no-source avoids provider calls; strict response parsing; unknown citations rejected; provider errors/refusal/incomplete responses; no secret in prompt/config; persisted-answer reuse; origin and admin authorization.
- PostgreSQL behavioral test passed with v1.7 migration replay: scoped Published retrieval, append-only reports/notes, reviewer workflow, service-only RPC access, workspace-isolated health, one-time atomic daily reservation, exhausted-cap rejection, source archival revalidation, follow-up queue, no status rollback after task escalation/resolution.
- Browser integration passed: Workspace cards and dashboard navigation, Knowledge Desk setup, AI status/connection button (mock), Markdown import, master save, escaped read-only reports, member Reports-only navigation, support demo flow, desktop/mobile width checks. Desktop and mobile screenshots visually reviewed.
- Build copied public assets successfully; syntax and release bundle are checked before delivery.

Limit: live key/model access, API billing/quota, real Telegram webhook and production cron require post-deployment UAT. “Konfigurasi siap” and preview screenshots are not proof of an active customer integration. Node test runtime available here is Node 24; deployment declares the existing Node 22 target. New APIs used (fetch, AbortSignal.timeout) are supported by the target; no direct Node 22 runtime test was available.

Release verification: archive version/files, no .env/dependencies/build output, byte equality for SQL, single transactions, fresh install plus older-version upgrade and v1.6 incremental replay checked by scripts/test-release-v17.mjs.
