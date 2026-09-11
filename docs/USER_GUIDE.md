# Pemakaian harian — Focusdesk 1.3

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
