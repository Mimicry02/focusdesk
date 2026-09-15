# Test results — Focusdesk 1.4.0

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
