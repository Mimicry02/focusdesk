# Focusdesk v1.5.0 — Briefing Telegram pagi & sore

Rilis source aplikasi Supabase + Vercel. Tambahan utama: ringkasan grup **09.00 WIB**, kartu tindakan pribadi PIC/reviewer, serta evaluasi **17.30 WIB** untuk tugas tertunda dan agenda besok. Data, user, PIC, dan pairing lama dipertahankan. Paket ini belum diterapkan ke production Anda.

## 1. Upgrade dan aktivasi

| Kondisi database | SQL yang dijalankan |
| --- | --- |
| Sudah v1.4 | `Focusdesk_v1_4_to_v1_5.sql` |
| Masih v1.3 | `Focusdesk_v1_3_to_v1_5.sql` |
| Masih v1.0/v1.1/v1.2 | `Focusdesk_Upgrade_to_v1_5.sql` |
| Database baru | `Focusdesk_Supabase_v1_5.sql`, lalu bootstrap admin |
| Setelah source v1.5 live dan Vault siap | `Focusdesk_Activate_Scheduler_v1_5.sql` |

1. Backup database/source; pilih **satu** SQL upgrade sesuai versi. Jalankan seluruh isinya di SQL Editor.
2. Ekstrak ZIP, perbarui repository dari root yang berisi package.json, lalu deploy commit terbaru ke Vercel. Pertahankan environment variables lama; tidak ada env baru wajib.
3. Pastikan `CRON_SECRET` >=32 karakter, token bot, dan `APP_URL` production benar. Pairing ulang tidak diperlukan jika akun/domain/bot tetap sama.
4. Ikuti **[panduan scheduler lengkap](docs/SCHEDULER_GUIDE.md)**: buat/periksa Vault `focusdesk_app_url` dan `focusdesk_cron_secret`, lalu jalankan SQL aktivasi setelah deployment sukses.
5. Periksa Settings → Telegram → Panggilan terakhir, riwayat pengiriman, serta job Supabase. Pastikan grup terhubung, task memilih grup, dan PIC linked + pairing.

Vercel Hobby tidak menjamin cron pada menit yang tepat. Pemicu setiap menit melalui Supabase Cron merupakan jalur yang disiapkan untuk kebutuhan Anda, dengan penggunaan sekitar 43.200 request/30 hari dan latensi pengiriman tetap mungkin. Dua cron Vercel harian menjadi fallback dan berbagi dedup database.

SQL upgrade additive/replay-safe; tidak mereset task/user/pairing. Jangan memakai fresh install pada database lama. Jangan rollback source saja ketika skema/alur baru sudah digunakan; simpan backup untuk pemulihan terkoordinasi.

Instalasi baru: jalankan full SQL, buat user Anda melalui Supabase Authentication, sesuaikan email pada `supabase/02_bootstrap_admin.sql`, lalu jalankan untuk admin pertama. Atur Site URL/redirect sesuai domain Vercel. Detail env/BotFather/PIC/kalender/laporan ada di bagian berikut.

## 2. Fitur yang dipertahankan dari v1.4

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

## 9. Scheduler Telegram v1.5

Target **09.00 WIB**: ringkasan grup dan kartu DM sesuai PIC/reviewer. Target **17.30 WIB**: tugas tertunda, belum selesai hari ini, dan agenda besok ke grup. Setiap hari termasuk akhir pekan; hanya task yang dibagikan ke grup yang dimuat.

**Aktivasi wajib untuk pemicu per menit:** ikuti [docs/SCHEDULER_GUIDE.md](docs/SCHEDULER_GUIDE.md). Buat dua Vault secrets, deploy source v1.5, lalu jalankan `Focusdesk_Activate_Scheduler_v1_5.sql`. Script ini menggantikan worker lama 06. Menjalankan SQL upgrade saja belum mengaktifkan Supabase Cron.

Vercel menyertakan dua fallback cron harian, dengan batas presisi per jam pada Hobby. Supabase Cron dipilih untuk pemicu setiap menit. Pengiriman tetap dipengaruhi antrean/jaringan, bukan jaminan tepat detik. Email opsional tetap mempunyai jadwal 08.00 WIB yang terpisah.

Ringkasan baru menghitung seluruh task, dengan maksimum 5 contoh per bagian. Kartu pagi dikirim bertahap melalui worker (maksimum 20 pesan per panggilan). Batch per tanggal/slot dilindungi kunci unik; task yang sudah Done/izin berubah tidak dikirimi kartu terjadwal. Ringkasan grup didahulukan sebelum kartu terkait; backlog diproses pada tick berikutnya.

Status antrean: pending → sending → sent, atau failed (retry/backoff, maksimum 5 percobaan), skipped (tidak relevan/expired/target terputus), uncertain (kemungkinan sudah terkirim; jangan retry massal). Sent berarti diterima API, bukan dibaca. Tidak ada jaminan exactly-once dari Telegram.

Tombol Send personal briefing tetap mengirim ringkasan pribadi manual terpisah. Untuk aktivasi, definisi filter, monitoring, recovery dan cara berhenti, gunakan SCHEDULER_GUIDE.

## 10. Checklist pengujian akun Anda

- [ ] Migrasi sukses; task/PIC/user lama dan laporan tetap tersedia.
- [ ] Label aplikasi v1.5, package.json 1.5.0.
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
- **Start work tidak terlihat di web:** cek konfirmasi “Status tersimpan”, lalu indikator Sinkron pada tab aktif. Jika tertunda, periksa jaringan/session dan Vercel logs. Bila Supabase menunjukkan In progress tetapi UI belum, pastikan source v1.5 terdeploy dan lakukan hard refresh sekali. Bila bot tidak mengonfirmasi, periksa error di chat, versi kartu dan hasil migrasi; jangan menganggap klik sebagai bukti tersimpan.
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
