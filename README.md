# Focusdesk v1.0 — Vercel + Supabase

Paket source aplikasi, bukan HTML demo. Login wajib; data awal akun kosong.

**Mulai dari `docs/START_HERE.html`.**

1. Buat project Supabase khusus aplikasi ini.
2. Jalankan `supabase/01_schema.sql` di SQL Editor.
3. Buat akun Anda melalui Authentication → Users → Add user (email terkonfirmasi).
4. Edit email di `supabase/02_bootstrap_admin.sql`, lalu jalankan untuk admin pertama.
5. Deploy **seluruh root proyek** ke Vercel. `package.json`, `vercel.json`, `api/`, `public/`, `server/` harus ikut.
6. Atur empat environment variables wajib di Vercel dan redeploy.
7. Atur Site URL, Redirect URLs, dan SMTP di Supabase. Login lalu undang user melalui menu User management.

## Environment variables wajib

| Nama | Isi |
| --- | --- |
| SUPABASE_URL | Project URL, tanpa `/rest/v1/` |
| SUPABASE_PUBLISHABLE_KEY | Publishable key atau legacy anon key |
| SUPABASE_SECRET_KEY | Secret key atau legacy service_role key; hanya di Vercel |
| APP_URL | Origin HTTPS production yang Anda buka, misalnya `https://focusdesk-anda.vercel.app` |

Opsional untuk briefing harian: `RESEND_API_KEY`, `EMAIL_FROM`, `CRON_SECRET` (acak minimal 32 karakter).

`npm run build` menghasilkan static assets di `dist/`; Vercel membangun `api/*.js` secara terpisah. Tidak ada framework build atau runtime npm dependency. Node runtime target: 22.x.

Jangan hanya mengunggah `dist/` atau `public/`: backend login/user management akan hilang. File ZIP bisa digunakan sebagai paket handoff; gunakan Vercel Drop untuk unggah proyek atau ekstrak dan impor melalui Git/CLI sesuai alur Vercel Anda.

## Fitur

- Supabase Auth: login, logout, invite email, password recovery, ubah password.
- Admin/user, daftar pengguna, promosi/demosi akun lain, aktif/nonaktif, instruksi reset.
- Tugas pribadi, CRUD, prioritas, Top 3, deadline, jadwal, estimasi, notes, board/filter/search.
- Kalender, ekspor .ics, link Google Calendar manual, timer fokus, insights.
- Briefing harian opsional melalui Resend + Vercel Cron; target 08.00 WIB.

Tidak ada akun/password demo, public signup UI, akses tugas pengguna lain oleh admin, atau sync Google Calendar otomatis.

## Verifikasi

`npm test` — unit dan API tests (mock provider).
`npm run build` — build static assets.
`scripts/test-sql.mjs` — verifikasi SQL/RLS lokal dengan PGlite jika dipasang terpisah.

Paket telah diuji pada logika aplikasi, API dengan mock, dan SQL pada PostgreSQL lokal berbasis PGlite. Belum dideploy ke akun Vercel Anda; Supabase Auth/SMTP/Resend nyata belum diuji tanpa konfigurasi proyek Anda.
