# Focusdesk v1.7 — Product, Architecture, Design, Schema, Rules

## Product requirements
AI menjawab manual aplikasi di grup Telegram dengan sumber dan eskalasi task existing. Workspace memudahkan akses fitur. Acceptance: hanya aplikasi/grup terotorisasi; tanpa sumber tidak memanggil AI; provider gagal tidak mematikan laporan; hanya pelapor bertindak; PIC/reviewer tetap existing; admin melihat kesiapan AI tanpa melihat key.

## Architecture dan alasan stack
Pertahankan vanilla JS/HTML/CSS FE, Vercel Node functions dan Supabase/PostgreSQL existing untuk menghindari framework migration. OpenAI Responses API memakai fetch server-side, tanpa dependency runtime baru. Structured Outputs mengontrol bentuk response/citation, bukan jaminan kebenaran semantik.
Default model gpt-4.1-mini mendukung Responses/Structured Outputs untuk penulisan jawaban pendek; bukan klaim model terbaru. OPENAI_MODEL dapat diubah setelah uji kompatibilitas. FTS existing dipertahankan; embeddings memerlukan enhancement dan evaluasi retrieval terpisah.

Service flow: authenticated webhook → receiveDesk → ask/action SQL transaction → AI prepare → outbox pending → claim → revalidate published sources/group → atomic daily reserve → OpenAI → validate answer/citation IDs → persist answer/audit transaction → Telegram. AI tidak menerima credentials, histori seluruh grup, atau tools. State mutasi task tetap melalui RPC existing.

Folder tambahan:
- server/ai.js: adapter OpenAI, config nonsecret, validation, safe errors, connection check.
- server/desk.js: worker AI di outbox support existing.
- api/desk.js: admin health/config dan POST ai-test dengan session/origin check.
- public/js/workspace.js, public/css/workspace.css: landing dan navigasi workspace.
- public/js/desk-home.js, public/desk-v17.css: onboarding support dan integrasi status.
- supabase/12_ai_workspace.sql: additive migration + ask/action override.
- public/guide-v1-7.html: setup guide standalone.

## Design dan UI/UX
Workspace landing: hero tugas hari ini, kartu pekerjaan/knowledge/laporan/PIC, entry AI/Telegram. Overview dashboard tetap tersedia. Sidebar dikelompokkan daily work, kelola/laporan, knowledge/support.
Knowledge Desk: statistik, checklist setup, deep link hash, admin-only AI & Telegram. Member Reports only. Form/modal existing digunakan kembali.
Design tokens: emerald #224c40, canvas #f5f7f5, white surface, accent biru/amber/ungu; system font, radius 8–18px; 4→2 column grids dan stacked mobile; semantic buttons/links, focus ring, aria-live status. Tidak ada input API key browser.

## Schema dan relasi
fd_desk_outbox menambah ai_state text NOT NULL (none/pending/reserved/complete), ai_question text (dibatasi 6000 saat prepare), ai_sources jsonb NOT NULL default [] (max 3 FTS matches), ai_result jsonb (mode/reason/model/verified sources/timestamp).
fd_ai_daily_usage: owner_id uuid FK fd_profiles, day date WIB, requests integer >=0; PK(owner_id,day). RLS enabled, service-only mutation. Reserve memakai row lock dan atomic upsert untuk membatasi concurrency.
fd_desk_ai_prepare/context/reserve/finish service-role-only. fd_desk_ai_health authenticated, tetapi wajib admin aktif dan filter auth.uid. Original report trigger tetap berlaku; catatan append-only. Tidak ada grant baru bagi authenticated atas outbox/usage.
Sumber harus tetap Published dengan ID/revisi/content yang sama sebelum inference dan saat persist. Delivery retry memakai jawaban tersimpan. Exactly-once Telegram send tidak dijanjikan: kiriman ambigu memakai state uncertain existing.

## Rules
ES modules; inject provider dependency untuk tes; no secret public/log/response. Escape HTML; MD diperlakukan sebagai data; Telegram plain text. Validasi source IDs. AI tidak menebak perubahan status task. SQL additive/replay-safe, search_path eksplisit, grants eksplisit, satu transaction upgrade. Timeout/output/daily cap dibatasi; raw provider error tidak ditampilkan.

## Limitations
FTS dapat melewatkan parafrasa. Citation/schema tidak menjamin grounded prose; perlu UAT manual asli. Satu pesan support/invocation bisa menambah antrean. Health bukan laporan billing. Tidak ada embeddings, Telegram media ingestion, DM knowledge mode, free-chat wake word, atau auto-edit task oleh AI.
