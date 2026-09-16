# Focusdesk v1.5 — Scheduler Telegram 09.00 & 17.30 WIB

## Perilaku yang ditambahkan

| Jadwal, setiap hari | Ke grup aktif | Ke chat pribadi |
| --- | --- | --- |
| 09.00 WIB | Ringkasan tugas tertunda dan rencana hari ini, hanya task yang secara eksplisit dibagikan ke grup tersebut. | Kartu tugas hari ini/tertunda ke PIC yang terhubung; task Ready for Testing/Testing ke pemilik sebagai reviewer. |
| 17.30 WIB | Tugas tertunda sebelum hari ini, tugas hari ini yang belum Done, serta agenda besok. | Tidak mengirim batch kartu baru; notifikasi perubahan task tetap bekerja seperti sebelumnya. |

Termasuk Sabtu dan Minggu. Jam bersifat tetap pada rilis ini. Tampilan Settings menjelaskan jadwal dan panggilan scheduler terakhir; bukan editor jam. Zona waktu adalah Asia/Jakarta, UTC+7, bukan zona browser atau server hosting.

Ringkasan grup tidak memiliki tombol tindakan. PIC harus mempunyai akun aktif, linked ke contact, personal pairing, serta username cocok bila username diisi. Task email-only tidak dapat dikirimi kartu Telegram. Task pribadi tanpa PIC dapat diterima pemiliknya. PIC tidak menerima tombol Pass & close untuk task wajib testing.

**Definisi:**

- Tertunda sebelum hari ini: belum Done dan scheduled date atau due date lebih kecil dari hari ini WIB. Ini mencakup rencana yang tertinggal, tidak selalu berarti deadline sudah lewat.
- Hari ini/rencana hari ini: belum Done, scheduled date atau due date sama dengan hari ini, dan belum masuk kelompok tertunda.
- Agenda besok: belum Done dan scheduled date atau due date sama dengan besok. Task dapat juga muncul pada bagian tertunda bila sebelumnya sudah terlambat.
- Belum selesai termasuk In progress, Ready for Testing, Testing, dan Rework. Tidak otomatis dipindahkan ke Done, Overdue, atau tanggal baru.
- Task tanpa kedua tanggal tidak masuk briefing. Done dikeluarkan dari semua daftar.
- Angka jumlah menghitung seluruh task yang memenuhi filter. Pesan menampilkan maksimal 5 contoh per bagian agar ringkas; sisanya dibuka di Focusdesk. Isi menggunakan status saat worker menyiapkan pesan, bukan snapshot persis pukul 09.00/17.30.

## Pilihan scheduler

Gunakan **Supabase Cron** untuk kebutuhan waktu ini. Script aktivasi memanggil endpoint Vercel setiap menit; database memilih slot yang sedang berlaku dan hanya membuat antrean sekali per tanggal/slot. Selain memicu briefing, panggilan ini menguras antrean pengiriman hingga 20 pesan per panggilan.

Vercel tetap menyertakan fallback dua cron harian: `0 2 * * *` untuk pagi dan `30 10 * * *` untuk sore, dalam UTC. Pada Hobby, Vercel hanya memberi presisi per jam, sehingga fallback saja tidak memenuhi target menit. Pada Pro presisi penjadwalan per menit. Dedup database mencegah fallback dan Supabase membuat batch yang sama dua kali.

Satu menit adalah interval pemicu, bukan jaminan pesan sudah diterima pada detik tertentu. Antrean, retry, cold start, gangguan layanan, dan jaringan dapat menambah jeda. Ringkasan grup diproses lebih dahulu; kartu yang terkait grup menunggu ringkasannya selesai diproses, umumnya lewat tick berikutnya. Jika grup terputus, hasil kirim uncertain, atau retry grup habis, kartu pribadi tetap boleh berjalan agar PIC tidak ikut terblokir.

## Upgrade dari versi Anda

1. Backup database dan simpan source sebelumnya. Hentikan sementara perubahan saat upgrade.
2. Jika sudah **v1.4**, jalankan `Focusdesk_v1_4_to_v1_5.sql` di Supabase SQL Editor. Jika masih **v1.3**, gunakan `Focusdesk_v1_3_to_v1_5.sql` sebagai gantinya. Jangan menjalankan SQL fresh install pada database lama.
3. Ekstrak ZIP source v1.5, perbarui root repository yang berisi package.json, lalu deploy commit terbaru di Vercel.
4. Pertahankan seluruh env sebelumnya. Pastikan `APP_URL` adalah origin production stabil; `CRON_SECRET` minimal 32 karakter; token Telegram masih benar. Tidak ada env baru yang wajib.
5. Setelah deployment sukses dan SQL 08 terpasang, aktifkan Supabase Cron dengan langkah berikut.

SQL upgrade mempertahankan task, PIC, user, dan pairing. Aktivasi scheduler dipisahkan karena memerlukan Vault dan mulai memicu pekerjaan terjadwal. Paket file ini tidak otomatis menjalankan migrasi atau mengirim pesan ke grup Anda.

## Aktivasi Supabase Cron

1. Buka project Supabase yang dipakai Focusdesk. Aktifkan fasilitas **Cron/pg_cron**, **pg_net**, dan **Vault** melalui dashboard bila belum aktif. Script juga mencoba membuat ekstensi pg_cron dan pg_net.
2. Buat dua secret lewat antarmuka **Vault**. Nilai tidak ditempelkan ke file SQL yang dibagikan:

| Nama tepat | Isi |
| --- | --- |
| `focusdesk_app_url` | Nilai `APP_URL`, misalnya `https://focusdesk-anda.vercel.app`, tanpa slash di akhir. |
| `focusdesk_cron_secret` | Nilai yang sama persis dengan `CRON_SECRET` di environment Production Vercel. |

3. Pastikan masing-masing nama hanya memiliki **satu** secret. Jika sudah dibuat saat memakai worker v1.3/v1.4, perbarui nilainya bila perlu; jangan membuat duplikat.
4. Supabase → SQL Editor → jalankan `Focusdesk_Activate_Scheduler_v1_5.sql` (salinan `supabase/09_enable_telegram_scheduler.sql`).
5. Periksa job **focusdesk-telegram-scheduler** dengan ekspresi `* * * * *`. Script menghapus hanya worker lama bernama `focusdesk-telegram-queue` bila ada dan menggantikannya. Menjalankan script aktivasi kembali memperbarui named job yang sama.
6. Tunggu satu–dua menit, lalu buka Focusdesk → Settings & integrations → Telegram. Periksa **Panggilan terakhir**. Buka ulang Settings untuk pembacaan baru. Waktu terakhir bukan jaminan scheduler masih berjalan di masa depan.
7. Periksa status HTTP pada monitoring pg_net dan Vercel Functions. Cron SQL berstatus sukses hanya berarti request berhasil dijadwalkan; belum membuktikan respons HTTP atau pengiriman Telegram berhasil.

Job ini membuat sekitar **43.200 HTTP request per 30 hari**, ditambah fallback harian. Pantau kuota Supabase dan Vercel. Jangan mengaktifkan kembali worker 06 bersamaan karena panggilannya menjadi redundan.

Endpoint production harus dapat dijangkau dari Supabase tanpa halaman login Deployment Protection atau redirect. Autentikasi endpoint memakai header `Authorization: Bearer <CRON_SECRET>`; jangan menghapus pemeriksaan secret untuk membuat job berhasil. Konfigurasikan akses mesin sesuai pengaturan deployment Anda, atau gunakan scheduler Vercel dengan batas presisi paketnya.

## Pemeriksaan penerima sebelum jam briefing

1. Pemilik menghubungkan grup dan masih merupakan owner group connection di Focusdesk.
2. Pada task, pilih grup yang benar. Task yang hanya ditulis pada web tanpa memilih grup tidak akan muncul di ringkasan grup.
3. PIC mempunyai email akun linked, status aktif, personal pairing, dan username terverifikasi bila digunakan.
4. Pastikan scheduled date/deadline tepat. Kartu otomatis pagi memuat semua task yang relevan, bukan hanya 10 kartu seperti batas command /tasks.
5. Untuk task wajib testing, pastikan siapa pemilik task; pemilik itulah reviewer saat ini.

## Perilaku pemulihan dan anti-duplikasi

- Sebelum 09.00: tick hanya memproses antrean yang sudah ada; tidak membuat briefing pagi lebih awal.
- 09.00–17.29: kesempatan briefing pagi sekali. Jika scheduler baru pulih pukul 10.00, briefing pagi dapat dibuat saat itu.
- 17.30–23.59: kesempatan briefing sore sekali. Briefing pagi yang terlewat tidak dikirim menyusul pada malam hari.
- Setelah tengah malam: pesan terjadwal dari hari sebelumnya dilewati. Pesan pagi belum terkirim kedaluwarsa saat 17.30.
- Slot pagi/sore dan tanggal memiliki primary key tersendiri; retry/concurrent calls tidak membuat ulang batch.
- Card membaca task terkini tepat sebelum kirim. Done, role yang sudah tidak sesuai, dan username mismatch dilewati.
- Data recurrence dimaterialisasi sampai horizon 14 hari sebelum ringkasan dibuat; agenda besok dapat memuat occurrence berulang yang dihasilkan server.
- Sent berarti diterima API Telegram, bukan sudah dibaca. Timeout ambigu menjadi uncertain dan tidak diulang otomatis untuk mengurangi pesan ganda. Tidak dijanjikan exactly-once delivery oleh provider.
- Grup atau PIC baru yang dihubungkan setelah batch pagi dibuat ikut pada batch berikutnya. Gunakan /tasks untuk kartu pribadi saat ini; notifikasi task baru/perubahan tetap berjalan.

Tombol **Send personal briefing** di Settings adalah briefing pribadi manual v1.3, terpisah dari jadwal grup baru. Tombol itu tidak memicu atau menghabiskan slot pagi/sore grup. **Process pending queue** memproses antrean milik Anda, tidak membuat ulang batch.

## Monitoring cepat

Jalankan query baca berikut di SQL Editor bila dibutuhkan:

```sql
select * from public.fd_tg_scheduler_health;
select day, slot, created_at, materialized, summaries, cards
from public.fd_tg_schedule_runs order by day desc, slot limit 10;
select day, schedule_slot, kind, status, count(*)
from public.fd_telegram_outbox
where day = (now() at time zone 'Asia/Jakarta')::date
group by day, schedule_slot, kind, status order by schedule_slot, kind, status;
select jobid, jobname, schedule, active
from cron.job where jobname in ('focusdesk-telegram-scheduler','focusdesk-telegram-queue');
```

Jangan membagikan Vault decrypted secrets atau command cron yang sudah memuat secret secara literal. Tidak perlu mengirim token ke chat untuk troubleshooting.

## Menonaktifkan

Untuk menghentikan tick Supabase:

```sql
select cron.unschedule('focusdesk-telegram-scheduler');
```

Untuk menghentikan seluruh briefing terjadwal, hapus juga **dua entri Telegram** pada `vercel.json` lalu redeploy. Cron email `/api/digest` terpisah. Menonaktifkan jadwal tidak menghapus antrean yang sudah ada; antrean dapat tetap diproses oleh aktivitas aplikasi sampai kedaluwarsa. Jangan menghapus task atau tabel untuk mematikan jadwal.

## Sumber teknis

Dokumentasi diperiksa 16 September 2026:

- [Vercel Cron: presisi dan batas paket](https://vercel.com/docs/cron-jobs/usage-and-pricing)
- [Supabase Cron](https://supabase.com/docs/guides/cron)
- [Supabase: pg_cron, pg_net dan Vault untuk pemanggilan HTTP](https://supabase.com/docs/guides/functions/schedule-functions)

Prinsip pg_net/Vault yang sama digunakan untuk memanggil endpoint Vercel; paket ini tidak membuat Edge Function baru.
