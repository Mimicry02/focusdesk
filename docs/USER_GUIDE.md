# Pemakaian harian — Focusdesk 1.4

## Baru di v1.4

**PIC contacts:** isi Username Telegram PIC, misalnya `@raka_dev`, dan hubungkan akun aktif dengan email yang sama. Programmer melakukan Connect personal dari akun Focusdesk miliknya. Yang sudah pairing cukup mengirim `/start` atau `/tasks` agar bot membaca username terbaru. Kembali ke PIC contacts untuk melihat status username cocok/belum pairing/tidak cocok.

Username adalah pengecekan tambahan, bukan identitas login. Numeric Telegram ID hasil pairing tetap menjadi identitas. Mismatch memblokir tindakan. Kontak lama tanpa username tetap memakai pairing lama. Edit koneksi kontak tidak otomatis mengganti assignee task lama; buka dan Save task untuk memperbaruinya.

**Grup:** kartu baru tidak memiliki tombol tindakan. PIC menerima Start work/Need Testing di DM; pemilik menerima tombol review di DM pada tahap testing. `/tasks` dari grup juga mengirim kartu pribadi sesuai akses pemanggil. Tombol lama v1.3 mungkin masih terlihat; server menolaknya dan mencoba menghapus keyboard ketika diklik.

**Sinkronisasi:** dashboard mengambil perubahan sekitar setiap 10 detik selama tab aktif, juga ketika modal terbuka. Indikator Sinkron menunjukkan waktu pembacaan sukses terakhir. Tab tersembunyi/offline berhenti polling dan mengambil ulang saat aktif/online. Tunggu konfirmasi bot “Status tersimpan”; klik saja belum membuktikan perubahan berhasil.

Jika task berubah saat modal terbuka, banner menampilkan status terbaru dan tombol penyimpanan/tindakan dikunci. Draf tetap berada di layar. Salin teks yang perlu dipertahankan, lalu pilih Muat detail terbaru dan setujui penggantian draf. Konflik versi di server tetap melindungi data.

**Dashboard:** kartu Tugas hari ini menghitung pekerjaan pribadi pada tanggal terpilih; In progress mencakup tugas saya/PIC; Menunggu review mencakup task milik Anda yang Ready for Testing/Testing; overdue memakai hari ini WIB. Review Desk membuka task yang perlu diuji. Kapasitas hanya menghitung estimasi pribadi, bukan delegasi. Laporan bulanan tetap snapshot: Generate ulang untuk data terbaru.

## Rutinitas

1. Pagi: baca briefing Telegram. Ketik /tasks untuk kartu tugas hari ini/tertunda. Atur task baru dan tanggal di Focusdesk.
2. Untuk penugasan: PIC contacts → akun programmer linked → task pilih PIC. Pilih grup bila informasi task boleh dibaca seluruh grup.
3. Task biasa: Start work → Done. Task System Analyst dengan review: aktifkan Wajib testing saat membuat task.
4. PIC selesai coding: Need Testing. Pemilik menerima notifikasi, Start testing, lalu Pass & close atau Fail & return.
5. Fail: reply prompt bot dengan fail: alasan yang baru dan jelas. Task menjadi Rework; PIC sama menerima notifikasi. Setelah perbaikan, ajukan Need Testing lagi.
6. Catatan: Add progress → reply progress: isi catatan. Jangan tulis rahasia jika task dibagikan ke grup.
7. Jika tombol lama ditolak: /tasks untuk kartu terbaru atau buka Focusdesk. Jangan mencoba menebak task dari nama di chat.
8. Recurring: New task → Repeat → pola/tanggal/interval. Selesai hari ini tidak menutup hari berikutnya. Stop repeating menghentikan seri dan menghapus occurrence mendatang belum selesai.
9. Laporan: Monthly reports → bulan/filter → Generate → Excel/CSV/Print PDF. Simpan sebagai arsip akhir bulan; laporan berikutnya menggunakan status terkini.
10. Gangguan Telegram: Settings → riwayat → Process pending queue. Untuk uncertain, periksa chat dahulu lalu /tasks; jangan mengulang massal.

Reviewer versi ini adalah pemilik task. Email-only PIC tidak bisa klik bot; akun harus aktif, linked, dan Telegram dipasangkan sendiri. Notes internal tidak dikirim, tetapi progres/kriteria testing bisa tampil di grup. Kalender Google masih ekspor manual.

Setup lengkap, env, SQL, BotFather, optional worker dan troubleshooting ada di README.md.
