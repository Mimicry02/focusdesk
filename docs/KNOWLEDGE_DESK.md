# Focusdesk 1.6 — Knowledge Desk

## Tujuan dan keputusan produk
Telegram menjadi pintu masuk pertanyaan dan laporan. Panduan Published menjadi sumber jawaban. Jika belum membantu, pelapor memilih kategori dan mengonfirmasi eskalasi ke task Focusdesk. Laporan asli tidak dapat diedit; reply berikutnya menjadi catatan tambahan. Admin mengelola master lewat web, pelapor mengelola percakapan lewat bot, PIC/reviewer menjalankan workflow tugas yang sudah ada.

Rilis ini menggunakan pencarian PostgreSQL Full Text Search dengan konfigurasi `simple`, penyaringan kata umum Indonesia/Inggris, dan pengambilan bagian Markdown yang cocok. Tidak ada LLM, embedding, biaya API AI tambahan, atau jawaban generatif. Skor kecocokan bukan probabilitas kebenaran. Kutipan bisa kurang relevan; pelapor dapat memilih Belum membantu. Markdown harus memuat langkah sebenarnya; tidak ada manual GEE fiktif yang dipublikasikan otomatis.

## Sebelum mulai
1. Aplikasi v1.5 dan migrasi 08 sudah terpasang. Untuk instalasi baru gunakan SQL fresh v1.6.
2. Login admin Focusdesk; application owner adalah reviewer untuk seluruh aplikasi yang ia kelola.
3. Tambahkan PIC lewat menu PIC contacts, hubungkan email dengan akun aktif. PIC menghubungkan Telegram melalui Settings → Connect personal. Username kontak harus cocok jika diisi; identitas utama tetap Telegram numeric ID hasil pairing.
4. Hubungkan grup melalui Settings → Telegram → Connect group. Admin grup menjalankan `/connect kode` yang diterbitkan aplikasi.
5. Buka Knowledge Desk dari sidebar. Halaman langsung: `/desk.html`.

## Konfigurasi master, berurutan
1. Overview → **Buat master awal**. Aman ditekan ulang: seed tidak menggandakan nama.
2. Categories: Pertanyaan, Bug, Permintaan Akses, Enhancement, Data Issue. Edit nama/deskripsi atau nonaktifkan.
3. Priorities: nama, mapping board Low/Medium/High, urutan, target respons dan selesai. Critical adalah nama priority support dengan mapping High pada board lama. Tidak mengubah enum atau laporan task lama.
4. Applications: kode unik per workspace (contoh GEE), nama, work area, default priority, PIC utama/cadangan, wajib testing, aktif. PIC kosong berarti triage oleh application owner.
5. PIC routing: buat satu baris per aplikasi + kategori. Pilih PIC kategori atau kosong untuk default aplikasi. Priority per kategori wajib dipilih; menjadi priority eskalasi. Maksimal 20 kategori aktif per aplikasi. Default aplikasi adalah acuan pengaturan awal; priority route adalah nilai final.
6. Group access: hubungkan aplikasi dengan grup terdaftar milik application owner. Satu grup boleh mengakses beberapa aplikasi, satu aplikasi boleh dipakai beberapa grup. Publikasikan hanya panduan yang boleh dilihat seluruh anggota grup tersebut.
7. Knowledge articles: pilih aplikasi, judul, kata kunci/sinonim, impor `.md` atau tulis isinya. Simpan Draft untuk ditinjau, lalu Published. Artikel Archived/Draft tidak dicari bot. File maksimal 200 KB; isi maksimal 150.000 karakter, 200 bagian. Dokumen dipecah per heading dan batas panjang pesan. Simpan sebagai artikel terpisah jika terlalu panjang.

## Percakapan Telegram
- `/apps` → aplikasi yang diizinkan di grup.
- `/ask GEE Bagaimana cara membuat preset filter?` → satu kutipan bagian panduan, judul, heading, revisi sumber.
- Jika grup hanya memiliki satu aplikasi, kode dapat dihilangkan: `/ask Bagaimana cara membuat preset filter?`.
- Untuk grup dengan beberapa bot, gunakan `/ask@username_bot GEE pertanyaan` atau `/apps@username_bot`.
- Pakai command eksplisit atau reply pesan bot. Bot tidak otomatis membaca seluruh obrolan/mention biasa. Privacy Mode dapat tetap aktif; Telegram mengirim command yang ditujukan ke bot dan reply pesan bot.
- Pelapor tidak wajib punya akun Focusdesk untuk bertanya di grup yang sudah disetujui admin. Laporan tetap terikat numeric Telegram ID dan chat asal. PIC/reviewer wajib punya akun aktif yang dipasangkan.
- **Terbantu** → menyelesaikan pertanyaan yang belum menjadi task. Jika task sudah ada, ini hanya feedback; tidak menutup task.
- **Belum membantu / tambah detail** → reply dengan keterangan. Bot menyimpan koreksi, mencoba mencari panduan lagi, lalu menawarkan eskalasi.
- **Buat laporan** → pilih kategori → periksa ringkasan → **Kirim laporan**. Tombol Batal membatalkan pembuatan task, bukan menghapus percakapan.
- Tombol di grup terlihat oleh semua orang; server hanya menerima tindakan dari pelapor asli. Kartu execution tetap dikirim ke DM PIC, kartu review mengikuti aturan reviewer v1.4/v1.5.
- Setelah konfirmasi, routing memilih PIC kategori/default yang aktif dan cocok pairing-nya, kemudian cadangan. Jika tidak ada PIC siap, task masuk ke application owner untuk triage. Nama PIC sebenarnya dikonfirmasi setelah transaksi tersimpan.
- Satu laporan hanya menghasilkan satu task walaupun klik berulang atau webhook diulang. Laporan terpisah dari user lain tidak digabung otomatis.
- Reply pesan support bot menambahkan informasi, tidak menimpa pertanyaan. Untuk laporan yang sudah menjadi task, kartu tugas dikirim ulang ke PIC agar melihat pembaruan; detail koreksi tersedia di halaman Reports.
- Perubahan status task mengirim notifikasi ke grup asal, tidak memuat internal progress note. Pelapor dapat melihat status dan memberi catatan; hanya PIC/reviewer sesuai perannya yang mengubah status kerja.
- File/foto Telegram belum diimpor sebagai lampiran di v1.6. Gunakan keterangan teks atau tautan yang dapat diakses PIC. File `.MD` diunggah lewat web admin.

## Laporan dan hak akses
Reports di Knowledge Desk hanya baca, termasuk bagi admin. Tidak ada API web untuk update/delete laporan. Database menolak perubahan identitas/pertanyaan asli dan perubahan/hapus catatan, bahkan jika melalui backend. Admin pemilik aplikasi dan PIC terpilih bisa melihat laporan; pelapor yang sudah terhubung saat laporan dibuat dapat melihat laporan miliknya di web. Akun lain tidak dapat membacanya. Akun baru yang dipasangkan belakangan tidak otomatis mengambil alih laporan lama.

Reports menampilkan 50 baris per halaman, detail kutipan panduan saat dijawab, target selesai, task terkait, dan audit/catatan. Export CSV mengekspor halaman yang sedang ditampilkan. Monthly reports task lama tetap tersedia untuk laporan pekerjaan bulanan. Target respons/selesai dihitung dalam jam kalender sejak eskalasi; ini target tersimpan, bukan SLA hari kerja, notifikasi breach, atau pengukuran respons pertama otomatis.

Permintaan akses juga tetap melewati review: bot membuat task, tidak memberikan hak akses GEE atau aplikasi lain secara otomatis. Knowledge baru dari hasil resolusi dibuat admin secara manual lewat Knowledge articles; publikasi otomatis, penggabungan laporan terpisah, dan reviewer terpisah dari application owner belum tersedia.

## Keandalan dan scheduler
Webhook menyimpan perubahan laporan dan pesan balasan pada transaksi database. Outbox mengirim reply dengan retry terbatas untuk kegagalan yang jelas, tetapi tidak mengirim ulang otomatis jika respons Telegram tidak pasti (`uncertain`). Worker scheduler yang sama menguras outbox support; webhook juga mengirim balasan segera. Status tasks dari web akan dinotifikasi pada tick worker berikutnya, biasanya sekitar satu menit jika cron sehat.

Jadwal lama tetap 09:00 dan 17:30 Asia/Jakarta. Jalankan pemeriksaan `supabase/11_diagnostics.sql`. Satu pesan manual berhasil tidak membuktikan cron aktif. `401` perlu dibaca bersama `content`; bisa berasal dari pemeriksaan secret endpoint atau API downstream. Jangan mereset secret berulang tanpa bukti. `Success, no rows returned` pada SELECT terfilter berarti tidak ada baris yang cocok, bukan bukti jadwal berhasil.

## Struktur dan aturan pengembangan
- `api/desk.js`: API session web, master admin, laporan scoped read-only.
- `server/knowledge.js`: pemecah Markdown, normalisasi query, parser command/callback.
- `server/desk.js`: percakapan grup dan pengiriman outbox support.
- `server/telegram.js`: dispatch ke Knowledge Desk sebelum aturan pairing tugas lama.
- `api/telegram-cron.js`: schedule/drain lama + drain support.
- `public/desk.html`, `public/desk.css`, `public/js/desk-ui.js`: halaman pengelolaan baru.
- `supabase/10_knowledge_desk.sql`: migrasi additive, RPC tervalidasi, RLS, trigger laporan/status.
- `scripts/test-v16-sql.mjs`, `scripts/test-v16-ui.mjs`, `tests/knowledge.test.mjs`: pemeriksaan perilaku.

Gunakan ESM, prepared SQL parameters, escaping DOM, same-origin HttpOnly sessions. Jangan menambahkan endpoint generik yang mengizinkan table/column dari request. RPC bot hanya service_role; jangan memberikan grant execute ke authenticated. Isi Markdown dan chat adalah data, bukan instruksi sistem atau SQL. RLS dan validasi callback adalah otoritas izin. Secrets hanya environment server/Vault.

Relasi utama: applications → routes → categories/priorities/PIC; applications ↔ Telegram groups lewat group mappings; applications → articles → chunks; applications → support_requests → notes dan task. UUID untuk relasi, bigint untuk Telegram IDs/update IDs/report number, timestamptz untuk waktu. Semua nama baru dipisahkan dari tabel tugas lama. `fd_support_requests.task_id` FK restrict mencegah task terkait dihapus tanpa merusak audit laporan.

## Uji penerimaan setelah deployment
1. Buat aplikasi TEST, satu route Bug, satu mapping grup uji.
2. Publikasikan artikel uji dengan heading dan isi yang memuat dua kata kunci unik.
3. Dari anggota grup, gunakan `/ask TEST dua-kata-kunci`. Periksa sumber/revisi.
4. Akun lain menekan tombol laporan tersebut: harus ditolak.
5. Pilih Buat laporan → Bug → Kirim laporan dua kali: satu task saja.
6. PIC menerima kartu pribadi, Start Work mengubah status web; grup menerima notifikasi.
7. Ready for Testing → reviewer Testing → Done; pelapor tidak bisa mengambil tindakan reviewer.
8. Reply koreksi; pastikan pertanyaan asli utuh dan audit bertambah.
9. Nonaktifkan mapping grup/artikel dan pastikan tidak lagi dikirim/dicari.
10. Periksa cron health pada dua waktu berbeda tanpa menjalankan request manual, lalu amati kiriman nyata 09:00 dan 17:30.

Referensi platform: https://core.telegram.org/bots/faq · https://core.telegram.org/bots/features · https://supabase.com/docs/guides/database/full-text-search
