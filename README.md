# Focusdesk v1.4.0 — Dashboard, PIC & Telegram sync

Buat/assign tugas di Focusdesk; terima briefing dan perbarui progres/testing lewat bot Telegram. Stack tetap Supabase + Vercel. Paket ini memperbarui source dan SQL aplikasi Anda. Koneksi Supabase/Telegram yang sudah berjalan dipertahankan melalui environment variables dan data pairing yang sama; paket belum diterapkan ke production Anda. Tidak ada token/password asli di ZIP.

## 1. Pilih SQL yang benar

| Kondisi | File yang dijalankan |
| --- | --- |
| Sudah menggunakan Focusdesk v1.3 dan SQL Telegram sudah terpasang | `Focusdesk_v1_3_to_v1_4.sql` saja (direkomendasikan untuk Anda) |
| Sudah menggunakan Focusdesk v1.0 / v1.1 / v1.2 | `Focusdesk_Upgrade_to_v1_4.sql` saja |
| Database baru, belum ada Focusdesk | `Focusdesk_Supabase_v1_4.sql`, lalu bootstrap admin |
| Ingin antrean diproses tiap menit | Opsional `supabase/06_optional_queue_worker.sql`, setelah bagian 9 |

**Backup database terlebih dahulu.** Jangan jalankan instalasi baru pada database lama. SQL upgrade digabung dalam satu transaksi dan dapat dijalankan ulang. Tidak ada DROP TABLE, reset pengguna, atau penghapusan task lama; beberapa fungsi, trigger, policy, dan constraint Focusdesk diganti untuk mendukung alur baru.

### Upgrade aplikasi berjalan

1. Simpan source/ZIP lama dan backup Supabase. Catat jumlah task serta beberapa ID untuk pembanding. Coba di staging dahulu bila memungkinkan.
2. Hentikan sementara aktivitas edit tim.
3. Supabase → SQL Editor → New query → tempel seluruh `Focusdesk_v1_3_to_v1_4.sql` (jika sudah v1.3), atau `Focusdesk_Upgrade_to_v1_4.sql` (versi lebih lama) → Run. Pastikan sukses.
4. Ekstrak ZIP v1.4. Folder yang berisi `package.json` adalah root project.
5. Perbarui repository deployment Anda dengan source v1.4. Jangan menimpa file rahasia lokal.
6. Pertahankan env lama → deploy commit terbaru ke production → login. Tidak ada env baru wajib untuk v1.4. Jika domain/token/webhook tidak berubah, tidak perlu pairing atau Register webhook ulang. Check webhook cukup untuk memeriksa URL.
7. Pastikan label v1.4, task lama, PIC, dan laporan masih terlihat. Jalankan checklist bagian 10.

Sesudah memakai status testing, jangan rollback aplikasi saja ke v1.2 karena versi lama tidak mengenali status baru. Pemulihan: perbaikan maju, atau restore backup database + source lama dalam maintenance window. Restore backup tidak memuat perubahan sesudah waktu backup.

### Instalasi baru

1. Buat project Supabase, jalankan `Focusdesk_Supabase_v1_4.sql`.
2. Authentication → Users → Add user: buat akun Anda dengan email/password yang benar dan selesaikan konfirmasi sesuai pengaturan Supabase.
3. Isi placeholder email di `supabase/02_bootstrap_admin.sql`, jalankan untuk admin pertama. **Bukan langkah upgrade.**
4. Authentication → URL Configuration: Site URL = domain production Vercel. Tambahkan domain yang sama pada redirect URLs; hindari wildcard domain sembarang.
5. Deploy, login, lalu undang programmer melalui User management. Akun harus aktif untuk mengakses task/pairing Telegram.

## 2. Perbaikan khusus v1.4

- Dashboard mengambil status terbaru setiap sekitar **10 detik selama tab aktif**, serta saat tab kembali aktif/koneksi kembali online. Tidak perlu refresh manual untuk Start work. Ini polling, bukan realtime push; latensi jaringan tetap berlaku.
- Indikator “Sinkron HH.MM.SS” menunjukkan waktu pengambilan sukses terakhir. Jika gagal, terlihat “Sinkronisasi tertunda”; aplikasi mencoba kembali. Polling tidak membuat occurrence berulang setiap 10 detik.
- **Grup menerima kartu informasi tanpa tombol tindakan.** Tombol pengerjaan ada di chat pribadi PIC, tombol review di chat pribadi pemilik/reviewer. `/tasks` dari grup mengirim kartu yang boleh diakses pemanggil ke chat pribadinya.
- Kolom **Username Telegram PIC** di PIC contacts, disertai status belum pairing / username tidak cocok / terverifikasi. Username bukan pengganti login dan pairing.
- Konfirmasi “Status tersimpan” dikirim setelah perubahan Supabase berhasil. Indikator tombol Telegram direspons lebih awal saat pemeriksaan berlangsung.
- Formulir terbuka tidak ditimpa oleh perubahan Telegram: banner menampilkan status terbaru, penyimpanan/tindakan versi lama dikunci, dan tombol “Muat detail terbaru” meminta persetujuan untuk mengganti draf di layar.
- Dashboard baru: tugas pribadi, In progress, review desk, overdue, kapasitas pribadi, jadwal dan progres PIC. Klik angka untuk membuka filter terkait. Pekerjaan delegasi tidak memakan kapasitas pribadi.
- Kesalahan izin suatu tindakan (403) tidak otomatis mengeluarkan pengguna dari sesi; sesi kedaluwarsa (401) tetap meminta login.

### Setelah upgrade: PIC yang sudah ada

1. PIC contacts → Edit → isi `@username_programmer`, centang koneksi akun aktif → Save PIC.
2. Programmer yang sudah pairing cukup mengirim `/start` atau `/tasks` di chat pribadi bot agar username aktual dibaca. Tidak perlu membuat ulang bot.
3. Kembali ke PIC contacts (atau refresh) dan pastikan **Username cocok · siap menerima tindakan**. Jika tidak cocok, pastikan email akun, username, dan akun Telegram yang dipakai benar.
4. Task lama tetap memakai assignee lama. Jika Anda baru menghubungkan akun PIC, buka task → pilih PIC → Save task agar assignment task diperbarui.
5. Kartu lama di grup mungkin masih menampilkan tombol lama. Server menolaknya dan menghapus tombol pada kartu tersebut saat diklik; ketik `/tasks` untuk kartu DM terbaru. Tidak ada penghapusan massal pesan grup.

Kontak lama tanpa username tetap memakai numeric ID hasil pairing untuk kompatibilitas. Mengisi username menambahkan pengecekan kecocokan; username yang berubah memerlukan pembaruan kontak dan `/start` dari PIC. Penggantian username oleh orang lain tidak memindahkan assignment maupun pairing.

Rilis ini memilih DM untuk tindakan dan pesan bersama untuk grup. Tidak mengimplementasikan pesan ephemeral Telegram.

### Kemampuan yang dipertahankan

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
5. Refresh Focusdesk. Satu grup hanya dapat terhubung ke satu pemilik Focusdesk pada v1.4.
6. Saat membuat/mengedit task, pilih **Bagikan ke grup Telegram**. Kosong = tidak dibagikan ke grup.

Privacy mode boleh tetap aktif. Bot memproses command, callback, dan reply task; obrolan biasa diabaikan/tidak disimpan. Bot admin dapat menerima pesan lebih luas daripada privacy-mode bot biasa. Di grup dengan beberapa bot, gunakan `/tasks@USERNAME_BOT`.

**Privasi:** semua anggota grup dapat membaca judul, project, kategori, PIC/reviewer, jadwal, deadline, progres, dan kriteria test yang dikirim. Notes internal dan email tidak disertakan. Jangan isi rahasia dalam progres/kriteria. Membership grup tidak memberi hak edit. Pesan lama tidak ditarik kembali ketika PIC/task/grup berubah atau koneksi diputus.

## 7. Assign task dan testing

1. Admin mengundang programmer melalui User management. Programmer menyelesaikan login dan aktif.
2. Buat PIC contact dengan email programmer dan username Telegram-nya, centang **Hubungkan ke akun aktif dengan email yang sama**.
3. Programmer login dan pairing personal Telegram sendiri. Kontak Email only tidak dapat mengubah task melalui bot.
4. Buat task → pilih PIC → aktifkan **Wajib testing oleh saya** bila perlu → isi kriteria → pilih grup opsional → Save.
5. Penyimpanan task dan antrean notifikasi terjadi bersama. Server mencoba mengirim segera; kegagalan Telegram tidak membatalkan task.

| Dari | Pelaku / tombol | Menjadi |
| --- | --- | --- |
| Backlog / To do / Rework | PIC pengerjaan: Start work | In progress |
| In progress | PIC pengerjaan: Need Testing | Ready for Testing |
| Ready for Testing | Pemilik: Start testing | Testing |
| Testing | Pemilik: Pass & close | Done |
| Ready for Testing / Testing | Pemilik: Return / Fail & return + alasan | Rework |
| Done dengan testing | Pemilik: Reopen with reason | Rework |

**Reviewer selalu pemilik task**, belum ada tester terpisah. Test cycle bertambah setiap kali masuk Ready for Testing. PIC tetap sama ketika Rework; penggantian PIC dilakukan di Focusdesk. PIC/kriteria tidak boleh diganti saat menunggu/dalam testing: kembalikan task dahulu.

Task tanpa testing bisa ditutup langsung oleh PIC pengerjaan. Jika tidak ada PIC, pemilik bertindak sebagai pelaksana. Pemilik tetap dapat mengelola rencana/status task biasa di web; tombol pengerjaan Telegram ditujukan kepada pelaksana. Task dengan testing tidak bisa melewati tahapan via checkbox, API, atau REST langsung. Testing yang sudah aktif tidak dapat dimatikan untuk melewati review.

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

Kalimat bebas “Done fixing ya tasks GEE Platform” tidak ditafsirkan otomatis. Gunakan tombol atau reply `done` pada kartu yang tepat. Versi pesan harus sama dengan task; tombol lama ditolak. `/tasks` menyediakan maksimal 10 kartu tugas hari ini/tertunda sesuai akses. Task masa depan dibuka di Focusdesk. Kartu grup v1.4 tidak memuat tombol tindakan. Hanya DM pengguna yang berhak menerima tombol sesuai tahap/perannya; server tetap memeriksa izin, versi, dan binding pesan pada setiap aksi.

Dashboard menyinkronkan setiap sekitar 10 detik saat tab aktif, termasuk ketika modal terbuka. Isi draf modal dipertahankan dan ditandai stale bila task berubah. Muat detail terbaru sebelum melakukan tindakan lanjutan. Tab tersembunyi berhenti polling lalu mengambil ulang saat aktif; reconnect juga memicu sinkronisasi. Laporan bulanan adalah snapshot dan perlu Generate ulang untuk isi terbaru.

## 8. Recurring dan laporan

New task → Repeat: Setiap hari / Hari kerja / Mingguan. Isi Scheduled day, interval, tanggal akhir opsional. “3 Posts Everyday (Area Tangerang)” adalah satu task harian, bukan otomatis tiga subtask. Jika ingin tiga checklist terpisah, buat tiga seri.

Horizon normal 14 hari; batas internal 31 hari; catch-up maksimal 31 hari ke belakang. Done hari ini tidak menutup besok. Occurrence masa depan tidak mengirim spam assignment; briefing pada harinya menampilkan task tersebut. Edit hanya memengaruhi occurrence yang dibuka, bukan template. Untuk perubahan seri: Stop repeating, lalu buat seri pengganti. Stop menghapus occurrence mendatang yang belum Done; Done dipertahankan.

PIC nonaktif menjeda generasi seri terkait. Grup yang diputus tidak dipakai occurrence baru. Task lama tidak otomatis dipindahkan saat kontak PIC diedit; simpan ulang task dengan PIC yang tepat.

Monthly reports → pilih bulan/dasar tanggal/lingkup/kategori/PIC → Generate → Excel / CSV / Print PDF. Status/PIC adalah kondisi **saat export**, bukan snapshot akhir bulan; durasi adalah estimasi, bukan timesheet. Kolom sejak v1.3: requires testing, cycle, criteria. Activity history menampilkan 200 kejadian terbaru per task; data lebih lama tetap disimpan selama task tidak dihapus. Histori sebelum v1.3 tidak direkonstruksi. Hapus task juga menghapus riwayatnya; simpan export sebagai arsip.

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
- [ ] Label aplikasi v1.4, package.json 1.4.0.
- [ ] Webhook production benar, tidak terkena redirect/protection.
- [ ] Pemilik dan programmer pairing akun masing-masing; kode lama ditolak.
- [ ] Grup dipasangkan oleh admin yang tepat.
- [ ] Task biasa terkirim dan tombol Done mengubah Focusdesk.
- [ ] PIC → Start work → Need Testing; PIC tidak bisa meluluskan testing.
- [ ] Pemilik → Start testing → Fail + alasan → Rework dan tag PIC.
- [ ] Perbaikan → Need Testing lagi → cycle naik → pemilik Pass → Done.
- [ ] Orang lain/tombol versi lama ditolak; grup tidak punya tombol tindakan baru.
- [ ] Biarkan tab dashboard aktif → PIC klik Start work → dalam sekitar 10 detik status menjadi In progress.
- [ ] Modal dengan draf terbuka → task berubah dari Telegram → draf tetap ada, banner muncul, Save terkunci.
- [ ] Username PIC tidak cocok → tombol pengerjaan tidak diberikan; username yang cocok dapat bertindak.
- [ ] Kegagalan kirim tidak membatalkan task; antrean menampilkan hasil.
- [ ] Briefing tanggal sama tidak diulang; cron produksi berjalan keesokan pagi.
- [ ] Occurrence berikutnya dibuat tanpa perlu membuka dashboard.
- [ ] Export bulanan memuat PIC, status testing, cycle, criteria.
- [ ] Modal dan Settings dapat digunakan pada mobile.

## 11. Troubleshooting

- **Origin tidak diizinkan:** APP_URL harus sama dengan origin yang dibuka; pakai satu domain canonical, redeploy.
- **Tabel/kolom/RPC tidak ditemukan:** jalankan upgrade lengkap pada project SUPABASE_URL yang benar; periksa schema cache bila perlu.
- **PIC tidak bisa klik:** akun aktif, PIC linked, task tersimpan dengan PIC itu, pairing dari akun programmer sendiri, dan username cocok. Kirim `/start` untuk memperbarui username yang dibaca bot. Cari tombol di DM, bukan kartu grup.
- **Start work tidak terlihat di web:** cek konfirmasi “Status tersimpan”, lalu indikator Sinkron pada tab aktif. Jika tertunda, periksa jaringan/session dan Vercel logs. Bila Supabase menunjukkan In progress tetapi UI belum, pastikan source v1.4 terdeploy dan lakukan hard refresh sekali. Bila bot tidak mengonfirmasi, periksa error di chat, versi kartu dan hasil migrasi; jangan menganggap klik sebagai bukti tersimpan.
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

Referensi dokumentasi primer (panduan awal 11 September; Telegram API diperiksa kembali 13 September 2026) (menu/kuota layanan dapat berubah):

- [Telegram Bot API](https://core.telegram.org/bots/api)
- [Telegram Bots FAQ](https://core.telegram.org/bots/faq)
- [Vercel deployment methods](https://vercel.com/docs/deployments/methods)
- [Vercel Cron usage](https://vercel.com/docs/cron-jobs/usage-and-pricing)
- [Supabase Cron](https://supabase.com/docs/guides/cron)
- [pg_net](https://supabase.com/docs/guides/database/extensions/pg_net)
- [Vault](https://supabase.com/docs/guides/database/vault)
