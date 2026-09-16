# Test results — Focusdesk 1.5.0

## Verifikasi rilis 1.5 — 16 September 2026

- 37 unit/mock API tests lulus: mencakup format briefing pagi/sore, escaping, panjang pesan, expiry WIB, allowlist cron, clock tidak diambil dari query HTTP, ringkasan grup scoped tanpa tombol, dan skip task Done sebelum kirim; regresi auth/PIC/report/Telegram sebelumnya tetap lulus.
- SQL/PGlite v1.5 lulus: migrasi replay mempertahankan task/pairing, RPC service-only, 08:59/09:00/17:29/17:30/23:59/midnight, dedup slot/tanggal pada retry, count lengkap/sampel terbatas, isolasi owner+grup, routing executor/reviewer, pengecualian task future/Done/mismatch, ketergantungan ringkasan sebelum kartu, draining >20 kartu, unpaired/inactive, materialisasi recurrence tanpa event-card ganda, dan expiry pesan lama.
- SQL/PGlite v1.4 sebagai regresi izin/status/testing kembali lulus.
- Build static dan syntax frontend berhasil. Dependency versions dipertahankan; package/root lock version menjadi 1.5.0.
- Playwright/Chromium API mocks lulus: polling status, perlindungan draf, workflow testing, username PIC, pairing, recurrence, desktop/mobile; tambahan Settings menampilkan 09.00/17.30 dan timestamp panggilan scheduler. Screenshot Settings disertakan.
- Packaging menggunakan scripts/test-release.mjs untuk memeriksa ZIP, versi, file SQL dedicated/fresh/upgrade, transaksi tunggal, tidak ada env asli/node_modules, serta replay SQL gabungan. Script aktivasi dipisah dari migration data.

**Belum diuji live:** pg_cron/pg_net/Vault pada project Supabase Anda, HTTP ke deployment Vercel, scheduler tepat waktu di production, kuota paket, dan bot/grup nyata. Tidak ada pesan ke orang lain yang dikirim selama pengujian. SQL clock test deterministik bukan pembuktian presisi penyedia scheduler. Node lokal 24, target production 22.

Reproduksi: `npm test`, `npm run build`, `PGLITE_MODULE=<entrypoint> node scripts/test-v15-sql.mjs`, kemudian `node scripts/package-release.mjs <folder>` dan `PGLITE_MODULE=<entrypoint> node scripts/test-release.mjs <folder>`. Browser memakai script test-v14-ui.mjs yang telah ditambah pemeriksaan Settings scheduler.

## Catatan historis rilis 1.4

Tanggal: 13 September 2026. Tidak memakai project Supabase, akun Vercel, atau token Telegram pengguna. Tidak ada pesan/undangan live yang dikirim oleh pengujian ini.

## Lolos lokal

- 32 unit/mock API tests melalui npm test: login/cookie, Origin, active account, PIC access, task validation, recurrence validation, CSV/XLSX export, Telegram escaping/reply parsing, webhook/cron secrets, timeout/429 behavior, disconnected-recipient skip. Tambahan v1.4: role keyboards, read-only polling/deletion snapshot, callback acknowledge → commit → confirmation → API web membaca status yang sama, group card tanpa keyboard dan PIC DM berisi Start work.
- npm run build: output static berhasil. Vercel membangun API functions secara terpisah saat deployment.
- PGlite v1.4: instalasi v1.3 dengan task/PIC/pairing, upgrade 07 dua kali mempertahankan data/versi/pairing; username verification, scoped directory, service-only grants; tindakan hanya DM yang benar; stranger/username mismatch/inactive/stale ditolak; Start work dibaca dari sesi web pemilik; seluruh siklus Need Testing → Testing → Rework → retest → Done; completion time dan duplicate update_id.
- PGlite release: combined fresh SQL dan combined upgrade replay berhasil; ZIP memuat versi/package/SQL yang sesuai, satu transaksi, tidak ada env asli/node_modules/dist, dan optional Cron tidak diaktifkan otomatis. Suite dasar v1.0–v1.3 tetap disertakan sebagai regresi historis.
- Playwright/Chromium dengan API mocks pada viewport 1440×1050 dan 390×844: dashboard aktif menerima perubahan tanpa refresh, modal mempertahankan draf dan mengunci Save saat versi berubah, reload eksplisit dan reviewer Testing → Done, PIC tidak mendapat tombol review, username dikirim saat save, pairing UI, recurring/group payload, tidak ada overflow halaman atau JavaScript error. Screenshot QA desktop/mobile disertakan di ZIP.
- Node syntax checks untuk modul baru dan frontend.

## Belum diverifikasi

- Deploy Vercel production dan Node 22 di Vercel. Runtime lokal menggunakan Node 24; package target tetap Node 22 dan hanya memakai API kompatibel Node 22.
- HTTP/PostgREST nyata, Supabase Auth SMTP, custom domain, Deployment Protection.
- BotFather/webhook/pairing/tombol/group permissions dengan bot live, rate-limit dan delivery jaringan nyata.
- Cron pukul 08 WIB di production, optional Supabase pg_cron/pg_net/Vault worker dan kuota.
- Load testing, penetration test eksternal, atau audit compliance.

## Reproduksi

```bash
npm ci
npm test
npm run build
```

Untuk SQL, sediakan paket @electric-sql/pglite pada lingkungan pengujian (bukan production), lalu jalankan scripts/test-sql.mjs, test-pic-sql.mjs, test-recurring-sql.mjs, test-telegram-sql.mjs. Jika paket ada di folder terpisah, PGLITE_MODULE dapat diisi absolute path entrypoint-nya.

`scripts/test-v14-sql.mjs` menguji perubahan migrasi dan izin terbaru. `scripts/test-release.mjs <folder-release>` menguji ZIP dan combined SQL. `scripts/test-ui.mjs` meneruskan ke `test-v14-ui.mjs` dan menggunakan Playwright/Chromium di lingkungan QA. PLAYWRIGHT_MODULE dapat menunjuk entrypoint Playwright; CHROMIUM_EXECUTABLE opsional untuk browser yang sudah tersedia. Runtime browser lokal memakai Chromium 153 dari paket QA terpisah karena download Playwright default timeout. Dependency QA tidak masuk dependencies production. Script browser hanya memakai API mocks; kelulusan bukan bukti webhook production sudah dikonfigurasi.

Lakukan checklist integrasi di README sebelum digunakan oleh tim. Simpan backup database dan ZIP versi sebelumnya.
