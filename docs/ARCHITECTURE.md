# Focusdesk v1.0 — PRD, Architecture, Schema, Rules

## PRD

Satu aplikasi untuk rencana kerja System Analyst, freelance Property, dan Web Development. Pengguna awal satu owner, dengan kemungkinan pengguna independen lainnya. Tujuan: kelola prioritas, kapasitas, jadwal, follow-up, dan akses akun. Tidak ada workspace/tugas bersama pada versi ini.

Alur: login → rencana hari → CRUD tugas → jadwal → fokus → update status → review. Admin: login → invite → user membuat password → aktif → manage role/status. Pendaftaran tanpa undangan tidak ditampilkan; akun Auth yang dibuat di luar alur admin tetap inactive.

Kriteria penerimaan: data lintas perangkat dari Supabase; user A tidak mengakses tugas B; user tidak bisa menaikkan role; akun inactive ditolak; admin dapat mengundang/mengelola akun lain; perubahan tab lama menghasilkan konflik; tidak ada service key di browser; tidak mengisi dashboard dengan data contoh.

## Stack dan alasan

HTML/CSS/JavaScript ES modules menjaga format HTML sebelumnya dan mudah dipaketkan. Tidak perlu instalasi framework untuk runtime. Vercel Node.js Functions menjalankan backend; Supabase PostgreSQL + Auth menyimpan data dan identitas. Frontend bukan Nuxt; migrasi framework tidak diperlukan untuk permintaan paket HTML saat ini. Supabase dan Vercel mengikuti pilihan pengguna. Jika kebutuhan berkembang, konfirmasi apakah pilihan ini didorong familiarity, biaya, atau kebutuhan teknis sebelum mengganti stack.

Aplikasi tidak memerlukan Sites hosting/identitas ChatGPT; paket ini dibuat untuk akun Vercel pengguna. Tidak ada deployment yang dilakukan sebagai bagian dari pembuatan ZIP.

## Folder

| Folder | Fungsi |
| --- | --- |
| public/index.html | Entry HTML |
| public/css/ | CSS tema yang diteruskan dari prototype + layout produksi |
| public/js/app.js | UI state, halaman, form, event handlers |
| public/js/model.js | Fungsi waktu WIB, konflik, escaping, ICS |
| public/js/api.js | HTTP same-origin, error handling |
| api/auth.js | Login/session/recovery/password/logout |
| api/tasks.js | CRUD milik user, validasi dan version check |
| api/profile.js | Profile/preferences/delivery status |
| api/users.js | Admin-only invite, access change, reset |
| api/digest.js | Cron secret atau manual authenticated send |
| server/core.js | Supabase HTTP client, cookies, session validation, CSRF/origin gate |
| server/task-validation.js | Allowlist field dan validasi server |
| server/digest.js | Ringkasan, claim, provider request, delivery status |
| supabase/ | Schema dan bootstrap admin |
| scripts/ | Build dan pengujian database opsional |
| tests/ | Pengujian logika dan API |
| docs/ | Panduan penggunaan dan setup |

## Aliran autentikasi/data

Browser POST login → Vercel menghubungi Supabase Auth → server memeriksa fd_profiles.is_active → access/refresh token ditempatkan dalam cookie HttpOnly/Secure/SameSite=Lax. Browser tidak menyimpan token di localStorage. API memverifikasi user dengan Supabase Auth, memeriksa status terkini, dan mengakses tabel dengan JWT user tersebut sehingga RLS tetap berlaku.

Setiap mutasi mensyaratkan Origin sama dengan APP_URL dan Content-Type JSON. APP_URL adalah allowlist yang dikonfigurasi, bukan nilai Host yang dipercaya begitu saja. Header Content-Security-Policy membatasi script/connect ke origin sendiri; user text di-escape sebelum menjadi markup. Cookie auth dan data response tidak di-cache.

Undangan/reset memakai default Supabase confirmation link. Setelah konfirmasi, token fragment diterima halaman lalu langsung dihapus dari history. Token diverifikasi server sebelum cookie dibuat. User menetapkan password lalu login normal. Jangan mengubah email template ke PKCE/custom token_hash tanpa mengubah callback implementasi. Link invite/recovery tidak menerima redirect dari input pengguna; redirect berasal dari APP_URL.

Refresh token disimpan maksimum tujuh hari di cookie dan dirotasi saat diperlukan. JWT access maksimal satu jam. Request auth gagal membersihkan cookie. Deactivation ditegakkan oleh profile check dan RLS pada request berikutnya; bukan push-based remote wipe.

## Role matrix

| Aksi | User aktif | Admin aktif | Inactive / anonymous |
| --- | --- | --- | --- |
| Baca/edit tugas sendiri | Ya | Ya | Tidak |
| Baca/edit tugas akun lain | Tidak | Tidak | Tidak |
| Edit nama/preferensi sendiri | Ya | Ya | Tidak |
| Lihat daftar akun | Tidak | Ya | Tidak |
| Invite/reset akun lain | Tidak | Ya | Tidak |
| Ubah role/status akun lain | Tidak | Ya | Tidak |
| Ubah role/status sendiri | Tidak | Tidak | Tidak |

## Skema

Semua tabel memakai prefix fd_ agar terpisah dari tabel aplikasi lain; tetap disarankan project khusus.

| Tabel | Field penting | Relasi / aturan |
| --- | --- | --- |
| fd_profiles | id uuid PK; email text; display_name text; role text; is_active boolean; created_at/updated_at timestamptz | id → auth.users, cascade; role CHECK admin/user; default inactive/user; role/status tidak mendapat grant UPDATE user |
| fd_preferences | user_id uuid PK; capacity integer; email_enabled boolean | FK profiles; capacity 30–1440; default 360 dan false |
| fd_tasks | id uuid PK; user_id uuid; title/category/project/kind/priority/status text; due_date/scheduled_date date; start_time time; duration integer; notes text; top_focus boolean; completed_at/created_at/updated_at timestamptz; version integer | FK profiles; field enum CHECK; duration 5–720; title 1–180; no midnight overflow; top_focus butuh scheduled date; ownership immutable |
| fd_audit | id bigint identity; actor_id/target_id uuid; action text; details jsonb; created_at timestamptz | FK profiles; admin read; RPC menulis perubahan akses |
| fd_deliveries | user_id uuid + day date composite PK; status text; attempt_at/accepted_at timestamptz; provider_id/last_error text | FK profiles; satu klaim per hari; hanya server menulis, owner membaca |

RLS is_active dan is_admin memakai SECURITY DEFINER dengan search_path kosong, akses berdasarkan auth.uid dari token, bukan body atau raw_user_meta_data. Semua metadata role/is_active dari signup diabaikan. Profile display_name hanya update kolom yang diizinkan. Direct inserts/updates role tidak diberikan kepada authenticated.

Trigger tugas mengunci per owner sebelum Top 3 check, memelihara version/timestamps dan completed_at. API PATCH/DELETE memfilter id+version; no matching row menghasilkan 409. RPC admin menserialisasi perubahan akses dan memeriksa ulang role aktif; self-change dilarang. Bootstrap admin dilakukan owner database melalui SQL, bukan first-user-wins.

## Waktu dan email

Versi ini menetapkan timezone Asia/Jakarta untuk semua pengguna. Tanggal jadwal + jam lokal disimpan terpisah; audit timestamps UTC/timestamptz. Calendar export mengonversi WIB ke UTC. Deadline tidak diubah otomatis saat jadwal dipindah.

Vercel Cron sekali sehari pada 01:00 UTC (target 08:00 WIB). Hobby memberi ketelitian per jam. Manual send dan cron memakai satu klaim per user/tanggal WIB dan idempotency key provider yang stabil. Status accepted bukan inbox delivery. Kegagalan bisa dicoba ulang; tidak ada persistent queue/automatic retry worker atau delivery webhook pada versi ini. Batas 10 akun opted-in aktif dan 500 tugas per email. Scale-up memerlukan antrean; jangan menaikkan batas tanpa analisis durasi/server/provider rate limit.

## Coding rules

ES modules; camelCase untuk fungsi/variabel, snake_case untuk database dan data API. Validasi client membantu UX, server+database otoritatif. Jangan memasukkan env/secrets di public/. Jangan membagikan key service role ke browser. Semua konten pengguna harus melewati escapeHTML; jangan membuat event handler inline. Role/state UI tidak menjadi sumber otorisasi. Gunakan SQL migrations untuk perubahan berikutnya, bukan drop database. Tangani optimistic concurrency sebelum overwrite data.

Gunakan unit/API tests untuk aturan penting. Isolasi RLS perlu pengujian database nyata; mock saja tidak cukup. Lihat TEST_RESULTS.md untuk batas verifikasi paket ini.
