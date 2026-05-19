#!/bin/bash
# =====================================================
# BIMXYZ BOOTSTRAP INSTALLER & UNINSTALLER
# Production Grade Auto-Deployment
# =====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${CYAN}====================================================="
echo -e "       BIMXYZ ULTIMATE SYSTEM DEPLOYMENT        "
echo -e "=====================================================${NC}"
echo ""

# Memeriksa Hak Akses Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[✗] Akses ditolak. Harap jalankan installer ini menggunakan akses root (sudo su).${NC}"
  exit 1
fi

echo -e "${YELLOW}Pilih aksi yang ingin dieksekusi:${NC}"
echo -e "  ${CYAN}1.${NC} 🚀 Install / Update Bimxyz Auto-Backup"
echo -e "  ${CYAN}2.${NC} 🗑️  Uninstall (Hapus Bersih ke Akar)"
echo -e "  ${CYAN}3.${NC} 🚪 Batal / Keluar"
echo ""
read -rp "Masukkan pilihan (1/2/3): " choice

case "$choice" in
    1)
        echo -e "\n${CYAN}====================================================="
        echo -e "         INSTALLING BIMXYZ ULTIMATE SYSTEM         "
        echo -e "=====================================================${NC}"
        echo -e "${YELLOW}[*] Mengunduh komponen utama sistem Bimxyz...${NC}"

        # URL RAW GITHUB FILE "bimxyz-main.sh"
        MAIN_SCRIPT_URL="https://raw.githubusercontent.com/BimxyzDev/auto-backup-node-vps/refs/heads/main/bimxyz-main.sh"

        # Proses Unduh dan Instalasi ke Direktori Sistem
        curl -sL "$MAIN_SCRIPT_URL" -o /usr/local/bin/bimxyz

        # Verifikasi Hasil Unduhan
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[+] Unduhan sistem utama berhasil.${NC}"
            echo -e "${YELLOW}[*] Mengonfigurasi hak akses eksekusi (permissions)...${NC}"
            
            # Memberikan akses executable
            chmod +x /usr/local/bin/bimxyz
            
            echo -e "${GREEN}✅ Instalasi permanen telah selesai!${NC}"
            echo -e "${CYAN}[i] Untuk menjalankan panel Bimxyz di masa mendatang, cukup ketik perintah berikut:${NC}"
            echo -e "    ${YELLOW}bimxyz${NC}\n"
            
            echo -e "${YELLOW}[*] Membuka antarmuka sistem dalam 2 detik...${NC}"
            sleep 2
            
            # Menjalankan aplikasi utama
            bimxyz
        else
            echo -e "${RED}[✗] Kesalahan Fatal: Gagal mengunduh file sistem utama.${NC}"
            echo -e "${RED}[!] Silakan periksa koneksi internet atau verifikasi URL repository Anda.${NC}"
            exit 1
        fi
        ;;
        
    2)
        echo -e "\n${CYAN}====================================================="
        echo -e "         UNINSTALLING BIMXYZ ULTIMATE SYSTEM       "
        echo -e "=====================================================${NC}"
        
        echo -e "${YELLOW}[*] Menghentikan semua proses background yang berjalan...${NC}"
        pkill -f "_backup_worker" 2>/dev/null || true
        pkill -f "_restore_worker" 2>/dev/null || true
        pkill -f "bimxyz" 2>/dev/null || true
        sleep 1

        echo -e "${YELLOW}[*] Menghapus file konfigurasi, folder sementara, dan log...${NC}"
        rm -rf /root/.bimxyz /root/.bimxyz_temp
        rm -f /var/log/bimxyz_backup.log
        rm -f /usr/local/bin/bimxyz

        echo -e "${YELLOW}[*] Menghapus jadwal Auto-Backup dari Cron...${NC}"
        crontab -l 2>/dev/null | grep -v "bimxyz" | crontab - 2>/dev/null || true

        echo -e "${YELLOW}[*] Menghapus tools dependensi (bc & rclone)...${NC}"
        # Hapus bc via apt, error di-ignore jika paket tidak ada
        DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y bc >/dev/null 2>&1 || true
        # Hapus rclone binary
        rm -f /usr/bin/rclone /usr/local/bin/rclone /usr/share/man/man1/rclone.1 /usr/local/share/man/man1/rclone.1

        echo -e "${GREEN}✅ Uninstalasi berhasil! Server telah bersih dari Bimxyz Auto-Backup beserta tools-nya.${NC}\n"
        ;;
        
    3)
        echo -e "${YELLOW}[*] Operasi dibatalkan.${NC}"
        exit 0
        ;;
        
    *)
        echo -e "${RED}[✗] Pilihan tidak valid. Silakan jalankan ulang script.${NC}"
        exit 1
        ;;
esac
