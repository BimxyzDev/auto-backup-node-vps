#!/bin/bash
# =====================================================
# BIMXYZ BOOTSTRAP INSTALLER
# Production Grade Auto-Deployment
# =====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${CYAN}====================================================="
echo -e "         INSTALLING BIMXYZ ULTIMATE SYSTEM         "
echo -e "=====================================================${NC}"
echo ""

# Memeriksa Hak Akses Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[✗] Akses ditolak. Harap jalankan installer ini menggunakan akses root (sudo su).${NC}"
  exit 1
fi

echo -e "${YELLOW}[*] Mengunduh komponen utama sistem Bimxyz...${NC}"

# ⚠️ GANTI LINK INI DENGAN LINK RAW GITHUB FILE "bimxyz-main.sh" ANDA:
MAIN_SCRIPT_URL="https://raw.githubusercontent.com/username-lu/repo-lu/main/bimxyz-main.sh"

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

