# Architecture — Focusdesk 1.5.0

## Tambahan scheduler

Stack production tetap HTML/CSS/JS, Node 22 Vercel Functions, Supabase Auth/Postgres, dan Telegram Bot API. Tidak mengganti framework atau database. Supabase Cron + pg_net memanggil endpoint yang sudah ada setiap menit karena Vercel Hobby tidak memberi presisi menit; Vault menyimpan origin dan CRON_SECRET. Detail konfigurasi ada pada SCHEDULER_GUIDE.

Flow: cron HTTP ber-Bearer secret → allowlist mode → fd_tg_schedule memakai clock DB WIB → lock tanggal/slot dan insert run unik → materialisasi recurrence → outbox ringkasan/kartu → fd_tg_claim → kirim grup → kartu dengan depends_on menunggu tick berikutnya → validasi ulang task/role/username → kirim DM. Normal event-notification tetap berjalan; saat materialisasi scheduler event-card sementara ditekan agar tidak menggandakan kartu pagi. Activity tetap dicatat.

| File/table | Struktur / tugas |
| --- | --- |
| supabase/08_scheduled_briefings.sql | Migrasi data/function; tidak mengaktifkan cron |
| supabase/09_enable_telegram_scheduler.sql | Aktivasi Cron terpisah setelah deploy + Vault siap |
| server/briefing.js | Formatter bounded + expiry WIB, tanpa I/O |
| api/telegram-cron.js | GET authenticated, modes schedule/morning/evening/queue; tidak menerima clock dari query |
| fd_tg_schedule_runs | PK(day date, slot text), created_at timestamptz, materialized/summaries/cards int; service only, RLS |
| fd_tg_scheduler_health | id boolean PK check true, last_tick_at/last_generated_at timestamptz, last_slot text; service only |
| fd_telegram_outbox | Tambahan schedule_slot text nullable check morning/evening, depends_on uuid FK ke outbox ON DELETE SET NULL; kind menerima briefing |
| fd_tg_schedule(text,timestamptz) | Service-only clock injection untuk test/recovery; endpoint hanya meneruskan slot |
| fd_tg_briefing_data(uuid,uuid,date) | Service-only owner+group scope, active profiles/group, non-Done, full counts + top 5 per bucket |

Periode morning 09.00–17.29, evening 17.30–23.59, tidak ada catch-up morning setelah 17.30. Run log 180 hari. Outbox pending/failed expiry diperiksa saat claim; expiry dicek lagi tepat sebelum send. Payload dibaca saat dispatch, bukan snapshot jam jadwal. depends_on melepas card setelah parent sent/skipped/uncertain atau failed lima percobaan; tidak memblokir pribadi selamanya bila grup gagal. Provider timeout tetap uncertain, tidak retry otomatis.

Security: numeric pairing/username dan role guard v1.4 dipertahankan. Tidak ada grant RPC baru untuk browser. API Settings mengekspos timestamp health, bukan konfigurasi Vault atau daftar task global. Pengujian memakai mock HTTP/PGlite; pg_cron/pg_net/Vault live memerlukan verifikasi operator.

## Arsitektur dasar dan aturan coding yang dipertahankan


## Stack dan struktur

Vanilla HTML/CSS/ES modules; Node 22 Vercel Functions; Supabase Auth + PostgreSQL/PostgREST; Telegram Bot API; ExcelJS 4.4.0; Resend opsional. Tidak ada bot polling process, frontend secret, atau dependency AI.

| Folder/file | Tanggung jawab |
| --- | --- |
| public/index.html, css/ | Shell dan tampilan Focusdesk |
| public/js/app.js | State, modal task, settings/pairing, workflow, reports |
| public/js/workflow.js | Enum status, aksi/label UI dan bot; bukan enforcement keamanan |
| public/js/api.js | Same-origin API, cookie HttpOnly |
| api/tasks.js | CRUD/version checks, recurrence, activity read, flush antrean |
| api/telegram.js | Authenticated pairing/settings/admin webhook/manual queue |
| api/telegram-webhook.js | POST terautentikasi secret header, tanpa browser Origin |
| api/telegram-cron.js | Bearer CRON_SECRET; daily materialization/digest atau queue-only |
| server/core.js | Supabase calls, cookie session, active user, CSRF Origin, validation |
| server/telegram.js | Telegram transport, formatting, strict reply parser, delivery worker |
| server/report*.js | Snapshot report, CSV injection protection, Excel export |
| supabase/01–05 | Schema dasar, PIC/report, recurrence, Telegram/workflow |
| supabase/06_optional_queue_worker.sql | Opt-in Supabase Cron HTTP queue worker |
| tests/, scripts/test-*.mjs | Unit/mock API, SQL/PGlite, browser mock smoke |

## Service flow

Task save: Browser → Vercel session/Origin validation → Supabase RLS + trigger guards → task/activity/outbox commit → immediate delivery attempt. Provider failure is separate from committed task state. Raw Supabase client updates are still checked by SQL workflow/PIC triggers.

Telegram: callback/reply → webhook secret check → numeric user ID mapping → active profile/current ownership/message binding → service-only fd_tg_action → row lock, version, update_id → guarded status transaction → new outbox events → Telegram. No action resolves a task by fuzzy title.

Pairing: authenticated browser requests random 192-bit code → SHA256 hash stored, expiry 10 minutes → user sends code → server validates private/group context and group admin → transactional redeem consumes code and connects identity. Telegram ID is unique across accounts; expected usernames are matched against the username observed from a trusted Telegram update. Numeric ID remains the paired identity; username alone never grants assignment access.

Scheduled: Supabase Cron (recommended) or daily Vercel fallback → fd_tg_schedule → WIB window + day/slot unique run → recurrence materialization → group briefing / morning DM outbox → claim/process up to 20. The old fd_tg_daily entrypoint delegates to this window-gated scheduler. Personal digest remains a manual action.

## Data model

All app tables use fd_ prefix. Full SQL is authoritative for fields, defaults, indexes, constraints and grants; table summary below highlights relations.

| Table | Key fields/types | Relations / constraints |
| --- | --- | --- |
| fd_profiles | id uuid PK, email text, display_name text, role text, is_active bool | auth.users FK; role admin/user; inactive by default |
| fd_preferences | user_id uuid PK, capacity int, email_enabled bool | profile FK |
| fd_tasks | id uuid PK, user_id uuid, status text, version int, scheduled/due date, completed_at timestamptz | Owner/profile, PIC, assignee/profile, recurrence, Telegram group FKs |
| fd_pics | id uuid PK, owner_id uuid, name/email text, linked_user_id uuid?, telegram_username text? | Unique lower(email) per owner; linked account optional |
| fd_recurrences | id uuid, owner_id uuid, template jsonb, pattern text, interval int, start/end date, generated_through date | Owner FK; interval 1–30; unique task recurrence_id/date |
| fd_telegram_accounts | user_id uuid PK, telegram_id bigint UNIQUE, chat_id bigint, telegram_username text?, username_seen_at timestamptz? | Profile FK; positive Telegram ID, private chat_id = Telegram ID |
| fd_telegram_groups | id uuid PK, owner_id uuid, chat_id bigint UNIQUE, title text, active bool | Negative chat ID; one owner per group |
| fd_telegram_codes | hash text PK, user_id uuid, kind text, expires_at timestamptz | Hash length 64; personal/group; consumed on success |
| fd_task_activity | id uuid, task_id uuid, actor_id uuid?, from/to_status text, cycle/version int, note text, created_at | Append-only to clients; task FK cascade; index task/time |
| fd_telegram_outbox | id uuid, owner_id, target_user_id? / target_group_id?, task_id?, kind, day, dedupe_key UNIQUE, status, attempts, timestamps | Exactly one target; pending/sending/sent/failed/uncertain/skipped |
| fd_telegram_messages | chat_id bigint + message_id bigint PK, task_id, task_version, target IDs | Binds Telegram message to exact task version/context |
| fd_telegram_updates | update_id bigint PK, created_at | Transactional dedup of successful status updates |
| fd_assignment_messages | task/version/recipient email UNIQUE, payload jsonb, status | Previous email assignment delivery snapshots |
| fd_deliveries | user_id + day PK, status | Previous daily email claims |
| fd_audit | bigint identity, actor/target uuid, details jsonb | User access changes |

Task additions: requires_testing boolean default false; acceptance_criteria text default empty, max 4000; test_cycle int default 0 derived by trigger; telegram_group_id nullable UUID. Status enum: Backlog, To do, In progress, Ready for Testing, Testing, Rework, Done. Reviewer is task.user_id; no tester_id in this release.

## Security and consistency

- Service-role secret/bot token stay on server. Browser only receives application data and one-time pairing code.
- All client mutation requests require trusted Origin + JSON. Webhook instead requires exact secret header; cron requires long Bearer secret.
- RLS owner/PIC access for tasks, owner-only contacts/groups/connections, task-bound activity read. Admin role alone does not read other people's tasks.
- Telegram private tables and all write paths revoked from anon/authenticated. Only scoped pairing/disconnect RPCs exposed to authenticated; redeem/action/claim/daily service-only.
- SQL fd_workflow_guard runs before existing PIC field guard; derived cycle runs after it. PIC can change only status/progress, not new testing or group fields.
- requires_testing cannot be disabled after activation. Initial testing task cannot start Done. Reviewer-only pass requires Testing. Rework requires new nonempty reason.
- fd_tg_action locks task, checks current access/context/version, inserts update_id and updates status in one transaction. On exception, the update ID insertion rolls back. Temporary auth.uid context is set only inside service-only RPC and restored.
- Provider side has no atomic commit with DB. A returned Telegram message ID is recorded before marking sent. Timeout or bookkeeping failure is uncertain, not blindly retried. Abandoned sending claims become uncertain after 5 minutes.
- Outbox workers claim with FOR UPDATE SKIP LOCKED. Retry applies to explicit transient failures, max 5 attempts. Queue-only worker is optional for timeliness; default daily is not a low-latency retry SLA.
- Content HTML-escaped. Internal notes/email excluded from Telegram. Group progress/criteria intentionally shared; old messages are not revoked.
- Telegram groups/channels/forum topics migrations are not auto-discovered; this release supports ordinary groups/supergroups and private chat, not channels or separate topic routing.

## Retention and maintenance

Daily cleanup removes expired pairing codes, update/message mappings older than 30 days, and sent/skipped queue records older than 90 days. Older message buttons therefore stop working; obtain current cards. Pending/failed/uncertain records remain for inspection. Activity stays until task deletion; FK cascades are described in SQL. Export/backup before deletion when audit retention is required.

Combined legacy upgrade wraps 03 + 04 + 05 + 07 + 08 in one transaction. For existing v1.4 use ONLY 08 (Focusdesk_v1_4_to_v1_5.sql); v1.3 uses combined 07+08 (Focusdesk_v1_3_to_v1_5.sql). Migrations preserve existing task rows/versions and pairing IDs. Scheduler activation 09 is separate and supersedes old queue worker 06. Older tasks retain their testing/group configuration. Existing ongoing series adopt testing/group fields only when new templates are created; per-occurrence edits do not change series template.

## Coding rules

Validate server inputs and SQL invariants; never trust UI button visibility. Parameterize SQL/RPC arguments; validate IDs before REST query composition. Do not log tokens/cookies/provider URLs. Avoid arbitrary user-ID impersonation RPC grants. Keep package lock and Node target consistent; version all release labels. Use additive reviewed migrations, explicit RLS/grants, regression tests and staging deployment. Do not change completed_at manually or rewrite activity history to fake completion. External writes/credentials must be configured by authorized operator.
| public/js/sync.js | Pembacaan task berhalaman tanpa materialisasi pada polling; snapshot ID/version |
| public/css/dashboard.css | Tokens visual, dashboard operasional dan responsive overrides |
| supabase/07_telegram_sync_pic.sql | Username PIC/accounts, scoped verification RPCs, DM-only transactional action guard |

## v1.4 synchronization and private actions

Browser: 10-second active-tab polling → GET /api/tasks?sync=1&page=N → user-token RLS read → compare ID/version snapshot. Normal foreground loading still materializes recurrences. A read epoch and busy check discard stale background results across foreground writes/sign-out. Polling does not rerender settings/report forms. Dashboard/list/calendar views rerender on changes, preserving search focus and scroll. Open task drafts are retained; changed/deleted/access-revoked tasks show a stale banner or close. Save and workflow on stale forms are blocked until explicit reload; server optimistic version checks remain authoritative. Offline/hidden tabs pause and reconnect/focus resumes. No Supabase Realtime publication or new environment variables required. Polling adds API reads roughly six times per minute per active tab; use realtime or a delta endpoint if the workspace grows substantially.

Telegram: answerCallbackQuery acknowledges receipt before database work. Then trusted from.id → active paired profile → observed username update → task/message binding + role/username verification → fd_tg_action transaction → success confirmation → outbox processing. Group cards are read-only; /tasks requests create only private outbox cards for the caller's accessible tasks. Legacy group actions are rejected by both webhook and SQL. DM roleFor distinguishes executor from reviewer; owner is executor only with no PIC or self-assignment. A username mismatch hides all action buttons for the affected account and rejects forged callbacks/replies. Telegram ephemeral messages are not used.

fd_save_pic_v14 wraps existing owner/version-checked fd_save_pic atomically and stores normalized expected username. fd_pic_telegram_status exposes only the caller's contacts, without numeric IDs. fd_tg_pic_matches is service-only. Old contacts with no expected username retain numeric pairing behavior. Existing task assignee snapshots are intentionally not reassigned by editing a contact: owner saves task explicitly. Username observations update only from webhook-authenticated Telegram sender data.
