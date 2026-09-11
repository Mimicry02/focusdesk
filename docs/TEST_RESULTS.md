# Test results — Focusdesk 1.3.0

Tanggal: 11 September 2026. Tidak memakai project Supabase, akun Vercel, atau token Telegram pengguna. Tidak ada pesan/undangan live yang dikirim oleh pengujian ini.

## Lolos lokal

- 28 unit/mock API tests melalui npm test: login/cookie, Origin, active account, PIC access, task validation, recurrence validation, CSV/XLSX export, Telegram escaping/reply parsing, webhook/cron secrets, timeout/429 behavior, disconnected-recipient skip.
- npm run build: output static berhasil. Vercel membangun API functions secara terpisah saat deployment.
- PGlite PostgreSQL tests: schema dasar, PIC/reports, recurring, dan Telegram/testing.
- Telegram SQL suite: fresh schema + migration replay/data preservation, one-use pairing, grant restrictions, owner/PIC RLS, reviewer-only testing, required fail reason, cycle 1 → 2, completion time, rejected stale message, duplicate update_id, inactive account, recurrence template fields, daily dedup, abandoned sending → uncertain.
- Node syntax checks untuk modul baru dan frontend.

## Belum diverifikasi

- Deploy Vercel production dan Node 22 di Vercel. Runtime lokal menggunakan Node 24; package target tetap Node 22 dan hanya memakai API kompatibel Node 22.
- HTTP/PostgREST nyata, Supabase Auth SMTP, custom domain, Deployment Protection.
- BotFather/webhook/pairing/tombol/group permissions dengan bot live, rate-limit dan delivery jaringan nyata.
- Cron pukul 08 WIB di production, optional Supabase pg_cron/pg_net/Vault worker dan kuota.
- Browser visual/end-to-end desktop/mobile: script smoke test disertakan, tetapi tidak selesai dijalankan karena binary Chromium belum tersedia dan download timed out. Tidak ada klaim screenshot/browser QA lolos.
- Load testing, penetration test eksternal, atau audit compliance.

## Reproduksi

```bash
npm ci
npm test
npm run build
```

Untuk SQL, sediakan paket @electric-sql/pglite pada lingkungan pengujian (bukan production), lalu jalankan scripts/test-sql.mjs, test-pic-sql.mjs, test-recurring-sql.mjs, test-telegram-sql.mjs. Jika paket ada di folder terpisah, PGLITE_MODULE dapat diisi absolute path entrypoint-nya.

scripts/test-ui.mjs menggunakan Playwright dan Chromium yang harus diinstal di lingkungan QA. PLAYWRIGHT_MODULE dapat menunjuk entrypoint Playwright di folder terpisah. Script hanya menggunakan API mocks; lolos script itu pun bukan bukti bot live sudah terhubung.

Lakukan checklist integrasi di README sebelum digunakan oleh tim. Simpan backup database dan ZIP versi sebelumnya.
