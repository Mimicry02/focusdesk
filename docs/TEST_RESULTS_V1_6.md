# Focusdesk v1.6 — validation

Local validation, 21 September 2026. Not a live production deployment test.

- Node unit/mock API suite: 42 passing. Covers existing auth, PIC, reporting, recurrence, Telegram actions/scheduler plus Markdown parsing, query normalization, group request routing, bot addressing, scope revalidation and uncertain delivery.
- PGlite SQL integration: additive migration applied twice; seed idempotency; cross-workspace master rejection; Published-only and group-scoped search; immutable original report and append-only notes; authenticated direct writes denied; reporter callback authorization; repeated callback creates only one task; PIC/reviewer workflow and status notifications; callback payload <=64 bytes; revoked access and service-only RPC.
- Browser tests with mocked APIs: master application form save, Markdown upload, escaped report text, no editable report fields, member-only Reports navigation, mobile width, no page JavaScript errors.
- Static build copies public files to dist. Vercel functions remain in api/.

Node execution here uses the provided Node 24 runtime; deployment declares Node 22. No Node-24-only APIs introduced. Database behavior was tested on embedded PostgreSQL, not on the user's hosted instance. Telegram transport in tests is mocked; perform acceptance checklist in KNOWLEDGE_DESK.md after deployment.
