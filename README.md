# Focusdesk v1.7.0 — AI Knowledge Assistant & Workspace

Bot Telegram existing sekarang dapat memakai OpenAI API untuk menyusun jawaban dari panduan Published. Workspace baru menyediakan akses cepat ke pekerjaan, Knowledge Desk, PIC, laporan, dan AI/Telegram. Panduan HTML: `public/guide-v1-7.html`.

## Upgrade
1. Backup database dan simpan source deployment lama.
2. **Sudah v1.6:** jalankan `Focusdesk_v1_6_to_v1_7.sql` seluruhnya di Supabase SQL Editor.
3. **Masih v1.3–v1.5:** gunakan `Focusdesk_Upgrade_to_v1_7.sql`. **Database kosong saja:** `Focusdesk_Supabase_v1_7.sql`, lalu bootstrap admin melalui `supabase/02_bootstrap_admin.sql`.
4. Ekstrak ZIP dan ganti isi root repository GitHub dengan file aplikasi, termasuk api/, server/ dan public/. Jangan upload ZIP sebagai satu file dan jangan hanya mengganti FE.
5. Tambahkan environment OpenAI untuk Production di Vercel, lalu redeploy. Build `npm run build`, output `dist`, Node 22.
6. Login admin → Workspace → Telegram & AI assistant → Periksa koneksi AI. Tes membaca akses model; billing/quota generasi masih perlu diuji dengan /ask.
7. Pastikan aplikasi, PIC routing, Group access, dan panduan Published siap. Di grup: `/apps`, lalu `/ask KODE pertanyaan`.

Migration additive dan dapat dijalankan ulang. Tidak mereset task, pengguna, PIC atau pairing. Bot/domain yang sama tidak memerlukan setWebhook ulang. Cron sehat tidak perlu dipasang ulang; `supabase/09_enable_telegram_scheduler.sql` hanya untuk pemasangan/perbaikan cron setelah Vault diperiksa.

## Environment OpenAI baru
| Nama | Nilai |
|---|---|
| OPENAI_API_KEY | Key baru project OpenAI, hanya di server Vercel |
| OPENAI_ENABLED | `true` untuk aktif; default `false` |
| OPENAI_MODEL | `gpt-4.1-mini` default; model Responses/Structured Outputs lain perlu uji kompatibilitas |
| OPENAI_DAILY_LIMIT | `100` default; 1–500 panggilan/workspace/hari WIB, termasuk percobaan gagal |

Cabut API key yang pernah dibagikan di chat. Key tersebut tidak disertakan atau digunakan dalam paket ini. Jangan kirim penggantinya lewat chat; jangan pakai prefix environment publik. Pastikan billing API dan akses model project tersedia.

Environment existing: APP_URL, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_USERNAME (tanpa @), TELEGRAM_WEBHOOK_SECRET, CRON_SECRET. Email opsional: RESEND_API_KEY, EMAIL_FROM. `.env.example` berisi nama variabel, bukan credential siap pakai.

Vault cron tetap berisi `focusdesk_app_url` dan `focusdesk_cron_secret` dengan nilai yang sama dengan URL production dan CRON_SECRET. **OPENAI_API_KEY tidak dimasukkan ke Vault cron.**

## Cara kerja
Telegram group `/ask KODE pertanyaan` → validasi grup/aplikasi → pencarian PostgreSQL → maksimal 3 kutipan Published → OpenAI Responses API → validasi ID sumber → simpan jawaban/audit → Telegram.

Jawaban mencantumkan sumber/revisi. Pertanyaan asli immutable, koreksi append-only. Reply teks ke bot memberi detail tambahan. Jika bukti tidak cukup, pelapor memilih kategori dan mengonfirmasi eskalasi untuk membuat task ke PIC. OpenAI tidak diberi tools untuk mengubah task/PIC; execution/review tetap tombol dan validasi role.

AI mati, key salah, model tidak tersedia, timeout, quota atau batas harian → fallback kutipan panduan. Tanpa sumber → tawarkan tambah detail/laporan tanpa memanggil OpenAI. Jika model tidak dapat menjawab dari sumber → tawarkan detail atau eskalasi.

UI AI menampilkan konfigurasi server, penggunaan hari ini dan 10 aktivitas terbaru milik workspace admin. “Konfigurasi siap” bukan bukti koneksi live; gunakan Periksa koneksi AI dan uji grup.

## Operasi dan batasan
- Maksimal satu pesan support per invocation saat AI aktif; antrean berikutnya diproses webhook/cron satu-menit. Latensi tergantung antrean dan layanan.
- AI timeout 18 detik, output maksimal 1.000 token. Tidak ada retry otomatis OpenAI; delivery Telegram memakai jawaban tersimpan. Pengiriman ambigu tidak diulang otomatis.
- Pertanyaan/kutipan dikirim ke OpenAI dengan `store:false`; bukan jaminan zero-retention seluruh layanan. Publish hanya data yang Anda izinkan untuk diproses. Jangan publish secret/data pribadi yang tidak perlu.
- Retrieval memakai kata kunci, belum embeddings. Gunakan judul/heading/sinonim jelas. AI tetap bisa salah; lakukan UAT dengan panduan asli.
- Chat bebas tanpa /ask tidak memicu AI. Knowledge Desk group-only. DM untuk kartu eksekusi PIC dan pairing. Ini bukan koneksi sesi ChatGPT personal.
- Daily cap per application owner/workspace, bukan total biaya seluruh workspace. Atur budget project OpenAI juga. Hitungan percobaan API, bukan token/biaya aktual.
- Scheduler tetap 09:00 dan 17:30 WIB.

## Pengembangan dan pengujian
`npm ci`, `npm test`, `npm run build`.
Database: `PGLITE_MODULE=<path @electric-sql/pglite> node scripts/test-v17-sql.mjs`.
Browser: `PLAYWRIGHT_MODULE=<path playwright> CHROMIUM_MODULE=<path @sparticuz/chromium> node scripts/test-v17-ui.mjs`.
Desain: `docs/V1_7_DESIGN.md`. Validasi: `docs/TEST_RESULTS_V1_7.md`. Dokumen v1.6/lebih lama menjelaskan fitur existing; README v1.7 berlaku untuk fitur baru.

Referensi: https://developers.openai.com/api/docs/guides/structured-outputs dan https://developers.openai.com/api/docs/models/gpt-4.1-mini

Paket belum dideploy atau diuji live menggunakan akun Vercel, Supabase, OpenAI dan Telegram Anda. Tidak ada akses pengelolaan deployment Anda pada sesi pembuatan paket.
