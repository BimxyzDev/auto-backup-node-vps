# 👑 BIMXYZ ULTIMATE BACKUP SYSTEM V4.1
### *Production Grade | Multi-Server | Auto-Pilot*

![Status](https://img.shields.io/badge/Status-Stable-green) ![Version](https://img.shields.io/badge/Version-4.1-blue) ![Optimized](https://img.shields.io/badge/Optimization-AMD_vCPU-orange)

**Bimxyz Ultimate Backup System** adalah solusi otomasi backup *enterprise* yang dirancang khusus untuk infrastruktur Pterodactyl Panel. Dibuat untuk menangani beban kerja tinggi (Multi-Node) dengan fokus pada integritas data dan efisiensi resource server.

## 🚀 Fitur Unggulan (V4.1)
* **Smart Compression:** Menggunakan `nice` dan `ionice` untuk mencegah CPU spikes, serta mendukung `pigz` untuk kompresi paralel yang super cepat.
* **Folder-ID Detection:** Teknologi radar yang mampu mendeteksi folder Google Drive bahkan di menu "Shared with me" (Bypass Error Exit 3).
* **Auto-Repair Config:** Pemulihan konfigurasi Rclone secara otomatis jika file `rclone.conf` hilang atau rusak.
* **Wings Safety Protocol:** Otomatis mematikan `wings` saat proses backup untuk menjamin konsistensi data dan menghidupkannya kembali setelah selesai.
* **Multi-Server Deploy:** Dirancang untuk berjalan di berbagai Node (seperti Node AMD 16GB) dengan manajemen nama node yang unik.

## 🛠️ Persyaratan Sistem
* **OS:** Ubuntu/Debian (Recommended).
* **Resource:** Minimal 2GB RAM (Optimized for 16GB+ Nodes).
* **Akses:** Root User.
* **Cloud:** Akun Google Cloud Console (Google Drive API Enabled).

## 📦 Cara Instalasi
Cukup jalankan perintah berikut di terminal Node Anda:
```bash
# Clone script dari repository Bimxyz
curl -o /usr/local/bin/bimxyz [https://raw.githubusercontent.com/BIMXYZ-OFFICIAL/main/bimxyz-main.sh](https://raw.githubusercontent.com/BIMXYZ-OFFICIAL/main/bimxyz-main.sh)

# Berikan izin eksekusi
chmod +x /usr/local/bin/bimxyz

# Jalankan dashboard
bimxyz
