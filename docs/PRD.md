# Product requirements — Focusdesk 1.5

## Tambahan rilis 1.5

Target tetap pengguna/pemilik, PIC dan grup yang sudah ada. Briefing setiap hari pukul 09.00 WIB ke grup aktif; eksekusi di DM PIC sesuai status; Ready for Testing/Testing ke DM pemilik. Evaluasi grup pukul 17.30 WIB memuat tertunda sebelum hari ini, hari ini belum selesai, dan agenda besok. Definisi serta batas kirim tertulis di SCHEDULER_GUIDE.

Acceptance tambahan: clock WIB dari database, morning/evening terpisah, kunci unik tanggal/slot, klaim SKIP LOCKED, fallback tidak menggandakan antrean, full counts dengan sampel maksimal 5, grup dibatasi owner+group, card revalidasi status/izin, expiry pagi 17.30 dan harian tengah malam, recurrence besok tersedia tanpa browser terbuka, semua kartu eligible dibuat meski >20 (worker bertahap), migrasi tanpa reset.

Non-goal: jam custom per pengguna/grup, janji detik-presisi, laporan historis snapshot di pukul yang tepat, DM kartu kedua pada sore hari, atau pengiriman ulang otomatis timeout ambigu.

UX: Settings menampilkan jadwal, heartbeat terakhir, dan label slot/day pada riwayat. Stack dipertahankan sesuai aplikasi existing; Supabase Cron digunakan untuk presisi pemicu dan pemrosesan antrean, dengan Vault untuk rahasia. Tidak ada perubahan ke demo HTML presentasi v1.4.

## Persyaratan yang dipertahankan


## Pengguna dan tujuan

Pemilik adalah System Analyst sekaligus freelancer Property/Web Development. PIC adalah programmer/pelaksana aktif yang menerima assignment. Admin mengelola akses pengguna; role admin tidak otomatis mendapat akses seluruh task orang lain.

Tujuan: satu sumber tugas di Focusdesk, notifikasi Telegram yang kontekstual, pengujian ulang oleh pemilik, checklist berulang, dan laporan bulanan. Tidak membuat tugas dari percakapan grup bebas.

## Scope rilis

- Pertahankan seluruh kemampuan v1.3 dan data lama.
- Pairing personal satu kali 10 menit; pairing grup oleh pengguna terhubung yang admin grup.
- Kontak PIC linked memberi akses; email-only tetap kontak, bukan identitas Telegram.
- Penugasan/rencana diedit di Focusdesk; status/progres di Focusdesk atau Telegram.
- Opt-in grup per task. Personal pairing menerima notifikasi tugas milik/assignment akun.
- requires_testing per task; reviewer adalah pemilik. Siklus test dan alasan kegagalan tersimpan.
- Daily briefing WIB, recurring server-side, antrean persisten, optional worker.
- Ekspor bulanan CSV/XLSX serta print/PDF manual.

## Acceptance criteria

1. Task lama tidak hilang/reset saat upgrade, migrasi bisa diulang.
2. Pemilik/PIC aktif saja yang mengubah task; grup/username bukan otorisasi.
3. PIC tidak dapat meluluskan task wajib testing atau mengubah PIC, rencana, kriteria.
4. Fail membutuhkan alasan baru; tugas kembali ke PIC yang sama.
5. Callback versi lama dan update duplikat tidak menimpa data baru.
6. Task tersimpan walau provider gagal; riwayat memperlihatkan pending/failed/uncertain.
7. Notes internal/email tidak muncul di pesan grup.
8. Recurring tidak memerlukan dashboard terbuka untuk menghasilkan occurrence.
9. Grup tidak memuat action keyboard; DM PIC menerima Start work/Need Testing, DM reviewer menerima tindakan testing sesuai tahap.
10. Expected username cocok dengan akun terpairing sebelum PIC bertindak; numeric ID tetap identitas.
11. Dashboard aktif memperbarui status dari Telegram tanpa refresh manual; modal draf dilindungi.
12. README membedakan upgrade/fresh SQL, env, webhook, pairing, kuota dan pengujian live.

## UX dan desain

Pertahankan identitas Focusdesk: sidebar, latar netral, aksen hijau, modal task dan layout responsif yang sudah ada. Tidak ada redesign marketing. Settings menambah panel Telegram penuh dengan status, pairing, grup, tindakan admin, antrean. Task menambah field grup/testing/kriteria dan tindakan workflow. Status terbaru tampil di daftar dan board. Dialog history menampilkan waktu, actor ID, transisi, note dan cycle.

Loading menggunakan indikator busy; error tidak dianggap success. Hasil pairing hanya tampil sekali untuk disalin; refresh memuat status koneksi. Tombol status tidak mengganti edit rencana. Checkbox task testing membuka dialog, bukan langsung menutup/reopen. Perubahan Telegram dimuat setiap sekitar 10 detik saat tab aktif, termasuk modal terbuka. Draf tidak ditimpa; modal berubah menjadi stale, menampilkan status terbaru dan meminta reload eksplisit sebelum save. Tampilan utama memisahkan Review Desk, My Work, Team Progress, kapasitas dan jadwal. Identitas visual hijau dipertahankan dengan kontras teks dan ruang yang lebih jelas.

## Batas yang disengaja

Belum ada tester terpisah, NLP bebas, penugasan via bot, WhatsApp, Google Calendar dua arah, upload bukti test, granular project membership, atau multi-owner dalam satu grup. Tasks per command maksimal 10, ringkasan 15, worker 20 per cron. Tidak dijanjikan exactly-once pengiriman provider. Penerapan live/beban besar memerlukan uji lanjutan, monitoring dan penyesuaian worker.
