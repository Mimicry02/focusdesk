# Focusdesk v1.3.0 — Telegram-first

Buat/assign tugas di Focusdesk; terima briefing dan perbarui progres/testing lewat bot Telegram. Stack tetap Supabase + Vercel. Paket berisi source dan migrasi, **belum terhubung ke akun atau bot Anda**. Tidak ada token/password asli di ZIP.

## 1. Pilih SQL yang benar

| Kondisi | File yang dijalankan |
| --- | --- |
| Sudah menggunakan Focusdesk v1.0 / v1.1 / v1.2 | `Focusdesk_Upgrade_to_v1_3.sql` saja |
| Database baru, belum ada Focusdesk | `Focusdesk_Supabase_v1_3.sql`, lalu bootstrap admin |
| Ingin antrean diproses tiap menit | Opsional `supabase/06_optional_queue_worker.sql`, setelah bagian 9 |

**Backup database terlebih dahulu.** Jangan jalankan instalasi baru pada database lama. SQL upgrade digabung dalam satu transaksi dan dapat dijalankan ulang. Tidak ada DROP TABLE, reset pengguna, atau penghapusan task lama; beberapa fungsi, trigger, policy, dan constraint Focusdesk diganti untuk mendukung alur baru.

### Upgrade aplikasi berjalan

1. Simpan source/ZIP lama dan backup Supabase. Catat jumlah task serta beberapa ID untuk pembanding. Coba di staging dahulu bila memungkinkan.
2. Hentikan sementara aktivitas edit tim.
3. Supabase → SQL Editor → New query → tempel seluruh `Focusdesk_Upgrade_to_v1_3.sql` → Run. Pastikan sukses.
4. Ekstrak ZIP v1.3. Folder yang berisi `package.json` adalah root project.
5. Perbarui repository deployment Anda dengan source v1.3. Jangan menimpa file rahasia lokal.
6. Tambahkan env di bagian 3 → redeploy production → login → Settings → Register webhook.
7. Pastikan label v1.3, task lama, PIC, dan laporan masih terlihat. Jalankan checklist bagian 10.

Sesudah memakai status testing, jangan rollback aplikasi saja ke v1.2 karena versi lama tidak mengenali status baru. Pemulihan: perbaikan maju, atau restore backup database + source lama dalam maintenance window. Restore backup tidak memuat perubahan sesudah waktu backup.

### Instalasi baru

1. Buat project Supabase, jalankan `Focusdesk_Supabase_v1_3.sql`.
2. Authentication → Users → Add user: buat akun Anda dengan email/password yang benar dan selesaikan konfirmasi sesuai pengaturan Supabase.
3. Isi placeholder email di `supabase/02_bootstrap_admin.sql`, jalankan untuk admin pertama. **Bukan langkah upgrade.**
4. Authentication → URL Configuration: Site URL = domain production Vercel. Tambahkan domain yang sama pada redirect URLs; hindari wildcard domain sembarang.
5. Deploy, login, lalu undang programmer melalui User management. Akun harus aktif untuk mengakses task/pairing Telegram.

## 2. Isi update v1.3

- Pairing personal dengan kode sekali pakai 10 menit; pairing grup dengan pemeriksaan admin grup.
- Notifikasi task baru/perubahan untuk pemilik dan PIC yang memasangkan Telegram. Grup hanya menerima task yang secara eksplisit dibagikan ke grup itu.
- Daily briefing berisi task hari ini dan tertunda, tidak termasuk Done.
- Start work, Need Testing, Start testing, Pass & close, Fail & return, Add progress.
- Alasan wajib untuk return/reopen task testing; riwayat status dan siklus pengujian.
- Antrean persisten, retry/backoff, status uncertain, dan pemrosesan manual.
- Recurring tasks diproses juga oleh jadwal server, bukan hanya ketika dashboard dibuka.
- Export CSV/XLSX memuat requires testing, test cycle, acceptance criteria; Excel merangkum status testing.

Fitur lama tetap: login, user/PIC management, prioritas, kategori, kalender manual, recurring tasks, email opsional, dan laporan bulanan. Tidak ada WhatsApp, AI/NLP berbayar, atau sinkronisasi Google Calendar dua arah.

## 3. Environment variables di Vercel

Project → Settings → Environment Variables. Isi untuk **Production**, lalu redeploy. Staging/Preview harus memakai bot dan project terpisah.

| Nama persis | Isi | Kebutuhan |
| --- | --- | --- |
| `SUPABASE_URL` | `https://PROJECT_REF.supabase.co`, dari Connect/API settings | Wajib |
| `SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_...` atau legacy anon key | Wajib |
| `SUPABASE_SECRET_KEY` | `sb_secret_...` atau legacy service_role key; server only | Wajib |
| `APP_URL` | Origin HTTPS production, tanpa slash akhir | Wajib |
| `CRON_SECRET` | Secret acak minimal 32 karakter | Otomatisasi |
| `TELEGRAM_BOT_TOKEN` | Token dari BotFather, server only | Telegram |
| `TELEGRAM_BOT_USERNAME` | Username bot tanpa `@`, ejaan tepat | Telegram |
| `TELEGRAM_WEBHOOK_SECRET` | Secret berbeda, 32–256 karakter A-Z/a-z/0-9/_/- | Telegram webhook |
| `RESEND_API_KEY` | Key Resend | Opsional: email task/briefing |
| `EMAIL_FROM` | Pengirim dari domain terverifikasi Resend | Jika memakai Resend |

Contoh membuat secret di terminal lokal:

```bash
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
```

Jalankan dua kali untuk CRON_SECRET dan TELEGRAM_WEBHOOK_SECRET berbeda. Jangan kirim hasil/token di chat, commit ke Git, atau memakai prefix NEXT_PUBLIC_. `.env.example` hanya template; Vercel tidak otomatis membaca nilainya.

Publishable key tidak menggantikan secret server. **Undangan/reset login dikirim Supabase Auth**, bukan Telegram atau email briefing Resend. Jika terkena email rate limit, periksa konfigurasi SMTP/batas Supabase; jangan terus retry undangan.

## 4. Deploy ke Vercel

ZIP perlu **diekstrak sebagai source**. Ini bukan klaim bahwa Vercel memiliki tombol import ZIP langsung.

- Ekstrak → masukkan source ke repository GitHub Anda → Import Project di Vercel; atau gunakan Vercel CLI dari folder package.json.
- Framework Preset: Other. Node: 22.x. Build Command: `npm run build`. Output Directory: `dist`.
- Folder `api/` harus berada di root project. Jangan hanya mengunggah folder dist.
- `vercel.json` sudah mencakup fungsi dan cron. Bot tidak membutuhkan proses polling yang terus hidup.

```bash
npm ci
npm test
npm run build
```

Build static tidak menjalankan backend. Untuk end-to-end gunakan staging Vercel + Supabase + bot staging. Cookie aplikasi Secure dan Origin harus sesuai APP_URL.

Webhook perlu URL production HTTPS yang dapat dijangkau Telegram tanpa password gate Vercel atau redirect. Jika 401/403, periksa Deployment Protection/Firewall. Jangan menghapus autentikasi Focusdesk; webhook memakai secret sendiri. Gunakan domain stabil, bukan URL preview.

## 5. BotFather → webhook

1. Di akun resmi **@BotFather**, buat bot dengan `/newbot` atau pilih bot khusus Focusdesk yang sudah ada.
2. Isi TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_USERNAME, TELEGRAM_WEBHOOK_SECRET dan env lain → deploy ulang.
3. Login admin Focusdesk → Settings & integrations → Telegram → **Register webhook**.
4. Klik **Check webhook**. URL harus `APP_URL/api/telegram-webhook`. Periksa pending/error yang berulang.
5. Hentikan script `getUpdates`/polling lama. Satu bot hanya punya satu webhook aktif; pendaftaran dari deployment lain mengganti tujuannya.
6. Opsional BotFather `/setcommands`:

```text
tasks - Kartu tugas hari ini dan tertunda
today - Kartu tugas hari ini dan tertunda
help - Panduan tombol dan reply Focusdesk
```

Tidak perlu menaruh token dalam URL browser/curl. Register webhook di aplikasi melakukan konfigurasi melalui server.

## 6. Pairing personal dan grup

### Personal — masing-masing pengguna

1. Login ke akun Focusdesk sendiri → Settings → **Connect personal**.
2. Klik Open Telegram bot lalu Start; atau kirim `/start KODE` ke chat pribadi bot.
3. Bot mengonfirmasi. Kembali ke Focusdesk → refresh ↻.
4. Kode personal adalah bukti otorisasi akun: **jangan bagikan ke grup atau programmer**. Kode hanya sekali pakai, berlaku 10 menit; kode baru membatalkan kode sebelumnya.
5. **Send today’s briefing** menguji ringkasan. Pengiriman manual/otomatis memakai kunci tanggal yang sama, sehingga tidak diulang hari itu.

### Grup — pemilik workspace yang juga admin grup

1. Hubungkan personal Anda dahulu.
2. Undang bot ke grup. Jadikan bot admin dengan hak minimum yang dibutuhkan agar pemeriksaan getChatMember andal; tidak perlu memberikan hak mengangkat admin atau menghapus pesan.
3. Anda juga harus admin/owner grup. Kirim sebagai akun pribadi, bukan anonymous admin atau channel.
4. Focusdesk → **Connect group** → kirim `/connect@USERNAME_BOT KODE` ke grup dari akun Telegram Anda yang sudah dipasangkan.
5. Refresh Focusdesk. Satu grup hanya dapat terhubung ke satu pemilik Focusdesk pada v1.3.
6. Saat membuat/mengedit task, pilih **Bagikan ke grup Telegram**. Kosong = tidak dibagikan ke grup.

Privacy mode boleh tetap aktif. Bot memproses command, callback, dan reply task; obrolan biasa diabaikan/tidak disimpan. Bot admin dapat menerima pesan lebih luas daripada privacy-mode bot biasa. Di grup dengan beberapa bot, gunakan `/tasks@USERNAME_BOT`.

**Privasi:** semua anggota grup dapat membaca judul, project, kategori, PIC/reviewer, jadwal, deadline, progres, dan kriteria test yang dikirim. Notes internal dan email tidak disertakan. Jangan isi rahasia dalam progres/kriteria. Membership grup tidak memberi hak edit. Pesan lama tidak ditarik kembali ketika PIC/task/grup berubah atau koneksi diputus.

## 7. Assign task dan testing

1. Admin mengundang programmer melalui User management. Programmer menyelesaikan login dan aktif.
2. Buat PIC contact dengan email programmer, centang **Hubungkan ke akun aktif dengan email yang sama**.
3. Programmer login dan pairing personal Telegram sendiri. Kontak Email only tidak dapat mengubah task melalui bot.
4. Buat task → pilih PIC → aktifkan **Wajib testing oleh saya** bila perlu → isi kriteria → pilih grup opsional → Save.
5. Penyimpanan task dan antrean notifikasi terjadi bersama. Server mencoba mengirim segera; kegagalan Telegram tidak membatalkan task.

| Dari | Pelaku / tombol | Menjadi |
| --- | --- | --- |
| Backlog / To do / Rework | PIC atau pemilik: Start work | In progress |
| In progress | PIC atau pemilik: Need Testing | Ready for Testing |
| Ready for Testing | Pemilik: Start testing | Testing |
| Testing | Pemilik: Pass & close | Done |
| Ready for Testing / Testing | Pemilik: Return / Fail & return + alasan | Rework |
| Done dengan testing | Pemilik: Reopen with reason | Rework |

**Reviewer v1.3 selalu pemilik task**, belum ada tester terpisah. Test cycle bertambah setiap kali masuk Ready for Testing. PIC tetap sama ketika Rework; penggantian PIC dilakukan di Focusdesk. PIC/kriteria tidak boleh diganti saat menunggu/dalam testing: kembalikan task dahulu.

Task tanpa testing bisa ditutup langsung. Task dengan testing tidak bisa melewati tahapan via checkbox, API, atau REST langsung. Testing yang sudah aktif tidak dapat dimatikan untuk melewati review.

Tombol Fail & return meminta reply, misalnya `fail: Pencarian GEE Platform error saat keyword kosong`. Status berubah setelah alasan valid; PIC yang Telegram-nya terhubung ditag menggunakan numeric user ID.

Reply yang didukung **hanya sebagai reply kartu/prompt bot**:

```text
start
ready
testing
done
fail: alasan pengembalian
progress: catatan pengerjaan
```

Kalimat bebas “Done fixing ya tasks GEE Platform” tidak ditafsirkan otomatis. Gunakan tombol atau reply `done` pada kartu yang tepat. Versi pesan harus sama dengan task; tombol lama ditolak. `/tasks` menyediakan maksimal 10 kartu tugas hari ini/tertunda sesuai akses. Task masa depan dibuka di Focusdesk. Tombol grup dapat terlihat oleh semua orang, tetapi hak aksi diperiksa server.

Dashboard refresh saat tab memperoleh fokus jika tidak ada modal edit; tersedia refresh manual. Tidak ada realtime push ketika modal sedang diedit. Konflik versi meminta muat ulang, bukan menimpa perubahan orang lain.

## 8. Recurring dan laporan

New task → Repeat: Setiap hari / Hari kerja / Mingguan. Isi Scheduled day, interval, tanggal akhir opsional. “3 Posts Everyday (Area Tangerang)” adalah satu task harian, bukan otomatis tiga subtask. Jika ingin tiga checklist terpisah, buat tiga seri.

Horizon normal 14 hari; batas internal 31 hari; catch-up maksimal 31 hari ke belakang. Done hari ini tidak menutup besok. Occurrence masa depan tidak mengirim spam assignment; briefing pada harinya menampilkan task tersebut. Edit hanya memengaruhi occurrence yang dibuka, bukan template. Untuk perubahan seri: Stop repeating, lalu buat seri pengganti. Stop menghapus occurrence mendatang yang belum Done; Done dipertahankan.

PIC nonaktif menjeda generasi seri terkait. Grup yang diputus tidak dipakai occurrence baru. Task lama tidak otomatis dipindahkan saat kontak PIC diedit; simpan ulang task dengan PIC yang tepat.

Monthly reports → pilih bulan/dasar tanggal/lingkup/kategori/PIC → Generate → Excel / CSV / Print PDF. Status/PIC adalah kondisi **saat export**, bukan snapshot akhir bulan; durasi adalah estimasi, bukan timesheet. Kolom v1.3: requires testing, cycle, criteria. Activity history menampilkan 200 kejadian terbaru per task; data lebih lama tetap disimpan selama task tidak dihapus. Histori sebelum v1.3 tidak direkonstruksi. Hapus task juga menghapus riwayatnya; simpan export sebagai arsip.

## 9. Jadwal dan worker antrean

Default cron `0 1 * * *` UTC = target 08.00 WIB. Pada **Vercel Hobby**, eksekusi dapat terjadi 08.00–08.59 WIB, bukan alarm menit-presisi. Endpoint mematerialisasi recurring tasks dan mengantrekan ringkasan personal/grup. Email memakai cron terpisah dan tetap opsional.

Ringkasan maksimal 15 task, query dibatasi 51 untuk indikator 50+. Task aktif dengan jadwal/deadline hari ini atau lebih awal masuk ringkasan. Task tanpa tanggal tidak masuk briefing tetapi tetap ada di dashboard.

Worker: maksimal 20 pesan per cron, 4 setelah save, 12 lewat Process pending queue. Cocok personal/tim kecil. Jika antrean bertambah, aktifkan worker per menit agar tidak menunggu cron harian. Riwayat UI menampilkan 20 pengiriman terbaru, bukan ukuran seluruh antrean.

| Status | Arti / tindakan |
| --- | --- |
| pending | Belum dicoba; Process pending queue atau tunggu worker |
| sending | Sedang dicoba; lease yang kedaluwarsa menjadi uncertain |
| sent | Telegram menerima; bukan bukti dibaca |
| failed | Retry/backoff minimal 60 detik, maksimum 5 percobaan |
| skipped | Target nonaktif/putus/akses berubah, ringkasan kedaluwarsa, atau penolakan permanen; perbaiki konfigurasi lalu minta kartu baru |
| uncertain | Timeout/crash setelah kemungkinan terkirim; tidak retry otomatis. Periksa chat lalu gunakan /tasks |

Telegram sendMessage tidak menyediakan kunci idempotensi pengiriman; tidak ada janji exactly-once delivery saat gangguan jaringan. Perubahan status memakai update_id dan version dalam transaksi. Pengiriman memakai kebijakan konservatif untuk mengurangi duplikasi.

### Opsional: Supabase Cron setiap menit

Ini memakai kuota layanan (~43.200 HTTP request per 30 hari), bukan “gratis tanpa batas”.

1. Aktifkan Cron/pg_cron, pg_net, dan Vault pada Supabase sesuai dokumentasi project.
2. Buat Vault secrets melalui dashboard: `focusdesk_app_url` = APP_URL tanpa slash akhir; `focusdesk_cron_secret` = CRON_SECRET Vercel. Jangan menulis nilai asli dalam file SQL yang dibagikan.
3. Jalankan `supabase/06_optional_queue_worker.sql`. Script berhenti jika secret belum ada.
4. Periksa job `focusdesk-telegram-queue` dan hasil HTTP/job execution. Worker hanya memproses antrean, tidak mengubah jam briefing.
5. Untuk menghentikan dengan sengaja: `select cron.unschedule('focusdesk-telegram-queue');`. Ini menghapus jadwal worker tersebut, bukan task/antrean.

Alternatif Vercel Pro: cron per menit ke `/api/telegram-cron?mode=queue`. Jangan memasukkan cron per menit ke konfigurasi Hobby. Pilih satu worker terjadwal; dua worker tetap memakai kuota walaupun klaim antrean dilindungi lock.

## 10. Checklist pengujian akun Anda

- [ ] Migrasi sukses; task/PIC/user lama dan laporan tetap tersedia.
- [ ] Label aplikasi v1.3, package.json 1.3.0.
- [ ] Webhook production benar, tidak terkena redirect/protection.
- [ ] Pemilik dan programmer pairing akun masing-masing; kode lama ditolak.
- [ ] Grup dipasangkan oleh admin yang tepat.
- [ ] Task biasa terkirim dan tombol Done mengubah Focusdesk.
- [ ] PIC → Start work → Need Testing; PIC tidak bisa meluluskan testing.
- [ ] Pemilik → Start testing → Fail + alasan → Rework dan tag PIC.
- [ ] Perbaikan → Need Testing lagi → cycle naik → pemilik Pass → Done.
- [ ] Orang lain/tombol versi lama ditolak.
- [ ] Kegagalan kirim tidak membatalkan task; antrean menampilkan hasil.
- [ ] Briefing tanggal sama tidak diulang; cron produksi berjalan keesokan pagi.
- [ ] Occurrence berikutnya dibuat tanpa perlu membuka dashboard.
- [ ] Export bulanan memuat PIC, status testing, cycle, criteria.
- [ ] Modal dan Settings dapat digunakan pada mobile.

## 11. Troubleshooting

- **Origin tidak diizinkan:** APP_URL harus sama dengan origin yang dibuka; pakai satu domain canonical, redeploy.
- **Tabel/kolom/RPC tidak ditemukan:** jalankan upgrade lengkap pada project SUPABASE_URL yang benar; periksa schema cache bila perlu.
- **PIC tidak bisa klik:** akun aktif, PIC linked, task tersimpan dengan PIC itu, pairing dari akun programmer sendiri.
- **Bot tidak menjawab grup:** periksa webhook, admin, perintah @username, dan jangan kirim sebagai anonymous admin/channel.
- **/tasks kosong:** task harus aktif dan terjadwal/deadline hari ini/tertunda, grup cocok, akun punya akses.
- **Email invite/reset gagal:** periksa Supabase Auth SMTP/rate limit, bukan token Telegram.
- **Telegram 401/403:** token dicabut/salah, bot diblokir atau kehilangan akses grup. Perbaiki lalu /tasks; jangan bagikan token.
- **Grup menjadi supergroup / chat ID berubah:** disconnect grup lama, pairing baru, pilih grup baru pada task. Migrasi chat ID otomatis belum didukung.
- **uncertain:** periksa chat sebelum meminta kartu baru; Process pending queue tidak mengulang status ini.
- **failed sudah 5 kali / skipped:** perbaiki penyebab lalu minta kartu baru atau simpan ulang task; tidak ada reset retry massal.

## 12. Dokumentasi dan sumber

- `docs/PRD.md`: scope dan acceptance.
- `docs/ARCHITECTURE.md`: stack, folder, alur, schema, keamanan.
- `docs/USER_GUIDE.md`: pemakaian harian.
- `docs/TEST_RESULTS.md`: pengujian lokal dan batas verifikasi live.

Dokumentasi primer diperiksa 11 September 2026 (menu/kuota layanan dapat berubah):

- [Telegram Bot API](https://core.telegram.org/bots/api)
- [Telegram Bots FAQ](https://core.telegram.org/bots/faq)
- [Vercel deployment methods](https://vercel.com/docs/deployments/methods)
- [Vercel Cron usage](https://vercel.com/docs/cron-jobs/usage-and-pricing)
- [Supabase Cron](https://supabase.com/docs/guides/cron)
- [pg_net](https://supabase.com/docs/guides/database/extensions/pg_net)
- [Vault](https://supabase.com/docs/guides/database/vault)
