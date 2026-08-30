<div align="center">

<img src="https://www.bimxyz.id/logo.png" alt="Bimxyz Official Logo" width="160">

# Auto Backup Node Pterodactyl

**Backup & Restore Otomatis untuk Node Pterodactyl ke Google Drive — Hemat Resource, Aman untuk Server Produksi**

[![Website](https://img.shields.io/badge/Website-bimxyz.id-3b82f6?style=for-the-badge)](https://www.bimxyz.id)
[![WhatsApp](https://img.shields.io/badge/WhatsApp-Chat-25D366?style=for-the-badge&logo=whatsapp&logoColor=white)](https://wa.me/6285707645737)
[![Telegram](https://img.shields.io/badge/Telegram-@bimxyzofficial-0088cc?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/bimxyzofficial)

</div>

---

## Tentang Proyek

**Auto Backup Node Pterodactyl** adalah skrip Bash untuk melakukan backup otomatis seluruh isi `/var/lib/pterodactyl/volumes` di sebuah node Pterodactyl ke Google Drive, lengkap dengan fitur restore, penjadwalan (cron), dan manajemen resource server. Dibuat untuk kebutuhan operasional **Bimxyz Official** dalam menjaga data server pelanggan tetap aman tanpa mengganggu performa node yang sedang melayani banyak server sekaligus.

Skrip ini dirancang agar **ringan** — proses backup dibatasi maksimum **0.5 vCPU dan 300MB RAM** memakai cgroup (`systemd-run`), sehingga node tetap responsif untuk melayani server-server yang sedang berjalan di atasnya, meskipun proses backup/restore/kompresi sedang aktif di background.

## Fitur

- 🚀 **Backup manual & otomatis** — jalankan kapan saja, atau jadwalkan lewat cron (per jam maupun per hari)
- 📥 **Restore satu klik** — pilih backup dari daftar yang tersedia di Google Drive, sistem otomatis mem-verifikasi integritas arsip sebelum menimpa data
- ☁️ **Integrasi Google Drive via rclone** — autentikasi menggunakan Service Account (aman untuk multi-server, tidak perlu login interaktif berulang)
- 🧹 **Retensi otomatis** — backup lama di Google Drive langsung dihapus setelah backup baru berhasil diunggah, jadi kuota Drive tidak membengkak; backup lokal disimpan sebagai cadangan selama 3 hari
- 🐢 **Pembatasan resource (CPU & RAM)** — seluruh proses backup dijalankan di dalam cgroup yang dibatasi ketat, tidak mengganggu server game/bot yang sedang online
- 💾 **Manajemen Swap & Kernel** — tambah, ubah ukuran, atau hapus swap file, plus optimasi `vm.swappiness` dan `vm.vfs_cache_pressure` untuk node dengan RAM terbatas
- 📊 **Dashboard status sistem** — cek koneksi Google Drive, penggunaan disk, status swap, status Wings, dan jadwal cron dalam satu tampilan
- 🔁 **Auto-retry & self-healing** — otomatis mencoba ulang saat upload/download gagal, dan memperbaiki konfigurasi rclone yang rusak tanpa perlu setup ulang manual
- 🛡️ **Aman untuk Wings** — layanan Wings dihentikan sementara saat backup/restore berjalan (jika sedang aktif) dan dijalankan kembali otomatis setelah selesai

## Kebutuhan Sistem

- VPS/dedicated server berbasis **Ubuntu/Debian** dengan akses root
- **systemd** terpasang (untuk pembatasan resource via cgroup; skrip tetap berjalan tanpanya lewat mode fallback, namun batas RAM jadi kurang presisi)
- Node **Pterodactyl (Wings)** dengan direktori volume di `/var/lib/pterodactyl/volumes`
- Akun Google Drive + **Service Account JSON** (panduan pembuatan ada di dalam skrip saat instalasi)

## Instalasi

Jalankan perintah berikut sebagai root di VPS/node Pterodactyl Anda:

```bash
bash <(curl -sL https://raw.githubusercontent.com/bimxyzdev/auto-backup-node-vps/main/install.sh)
```

Installer akan menampilkan menu:

```
1. Install / Update Bimxyz Auto-Backup
2. Uninstall (Hapus Bersih ke Akar)
3. Batal / Keluar
```

Pilih **1**, tunggu proses unduh selesai, dan panel utama (`bimxyz`) akan otomatis terbuka. Setelah instalasi selesai, Anda bisa menjalankan panel kapan saja cukup dengan mengetik:

```bash
bimxyz
```

## Cara Penggunaan

### 1. Konfigurasi Awal
Saat pertama kali dijalankan, skrip akan meminta:
- **Service Account JSON** dari Google Cloud Console (folder Google Drive tujuan backup harus dibagikan ke email service account tersebut)
- **Nama node** server (contoh: `SG-Node-01`) — dipakai sebagai penanda pada nama file backup

### 2. Menu Utama

| Opsi | Fungsi |
|---|---|
| 1. Jalankan Backup Sekarang | Backup langsung, berjalan di background (tahan SIGHUP) |
| 2. Pulihkan Backup (Restore) | Pilih file backup dari Google Drive untuk dipulihkan |
| 3. Atur Jadwal Backup Otomatis | Jadwalkan via cron — interval per jam atau per hari |
| 4. Atur / Ubah Nama Node Server | Ubah label node yang dipakai di nama file backup |
| 5. Lihat Status Sistem | Dashboard kondisi Drive, disk, swap, Wings, dan cron |
| 6. Reset Autentikasi Google Drive | Hapus konfigurasi rclone & Service Account, setup ulang |
| 7. Manajemen Swap & Kernel | Tambah/ubah/hapus swap, optimasi parameter kernel |
| 8. Keluar | Menutup panel |

### 3. Menjadwalkan Backup Otomatis

Dari menu **3**, pilih salah satu mode:
- **Per jam** — misalnya backup tiap 6 jam, cocok untuk data yang sering berubah
- **Per hari** — backup sekali (atau tiap beberapa hari) pada jam tertentu (WIB), skrip otomatis mengonversi ke zona waktu server

### 4. Restore Backup

Dari menu **2**, skrip menampilkan daftar backup yang tersedia di Google Drive beserta ukurannya. Setelah memilih, Anda diminta mengetik `RESTORE` untuk konfirmasi — data lama akan dipindahkan ke folder snapshot (`/root/volumes_snapshot_*`) sebelum ditimpa, sehingga tetap ada jalan mundur jika terjadi kesalahan. Dua snapshot terbaru disimpan otomatis, sisanya dibersihkan.

### Mode CLI (non-interaktif)

Skrip juga mendukung argumen langsung, berguna untuk debugging atau dipanggil dari sistem lain:

```bash
bash bimxyz-main.sh --auto-backup           # Dipakai otomatis oleh cron
bash bimxyz-main.sh --run-worker-backup     # Jalankan proses backup langsung (tanpa menu)
bash bimxyz-main.sh --run-worker-restore <nama_file.tar.gz>   # Restore langsung dari nama file
```

## Uninstall

Jalankan ulang installer dan pilih opsi **2**:

```bash
bash <(curl -sL https://raw.githubusercontent.com/bimxyzdev/auto-backup-node-vps/main/install.sh)
```

Uninstaller akan menghentikan proses yang berjalan, menghapus konfigurasi, jadwal cron, binary `bimxyz`, dan `rclone`. Swap file (`/swapfile`) **tidak dihapus otomatis** jika pernah dibuat — hapus manual dengan `swapoff /swapfile && rm -f /swapfile` bila diperlukan.

## Struktur File

| Path | Keterangan |
|---|---|
| `/usr/local/bin/bimxyz` | Skrip utama setelah terinstal |
| `/root/.bimxyz/` | Konfigurasi (Service Account JSON, nama node) |
| `/root/bimxyz_backup/` | Penyimpanan backup lokal (retensi 3 hari) |
| `/var/log/bimxyz_backup.log` | Log seluruh proses backup/restore |
| `/root/volumes_snapshot_*` | Snapshot data lama sebelum proses restore |

## FAQ

**Apakah proses backup akan mengganggu server yang sedang online di node?**
Tidak. Proses kompresi dan upload dibatasi maksimum 0.5 vCPU dan 300MB RAM menggunakan cgroup, sehingga server-server Pterodactyl lain di node yang sama tetap mendapat jatah resource yang cukup.

**Apakah Wings perlu dimatikan manual sebelum backup?**
Tidak perlu. Skrip otomatis menghentikan Wings sementara (jika sedang berjalan) sebelum proses backup/restore, dan menjalankannya kembali setelah selesai.

**Berapa lama backup disimpan?**
Di Google Drive, hanya backup **terbaru** per node yang disimpan (backup lama otomatis dihapus setelah upload baru berhasil). Secara lokal, backup disimpan selama 3 hari sebagai cadangan darurat.

**Bagaimana jika koneksi ke Google Drive terputus saat upload?**
Skrip otomatis mencoba ulang hingga 3 kali dengan jeda 15 detik. Jika tetap gagal, backup lokal tetap tersimpan dan tercatat di log.

## Link Resmi

- 🌐 Website: [bimxyz.id](https://www.bimxyz.id)
- 📦 Repository: [github.com/bimxyzdev/auto-backup-node-vps](https://github.com/bimxyzdev/auto-backup-node-vps)
- 📞 Kontak: WhatsApp [+62 857-0764-5737](https://wa.me/6285707645737) · Telegram [@bimxyzofficial](https://t.me/bimxyzofficial) · Email bimxyzofficial@gmail.com

---

<div align="center">
<sub>Dikembangkan oleh Bimxyz Official — Penyedia Panel Pterodactyl & Layanan Digital Terpercaya di Indonesia 🇮🇩</sub>
</div>
