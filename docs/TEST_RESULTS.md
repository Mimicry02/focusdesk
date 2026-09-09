# Verification record — Focusdesk v1.0

## Passed locally

- `npm test`: 12 tests. Validasi task allowlist, dates/time bounds, konflik jadwal, escaping HTML, ekspor UTC/ICS, trusted Origin, cron secret, request body, admin API guard, inactive-account denial, HttpOnly cookie session, no token JSON.
- `npm run build`: public assets copied successfully.
- JavaScript syntax checks on all modules.
- `scripts/test-sql.mjs` using local PostgreSQL engine PGlite: schema applied twice without failure; inactive-by-default Auth trigger; signup metadata cannot grant admin; per-user RLS; admin cannot read other tasks; column grant prevents role escalation; role RPC guard/self-protection; Top 3; task version/completion timestamps; midnight constraints; inactive denial; digest claim deduplication.

## Not yet verified against your infrastructure

- Vercel production function compilation/deployment, cookies on your domain.
- Hosted Supabase Auth invitation/recovery and token refresh behavior with your settings.
- Actual SMTP/Resend delivery, domain verification, cron invocation timing.
- Browser visual/end-to-end testing and multi-session concurrency load tests.

The SQL test uses a minimal auth.users/auth.uid stub in local PostgreSQL. It verifies SQL/RLS behavior but does not emulate Supabase Auth's entire service. Source API tests use mocked provider responses. No production credentials, SMTP account, or user data were accessed.

## After deployment — essential smoke test

1. Login admin A. Create task A, refresh, verify persistence.
2. Invite user B. In a separate browser session, set password and login. Ensure A's task is absent; create task B.
3. Ensure user B has no User management access; admin A cannot see B's task in task views.
4. Deactivate B from admin. B's next refresh/API operation must fail and clear the workspace view.
5. Reactivate B and login again; their task should remain.
6. Edit the same task in two tabs. Saving the stale version should display a conflict, not overwrite silently.
7. Test Forgot password/Change password after SMTP setup.
8. Configure optional briefing, send once, verify provider/inbox, and verify a second same-day request is skipped.
9. Import one calendar test event; confirm time in WIB. Clean up the calendar event manually afterwards.
