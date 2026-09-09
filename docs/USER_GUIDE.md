# Focusdesk — User Guide v1.0

## Login pertama

Masuk menggunakan akun yang sudah dibuat/diundang dan diaktifkan. Tidak ada mode demo otomatis. Jika Anda baru menerima undangan, buka email lalu buat password minimal 12 karakter, kemudian login. Akun biasa tidak memiliki menu User management.

## Mengelola pekerjaan

- **New task** membuka formulir. Tentukan nama hasil kerja, area, project, jenis, prioritas, status, deadline, tanggal pengerjaan, jam mulai, estimasi menit, dan notes.
- Area awal: Full Time, Property, Web Development. Project berupa teks; master area/project khusus belum tersedia.
- Deadline adalah batas selesai. Scheduled day adalah kapan Anda mengerjakannya. Boleh berbeda.
- Untuk backlog yang belum dijadwalkan, pilih Backlog dan kosongkan Scheduled day/Start time. Status Backlog saja tidak menghapus jadwal.
- Maksimal tiga tugas Top 3 yang belum selesai pada tanggal sama; aturan juga dijaga di database.
- Durasi 5–720 menit. Form memakai kelipatan lima. Sesi tidak boleh melewati tengah malam; pecah menjadi dua tugas/sesi bila perlu.
- Jam kosong berarti fleksibel. Kalender ekspor memakai default 09.00 WIB untuk tugas tersebut.
- Jadwal bertabrakan diberi peringatan tetapi tetap boleh disimpan. Periksa Calendar sebelum mengerjakannya.
- Centang tugas untuk Done. Hilangkan centang untuk mengembalikan To do. Untuk status lain, buka detail tugas.
- Perubahan data baru dianggap tersimpan setelah server merespons. Jika muncul konflik versi, tutup detail, klik Refresh di kanan atas, lalu edit ulang.
- Delete menghapus tugas setelah konfirmasi, tanpa undo. Event yang sudah diekspor ke Google Calendar tidak ikut dihapus.

## Tampilan kerja

- Overview: pilih tanggal untuk prioritas, tugas terjadwal, kalender, dan workload pada tanggal itu. Needs attention menghitung tugas terlambat relatif hari ini di WIB.
- All tasks: pencarian nama/project/notes; filter area dan status; tampilan List/Board. Board belum mendukung drag-and-drop: ubah Status pada detail kartu.
- Marketing & follow-up: tugas jenis Marketing dan Follow-up, bukan CRM kontak terpisah.
- Calendar: pindah minggu atau pilih tanggal, lalu tambah/edit blok. Semua waktu menggunakan WIB.
- Insights: estimasi menit per hari pada minggu yang memuat tanggal terpilih; progres area dan delivery menghitung seluruh data akun. Saran berupa aturan tetap, bukan AI.
- Timer 25 menit: tombol Play pada prioritas memilih tugas. Start/Pause/Reset tersedia. Timer tidak mengubah status tugas, tidak merekam jam kerja, dan hilang saat reload/logout.

## Preferensi dan email

Settings memuat nama, kapasitas, preferensi email, ubah password, dan status briefing. Kapasitas awal 360 menit mencakup semua area kerja; ubah sesuai kemampuan. Statistik waktu memakai estimasi, bukan durasi timer.

Pengiriman briefing membutuhkan Resend + domain pengirim terverifikasi + environment variables + Vercel Cron. Default target 08.00 WIB; Vercel Hobby memberi jendela waktu per jam, sehingga bisa diterima lebih lambat. Preferensi email menentukan siapa yang masuk cron. **Send today’s briefing** mengirim manual ke email akun Anda setelah konfirmasi, termasuk ketika preferensi cron dimatikan. Manual dan cron berbagi batas satu briefing per hari WIB.

Status `accepted` berarti penyedia email menerima permintaan, bukan bukti masuk inbox. `sending` menandakan klaim masih berlangsung. `failed` dapat dicoba kembali setelah penyebabnya diperbaiki. Percobaan ulang setelah 10 menit memakai idempotency key yang sama; setelah respons ambigu, periksa log provider sebelum berasumsi gagal.

Penerima selalu email akun yang terverifikasi, bukan alamat arbitrer. Versi ini dibatasi 10 akun aktif yang mengaktifkan cron; lebih dari itu perlu antrean/pagination worker. Ini berbeda dari jumlah total akun yang dapat login. Isi email maksimal 500 tugas relevan per pengguna; aplikasi tetap memuat keseluruhan data.

## Google Calendar

Export calendar mengunduh semua tugas terjadwal yang belum Done ke `.ics`; impor manual ke Google Calendar. Detail tugas memiliki Add to Google Calendar yang membuka draf event. Simpan perubahan tugas dulu, tutup/buka detail, baru gunakan tautan.

Belum ada Google OAuth, baca kalender Google, sinkronisasi otomatis, atau penanganan perubahan dua arah. Impor berulang bisa membuat event ganda.

## User management (admin)

1. Invite user → masukkan nama/email → Send invitation. Email sungguhan dikirim oleh Supabase melalui SMTP yang Anda konfigurasi. Role awal selalu user.
2. User menerima tautan, mengatur password sendiri, lalu login ke workspace kosong. Tidak perlu membagikan password admin.
3. Manage → pilih role admin/user dan status aktif → Save access → konfirmasi.
4. Nonaktifkan untuk menghentikan permintaan data berikutnya. Data tidak dihapus. Informasi yang sudah dilihat/diunduh sebelumnya tidak bisa ditarik kembali.
5. Reset password mengirim instruksi ke email akun terpilih setelah konfirmasi. Admin tidak melihat atau menetapkan password pengguna.
6. Akun sendiri tidak boleh diturunkan rolenya atau dinonaktifkan dari UI/RPC. Ini menjaga setidaknya satu admin aktif selama semua perubahan dilakukan melalui aplikasi.
7. Audit menampilkan perubahan akses terbaru. Ini bukan audit lengkap seluruh aktivitas auth atau perubahan tugas; audit auth tersedia di Supabase.

Admin aplikasi tidak dapat melihat tugas akun lain. Pemilik proyek Supabase yang memegang akses SQL/service key tetap memiliki akses infrastruktur; jangan menyamakan admin aplikasi dengan administrator database.

## Kebiasaan harian

Pagi: pilih tiga prioritas dan beri blok waktu. Saat terganggu: catat permintaan baru ke backlog. Kelompokkan follow-up freelance sesuai waktu yang tersedia. Sore: update status dan jadwalkan ulang sisa tugas. Gunakan kapasitas untuk membatasi komitmen, bukan memaksimalkan semua slot.

## Belum termasuk

Tugas berulang, subtasks, dependency, lampiran, organisasi/team workspace bersama, hard delete user, public signup, MFA UI, custom category, data migration dari prototype, dan Google Calendar sync otomatis. Dashboard baru mulai kosong; data contoh lama tidak dikirim ke cloud.
