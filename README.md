# Focusdesk v1.6.0 — Knowledge Desk

Paket aplikasi Vercel + Supabase + Telegram. Rilis 1.6 menambahkan master aplikasi/kategori/priority/PIC routing, panduan Markdown, pelaporan lewat bot, eskalasi task, dan riwayat laporan yang tidak dapat diedit.

**Mulai:** [Manual Knowledge Desk](docs/KNOWLEDGE_DESK.md) · HTML interaktif di `public/guide-v1-6.html` (bisa dibuka langsung tanpa server).

## Upgrade dari v1.5
1. Simpan backup database dan source deployment yang sedang dipakai.
2. Jalankan **Focusdesk_v1_5_to_v1_6.sql** di Supabase SQL Editor sebagai project owner. Ini menambah schema/RPC baru, tidak mereset task, user, PIC atau pairing Telegram.
3. Ekstrak ZIP. Upload seluruh isi ke root repository GitHub: `api/`, `server/`, `public/`, `supabase/`, `package.json`, `package-lock.json`, `vercel.json`, dan dokumen. Jangan upload ZIP sebagai satu file, jangan hanya upload `public/`.
4. Vercel memakai root yang berisi package.json; build `npm run build`, output `dist`, Node 22. Tunggu deployment Production Ready.
5. Environment yang lama tetap dipakai. Tidak perlu token AI baru dan tidak perlu pairing ulang jika bot/domain tetap sama.
6. Login admin → sidebar **Knowledge Desk** → Buat master awal → Applications → PIC routing → Group access → Knowledge articles.
7. Grup uji: `/apps`, lalu `/ask GEE pertanyaan`. Periksa alur eskalasi dan PIC sebelum membuka akses grup lain.
8. Jalankan query read-only `supabase/11_diagnostics.sql`. Kalau cron sudah aktif/sehat, tidak perlu dihapus atau dipasang ulang. Kalau belum ada/nonaktif, jalankan **Focusdesk_Activate_Scheduler_v1_6.sql** setelah memeriksa Vault.

**Jangan menjalankan SQL fresh pada database lama.** Dari v1.3/v1.4 gunakan **Focusdesk_Upgrade_to_v1_6.sql** (gabungan migrasi 03,04,05,07,08,10, dapat diterapkan ulang). Instalasi kosong: **Focusdesk_Supabase_v1_6.sql**, lalu ikuti `supabase/02_bootstrap_admin.sql` untuk mengaktifkan akun admin Anda.

## Environment dan integrasi
Wajib untuk server/auth: `APP_URL` (origin production), `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`.
Telegram: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET` (minimal 32 karakter), `CRON_SECRET` (minimal 32 karakter). Gunakan bot yang sudah terhubung; webhook tetap `/api/telegram-webhook` dan secret header Telegram tetap sama. Untuk bot baru ikuti panduan Telegram lama di docs.
Email opsional: `RESEND_API_KEY`, `EMAIL_FROM`. Calendar/export dan workflow lama tetap tersedia.

Vault untuk cron: tepat satu `focusdesk_app_url` berisi origin aplikasi sebenarnya dan tepat satu `focusdesk_cron_secret` dengan nilai sama persis dengan `CRON_SECRET` deployment Production. Nilai contoh bukan credential. Simpan environment Vercel lalu redeploy agar berlaku. Jangan mengirim secret ke chat atau GitHub.

Tidak ada migration yang otomatis mengirim pesan Telegram; aktivasi worker/tes endpoint dapat mengirim antrean nyata. Jadwal 09:00 dan 17:30 WIB memakai worker setiap menit dengan deduplikasi slot harian. Pengiriman tidak bisa dijamin tepat detik jika layanan tidak tersedia.

## Yang ada di 1.6
- Master aplikasi dengan PIC utama/cadangan dan application owner sebagai reviewer.
- Master kategori, priority, routing per aplikasi/kategori, pemetaan aplikasi–grup.
- Import `.MD`, Draft/Published/Archived, pemecahan heading, pencarian bagian panduan, sumber dan revisi.
- `/apps`, `/ask KODE pertanyaan`; reply sebagai koreksi; tombol konfirmasi pembuatan task.
- Pelapor anggota grup tidak harus login web. Tindakan terikat numeric Telegram ID dan chat.
- Laporan asli dan catatan tidak dapat diedit/dihapus. Reports hanya baca, RLS, pagination dan export CSV halaman.
- Task memakai workflow PIC/reviewer lama; status tersinkron web dan notifikasi grup.
- Outbox support, retry terbatas, idempotensi webhook/task, pemeriksaan ulang akses saat mengirim.

## Batasan yang perlu diketahui
Pencarian tanpa LLM menampilkan kutipan, bukan jawaban AI bebas. Knowledge harus Anda isi dan tinjau. Reviewer masih application owner, bukan pilihan user terpisah. Critical support dipetakan ke High di board lama. Target waktu adalah jam kalender, bukan SLA business-hours/auto-escalation. Attachment Telegram, penggabungan laporan terpisah, dan pembuatan knowledge otomatis dari resolusi belum disediakan. Semua anggota grup bisa melihat tombol support, tetapi hanya pelapor yang dapat menjalankannya; tombol execution tetap DM PIC.

## Pengembangan dan validasi
`npm ci`, `npm test`, `npm run build`.
Untuk uji PostgreSQL lokal: install `@electric-sql/pglite` sebagai dependency pengembangan sementara, lalu `node scripts/test-v16-sql.mjs` (atau atur `PGLITE_MODULE`). Browser QA menggunakan Playwright/Chromium melalui environment `PLAYWRIGHT_MODULE`, `CHROMIUM_EXECUTABLE`, `CHROMIUM_MODULE`.

Hasil validasi ada di `docs/TEST_RESULTS_V1_6.md`. Pengujian lokal menggunakan database simulasi dan API mock; deployment Supabase/Vercel/Telegram milik Anda belum diuji langsung dalam proses pembuatan paket ini.
