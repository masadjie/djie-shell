# Changelog

Semua perubahan penting di Djie Shell. Format mengikuti [Keep a Changelog](https://keepachangelog.com/id-ID/1.1.0/), versi mengikuti [Semantic Versioning](https://semver.org/lang/id/).

Download versi terbaru: [Releases](https://github.com/masadjie/djie-shell/releases/latest) · Website: [masadjie.github.io/djie-shell](https://masadjie.github.io/djie-shell/)

---

## [Unreleased]

### Baru
- **🔑 Isi password sudo dari host tersimpan** — saat terminal SSH menampilkan prompt `[sudo] password for <user>:` (atau `Password:` setelah perintah `sudo`), muncul tawaran mengisi password tersimpan host itu: **Tab** atau klik untuk mengisi, **Esc** untuk menutup. Hanya muncul jika user di prompt sama dengan user host dan password-nya tersimpan; tidak pernah mengisi otomatis, tidak ikut broadcast atau riwayat, dan tidak ditawarkan untuk `su` (password root) maupun login SSH ke server lain (macOS & Windows)

## [0.5.1] — 2026-11-23

Rilis perbaikan untuk v0.5.

### Diperbaiki
- Terminal: ikon prompt Oh My Posh / Starship / Powerlevel (folder, OS, git, panah powerline) tidak lagi tampil sebagai kotak □. Djie Shell kini membawa font ikon [Symbols Nerd Font](https://www.nerdfonts.com/) sebagai cadangan, tanpa perlu instal font apa pun; huruf biasa tetap memakai font terminal (macOS & Windows)
- Tim: admin tidak lagi berubah jadi anggota "menunggu admin" saat vault yang sama dipakai ganti akun Google lalu disinkron. Tim yang telanjur begitu dipulihkan saat sinkron jika kunci adminnya masih ada di vault; jika tidak, app menjelaskan masalahnya (core, tampilan macOS & Windows)
- Tim (macOS): keterangan waktu sinkron ikut bahasa app
- Broadcast terminal tidak lagi meneruskan balasan otomatis terminal (mis. laporan posisi kursor `ESC[10;10R`) ke panel lain — sebelumnya bisa muncul teks aneh seperti `;10R` di server lain (macOS & Windows)

## [0.5.0] — 2026-11-21

Rilis terbesar sejauh ini: Dashboard semua server, Kelola Server, backup database, Docker, split & broadcast, dan versi Linux (beta).

### Baru
- **🌐 Dwibahasa: Indonesia & English** di Mac, Windows, dan Linux — ikut bahasa sistem, atau pilih di menu Tampilan / halaman Tentang / Akun ("Bahasa / Language"). Pesan error dari server & core ikut diterjemahkan. Kamus bersama di `i18n/`

### Baru
- **🐧 Linux (beta)** — app Linux pertama (GTK4 + libadwaita + terminal VTE) di atas core Rust yang sama: vault terenkripsi, daftar & editor host (password / SSH key / agent, jump host, proxy), tab terminal SSH & lokal, Keychain, dan Snippets. Skrip build AppImage & Flatpak dasar di `scripts/`. SFTP, Database, Docker, Dashboard, Tim, dan sync Google menyusul
- **📊 Dashboard semua server** — menu baru paling atas di sidebar
  - Kartu per server: CPU dengan grafik kecil, RAM, disk, load, uptime, kecepatan jaringan — diperbarui tiap 5 detik, tanpa agen (cukup SSH)
  - Ringkasan: server online, yang perlu perhatian, CPU rata-rata, total RAM terpakai
  - Peringatan oranye di atas 75% dan merah di atas 90%; server offline ditandai dan dicoba ulang otomatis tiap 20 detik
  - Filter *Semua · Perlu perhatian · Offline* dan pencarian (nama, OS, grup)
  - Pilih 2–4 server → **Split & broadcast** dalam satu klik; atau buka terminal / SFTP langsung dari kartu
- **🔔 Notifikasi server** — tombol *Notifikasi* di Dashboard: tetap memantau di latar belakang dan memberi notifikasi desktop (macOS & Windows) saat server mati, pulih lagi, atau CPU/RAM/disk melewati 90%; klik notifikasi membuka Dashboard
- **▶️ Jalankan perintah di banyak server** — satu perintah ke banyak server sekaligus (8 paralel)
  - Hasil per server: sukses/gagal, exit code, output (stdout + stderr), durasi; yang gagal otomatis terbuka
  - Pilih server (semua / hanya online), ambil dari Snippet, atur batas waktu (30 detik – 30 menit)
  - *Ulangi yang gagal* dan *Salin semua* output
- **🛠️ Kelola Server** — menu baru: pilih server, lalu
  - **Proses** ala htop: urut CPU/memori/PID, cari, hentikan (SIGTERM) atau kill -9
  - **Service systemd**: start, stop, restart, reload, aktif/nonaktif saat boot, status lengkap, langsung ke log-nya (konfirmasi saat menghentikan SSH)
  - **Cron**: daftar jadwal dengan penjelasan bahasa biasa (“Tiap Senin–Jumat pukul 08.00”), tambah/ubah dengan preset, aktif/nonaktif, hapus
  - **Log**: journalctl per service & level, file log umum (nginx, syslog, auth, …), saring, mode ikuti
  - Aksi yang butuh root memakai `sudo -n` otomatis; user tanpa sudo mendapat penjelasan yang jelas
- **💾 Backup & restore database** — tombol backup di tiap koneksi MySQL, MariaDB, PostgreSQL, MongoDB, SQLite
  - Lewat host SSH: `mysqldump` / `pg_dump` / `mongodump` dijalankan di server, hasilnya dialirkan & dikompres di komputer ini (tanpa memasang apa pun)
  - Koneksi langsung: memakai alat di komputer ini (PATH, Homebrew, MAMP, komponen Server Lokal)
  - Jadwal harian / mingguan pada jam pilihan, simpan N backup terakhir, opsional unggah ke Google Drive; notifikasi bila backup terjadwal gagal
  - Restore dari daftar backup dengan konfirmasi; progres & tombol batal
- **🐳 Docker** — kelola Docker di komputer ini atau di server mana pun lewat SSH, tanpa expose port Docker
  - Container dikelompokkan per proyek Compose: start, stop, restart, pause, hapus
  - CPU & RAM live tiap container, log yang ikut berjalan (300 – 5.000 baris)
  - Satu klik buka shell di dalam container (tab SSH, atau terminal lokal)
  - Proyek Compose: up, restart, stop, down; daftar & hapus image
  - Mendukung Docker Desktop, OrbStack, Rancher, Colima; di server otomatis mencoba `sudo -n` bila user belum di grup `docker`
  - Tampilan gaya OrbStack: sidebar Container · Volume · Image · Network, proyek Compose yang bisa dilipat, tombol yang muncul saat disorot
  - Panel detail container: CPU & RAM, port yang bisa dibuka di browser, perintah, restart policy, health, IP & network, mount, environment (tersamar)
  - Daftar & hapus volume, daftar network
- **🪟 Split & broadcast terminal**
  - Bagi layar jadi 2–4 terminal berdampingan (2 kolom, 3 kolom, 2×2): duplikat tab (⌘D / Ctrl+Shift+D), gabung tab yang sudah terbuka, atau buka host baru
  - **Broadcast** (⇧⌘B / Ctrl+Shift+B): ketik sekali, dikirim ke semua panel split — panel bertanda oranye
  - Klik panel untuk memfokuskannya; keluarkan panel dari split tanpa menutup tab

## [0.4.0] — 2026-11-20

Tiga fitur besar: server lokal ala MAMP, berbagi host ke tim, dan edit file langsung di server. 🎬 [Video pengenalan](https://masadjie.github.io/djie-shell/#video)

### Baru
- **🧱 Server Lokal** — jalankan web server & database di komputer sendiri, seperti MAMP / XAMPP
  - **Apache atau Nginx + PHP 8.4** dengan port & folder proyek yang bisa diatur, tombol *Buka di browser*
  - **MySQL 8.4, PostgreSQL 17, MongoDB 8** — Start/Stop per database, tombol *Buka di Database*
  - Komponen diunduh otomatis saat pertama dipakai, lengkap dengan progress & tombol batal; Apache bawaan macOS dipakai langsung
  - Hanya mendengarkan di `127.0.0.1`; semua layanan berhenti saat app ditutup, proses sisa dibersihkan saat app dibuka lagi
  - Windows: tombol pasang Microsoft Visual C++ Runtime bila belum ada
- **👥 Tim** — admin membagikan host ke rekan kerja lewat email
  - Buat tim, pilih host yang dibagikan, undang email langsung dari app (Google mengirim email undangan)
  - Rekan bergabung lewat **Tim → Gabung tim** dan halaman [Gabung tim](https://masadjie.github.io/djie-shell/team.html); host tim muncul di daftar Hosts (read-only) lengkap dengan password & SSH key
  - Terenkripsi end-to-end di Google Drive admin: kunci tim dibungkus per anggota (X25519), isi tim ditandatangani admin (Ed25519)
  - Perubahan host oleh admin otomatis terkirim; anggota dikeluarkan → izin Drive dicabut dan kunci tim diganti
- **📝 SFTP: edit & buka dengan app lain**
  - **Editor bawaan**: klik dua kali file teks di server — nomor baris, cari, simpan ⌘S / Ctrl+S, peringatan bila file diubah orang lain, line ending CRLF/LF dijaga
  - **Buka dengan** VS Code, Sublime, Notepad++, Preview, atau app lain — setiap kali disimpan, file otomatis di-upload ke server

### Diubah
- Login Google kini juga meminta izin `drive.file` (hanya file yang dibuat/dipilih lewat Djie Shell) untuk fitur Tim — pengguna lama cukup klik **Izinkan akses Google Drive** di halaman Tim
- Kebijakan privasi diperbarui untuk izin baru tersebut
- Website: bagian Server Lokal, Tim, editor SFTP, dan pilihan video *Baru di v0.4* / *Tur lengkap*

### Diperbaiki
- Windows: editor SFTP sempat hanya menampilkan baris pertama file

## [0.3.0] — 2026-11-20

### Baru
- **📊 Info server** — klik *Info server* di tab SSH yang aktif (⇧⌘I / Ctrl+Shift+I)
  - Spesifikasi: OS & versi, kernel, CPU (model, arsitektur, jumlah core), uptime, load
  - **Grafik live** CPU, RAM, dan kecepatan jaringan, diperbarui tiap 3 detik
  - Pemakaian RAM, swap, dan tiap partisi storage
  - Server Linux (Ubuntu, Debian, CentOS, Alpine, …) & macOS, lewat SSH — ikut key & proxy host, tanpa install apa pun di server
- Video promo dengan narasi dan caption, plus versi 9:16 untuk Reels / TikTok / Shorts

### Diubah
- Build Windows dikunci ke .NET 9 SDK agar stabil di CI

## [0.2.0] — 2026-11-20

### Baru
- **🪟 Versi Windows** (WinUI 3) dengan semua fitur versi Mac; installer `Setup.exe` per user tanpa hak admin (x64 & ARM64)
- **🌐 Proxy SOCKS5 / HTTP** per host, lengkap dengan login — dipakai terminal, SFTP, port forwarding, dan tunnel database
- **🗄️ Database ala phpMyAdmin**: pohon database & tabel, ringkasan tabel, paging, struktur, tab **Cari** per kolom (`=`, `LIKE %…%`, `IN`, `BETWEEN`, `IS NULL`, …), cari cepat di semua kolom, daftar tabel bisa ditampilkan/disembunyikan
- **⌨️ Terminal lokal**: zsh di Mac, PowerShell / CMD / WSL di Windows (⇧⌘T / Ctrl+Shift+T)
- **Autocomplete** perintah di terminal dari riwayat host, snippet, dan perintah umum
- SSH agent di Windows: OpenSSH agent & Pageant
- Website: download langsung DMG / EXE, bagian database, proxy, dan terminal lokal

### Diperbaiki
- Windows: tampilan buram di layar skala tinggi
- Pesan error yang lebih jelas di macOS

## [0.1.0] — 2026-11-20

Rilis pertama (macOS).

### Baru
- Vault terenkripsi (Argon2id + XChaCha20-Poly1305) dengan master password dan **Touch ID**
- **Hosts** dalam grid atau list, grup, tag, warna kartu, connect banyak host sekaligus
- Terminal SSH (password, SSH key, agent), jump host, agent forwarding, startup snippet, env var, 7 tema terminal
- **SFTP** dua panel dengan drag & drop, progress, chmod
- **Keychain** SSH key (buat Ed25519 / impor), **Port forwarding** local/remote/SOCKS, **Snippets**, **Known Hosts**, **Logs**
- Klien database (MySQL, PostgreSQL, SQL Server, SQLite, Redis, MongoDB, ClickHouse, …)
- **Sync Google Drive** (folder tersembunyi `drive.appdata`), halaman Akun, mode gelap & terang
- Website dengan kebijakan privasi & ketentuan

[Unreleased]: https://github.com/masadjie/djie-shell/compare/v0.5.1...main
[0.5.1]: https://github.com/masadjie/djie-shell/releases/tag/v0.5.1
[0.5.0]: https://github.com/masadjie/djie-shell/releases/tag/v0.5.0
[0.4.0]: https://github.com/masadjie/djie-shell/releases/tag/v0.4.0
[0.3.0]: https://github.com/masadjie/djie-shell/releases/tag/v0.3.0
[0.2.0]: https://github.com/masadjie/djie-shell/releases/tag/v0.2.0
[0.1.0]: https://github.com/masadjie/djie-shell/tree/v0.1.0
