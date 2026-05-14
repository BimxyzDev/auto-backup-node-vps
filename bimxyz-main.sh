#!/bin/bash
# ╔═══════════════════════════════════════════════════════╗
# ║     BIMXYZ ULTIMATE BACKUP SYSTEM V1.0               ║
# ║     Production Grade | Multi-Server | Auto-Retry      ║
# ╚═══════════════════════════════════════════════════════╝

set -euo pipefail

# ─── CONSTANTS ───────────────────────────────────────────
readonly VERSION="4.0"
readonly REMOTE_NAME="gdrive_bimxyz"
readonly GDRIVE_FOLDER="Backup_Bimxyz"
readonly PTERO_PATH="/var/lib/pterodactyl/volumes"
readonly CONFIG_DIR="/root/.bimxyz"
readonly TEMP_DIR="/root/.bimxyz_temp"
readonly NODE_CONFIG="$CONFIG_DIR/node.conf"
readonly LOG_FILE="/var/log/bimxyz_backup.log"
readonly MAX_RETRIES=3
readonly RETENTION_DAYS=7

# ─── WARNA ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

# ─── LOGGING ─────────────────────────────────────────────
log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    case "$level" in
        INFO)  echo -e "${GREEN}[✓] $msg${NC}" ;;
        WARN)  echo -e "${YELLOW}[!] $msg${NC}" ;;
        ERROR) echo -e "${RED}[✗] $msg${NC}" ;;
        STEP)  echo -e "${CYAN}[»] $msg${NC}" ;;
    esac
}

# ─── CLEANUP ─────────────────────────────────────────────
cleanup() {
    local code=$?
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    [ $code -ne 0 ] && log ERROR "Terminated (exit $code) — cek: $LOG_FILE"
}
trap cleanup EXIT
trap 'log ERROR "Interrupted!"; exit 130' INT TERM

# ─── ROOT CHECK ──────────────────────────────────────────
check_root() {
    [ "$EUID" -eq 0 ] && return
    echo -e "${RED}[✗] Harus root. Jalankan: sudo bash $0${NC}"
    exit 1
}

# ─── DEPENDENCIES ────────────────────────────────────────
install_deps() {
    local missing=()
    command -v rclone  &>/dev/null || missing+=("rclone")
    command -v curl    &>/dev/null || missing+=("curl")
    command -v python3 &>/dev/null || missing+=("python3")
    command -v bc      &>/dev/null || missing+=("bc")

    [ ${#missing[@]} -eq 0 ] && return 0

    log STEP "Installing: ${missing[*]}"
    for dep in "${missing[@]}"; do
        if [ "$dep" == "rclone" ]; then
            curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 \
                || { log ERROR "Gagal install rclone"; exit 1; }
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$dep" >/dev/null 2>&1 \
                || { log ERROR "Gagal install $dep"; exit 1; }
        fi
    done
    log INFO "Semua dependency OK"
}

# ─── GDRIVE SETUP ────────────────────────────────────────
gdrive_is_alive() {
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$" \
        && rclone lsd "$REMOTE_NAME:" &>/dev/null
}

setup_gdrive() {
    if gdrive_is_alive; then
        log INFO "GDrive terhubung ✓"
        return 0
    fi

    # Hapus remote rusak
    rclone config delete "$REMOTE_NAME" 2>/dev/null || true

    echo -e "\n${CYAN}${BOLD}═══════ SETUP GOOGLE DRIVE ═══════${NC}"
    echo -e "  ${BOLD}1.${NC} Service Account JSON ${GREEN}[RECOMMENDED - untuk deploy massal]${NC}"
    echo -e "  ${BOLD}2.${NC} OAuth Token ${YELLOW}[untuk 1 server / testing]${NC}"
    echo ""
    read -rp "Pilihan (1/2): " AUTH

    case "$AUTH" in
        1) setup_service_account ;;
        2) setup_oauth ;;
        *) log ERROR "Pilihan tidak valid"; exit 1 ;;
    esac
}

setup_service_account() {
    echo -e "\n${CYAN}PANDUAN SERVICE ACCOUNT:${NC}"
    echo -e "  1. Buka ${YELLOW}https://console.cloud.google.com/${NC}"
    echo -e "  2. IAM & Admin → Service Accounts → Create"
    echo -e "  3. Keys → Add Key → JSON → Download"
    echo -e "  4. Share folder GDrive ke email service account"
    echo -e "\n${YELLOW}Paste isi file JSON (lalu CTRL+D):${NC}"

    mkdir -p "$CONFIG_DIR"
    local sa_file="$CONFIG_DIR/service_account.json"
    cat > "$sa_file"

    # Validasi JSON
    python3 -c "import json,sys; json.load(open('$sa_file'))" 2>/dev/null \
        || { log ERROR "JSON tidak valid!"; rm -f "$sa_file"; exit 1; }
    chmod 600 "$sa_file"

    rclone config create "$REMOTE_NAME" drive \
        service_account_file="$sa_file" \
        scope=drive \
        --non-interactive >/dev/null 2>&1

    gdrive_is_alive \
        || { log ERROR "Koneksi gagal — cek permission service account"; exit 1; }
    log INFO "Service Account berhasil"
}

setup_oauth() {
    echo -e "\n${CYAN}Jalankan ini di PC yang ada browser-nya:${NC}"
    echo -e "  ${YELLOW}rclone authorize \"drive\"${NC}"
    echo -e "\nPaste token JSON di sini:"
    read -rp "> " TOKEN_JSON

    rclone config create "$REMOTE_NAME" drive \
        token="$TOKEN_JSON" \
        scope=drive \
        --non-interactive >/dev/null 2>&1

    gdrive_is_alive \
        || { log ERROR "Token tidak valid"; exit 1; }
    log INFO "OAuth berhasil"
}

# ─── NODE NAME ───────────────────────────────────────────
get_node_name() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$NODE_CONFIG" ]; then
        read -rp "Nama Node (contoh: SG-Node-01): " input
        local sanitized
        sanitized=$(echo "$input" | tr -cd '[:alnum:]_-')
        [ -z "$sanitized" ] && { log ERROR "Nama tidak valid"; exit 1; }
        echo "$sanitized" > "$NODE_CONFIG"
    fi
    cat "$NODE_CONFIG"
}

# ─── DISK SPACE CHECK ────────────────────────────────────
check_disk_space() {
    local src="$1"
    local src_mb; src_mb=$(du -sm "$src" 2>/dev/null | awk '{print $1}')
    local free_mb; free_mb=$(df -m "$TEMP_DIR" | awk 'NR==2{print $4}')
    local need_mb=$(( src_mb + 512 ))

    log STEP "Source: ${src_mb}MB | Free: ${free_mb}MB | Required: ${need_mb}MB"
    [ "$free_mb" -ge "$need_mb" ] && return 0

    log ERROR "Disk tidak cukup! Free=${free_mb}MB, Butuh=${need_mb}MB"
    exit 1
}

# ─── RCLONE WITH RETRY ───────────────────────────────────
rclone_retry() {
    local op="$1"; shift
    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        rclone "$op" "$@" \
            --progress \
            --transfers=4 \
            --checkers=8 \
            --retries=5 \
            --low-level-retries=10 \
            --stats=30s \
            && return 0
        log WARN "Attempt $attempt/$MAX_RETRIES gagal — retry 15s..."
        sleep 15
        (( attempt++ ))
    done
    log ERROR "Gagal setelah $MAX_RETRIES attempts"
    return 1
}

# ─── BACKUP ──────────────────────────────────────────────
do_backup() {
    local node; node=$(get_node_name)
    local stamp; stamp=$(date +%Y-%m-%d_%H-%M-%S)
    local fname="${node}_${stamp}.tar.gz"
    local tmpf="$TEMP_DIR/$fname"

    echo -e "\n${CYAN}${BOLD}═══════ BACKUP MODE ═══════${NC}"
    log STEP "Node: $node | Target: $fname"

    [ -d "$PTERO_PATH" ] || { log ERROR "Path tidak ada: $PTERO_PATH"; exit 1; }

    mkdir -p "$TEMP_DIR"
    check_disk_space "$PTERO_PATH"

    # Compress
    log STEP "Mengkompress volumes..."
    local t0=$SECONDS
    tar -czf "$tmpf" \
        --checkpoint=500 \
        --checkpoint-action=dot \
        -C /var/lib/pterodactyl volumes 2>/dev/null
    echo ""
    local elapsed=$(( SECONDS - t0 ))
    local fsize; fsize=$(du -sh "$tmpf" | awk '{print $1}')
    log INFO "Kompresi selesai: ${fsize} dalam ${elapsed}s"

    # Upload
    log STEP "Upload ke Google Drive..."
    rclone_retry copy "$tmpf" "$REMOTE_NAME:$GDRIVE_FOLDER" \
        || { log ERROR "Upload gagal!"; exit 1; }

    rm -f "$tmpf"

    # Retention cleanup
    log STEP "Hapus backup >${RETENTION_DAYS} hari..."
    rclone delete "$REMOTE_NAME:$GDRIVE_FOLDER" \
        --min-age "${RETENTION_DAYS}d" \
        --include "${node}_*.tar.gz" 2>/dev/null || true

    echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════╗"
    echo -e "║       ✅ BACKUP SUKSES! GACOR!        ║"
    echo -e "╠══════════════════════════════════════╣"
    echo -e "║${NC} Node  : ${BOLD}$node${NC}"
    echo -e "${GREEN}${BOLD}║${NC} File  : ${BOLD}$fname${NC}"
    echo -e "${GREEN}${BOLD}║${NC} Size  : ${BOLD}$fsize${NC}"
    echo -e "${GREEN}${BOLD}║${NC} Drive : ${BOLD}$GDRIVE_FOLDER/${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"

    log INFO "BACKUP COMPLETE: $fname ($fsize)"
}

# ─── RESTORE ─────────────────────────────────────────────
do_restore() {
    echo -e "\n${CYAN}${BOLD}═══════ RESTORE MODE ═══════${NC}"
    log STEP "Mengambil daftar backup dari GDrive..."

    local list
    list=$(rclone lsf "$REMOTE_NAME:$GDRIVE_FOLDER" --include "*.tar.gz" 2>/dev/null | sort -r)
    [ -z "$list" ] && { log ERROR "Tidak ada backup di GDrive!"; exit 1; }

    echo -e "\n${YELLOW}${BOLD}Daftar Backup:${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────${NC}"

    local -a files
    local i=1
    while IFS= read -r f; do
        files+=("$f")
        local sz
        sz=$(rclone size "$REMOTE_NAME:$GDRIVE_FOLDER/$f" --json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); mb=d['bytes']//1024//1024; print(f'{mb}MB')" 2>/dev/null || echo "?")
        echo -e "  ${BOLD}[$i]${NC} $f ${YELLOW}($sz)${NC}"
        (( i++ ))
    done <<< "$list"

    echo -e "${CYAN}──────────────────────────────────────────────${NC}"
    echo ""
    read -rp "Pilih nomor (1-${#files[@]}): " num

    [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#files[@]}" ] \
        || { log ERROR "Nomor tidak valid!"; exit 1; }

    local rfile="${files[$((num-1))]}"

    # Konfirmasi destruktif
    echo -e "\n${RED}${BOLD}⚠️  PERINGATAN: OPERASI INI TIDAK BISA DIBATALKAN! ⚠️${NC}"
    echo -e "${RED}  • Semua isi $PTERO_PATH akan dihapus${NC}"
    echo -e "${YELLOW}  • File   : $rfile${NC}"
    echo -e "${YELLOW}  • Backup lama akan dipindah ke /root/volumes_snapshot_*${NC}"
    echo ""
    read -rp "Ketik ${BOLD}RESTORE${NC} untuk lanjut: " confirm
    [ "$confirm" == "RESTORE" ] || { log WARN "Dibatalkan"; exit 0; }

    mkdir -p "$TEMP_DIR"
    local local_file="$TEMP_DIR/$rfile"

    # Download
    log STEP "Mendownload: $rfile"
    rclone_retry copy "$REMOTE_NAME:$GDRIVE_FOLDER/$rfile" "$TEMP_DIR/" \
        || { log ERROR "Download gagal!"; exit 1; }

    # Integrity check
    log STEP "Verifikasi integritas archive..."
    tar -tzf "$local_file" >/dev/null 2>&1 \
        || { log ERROR "File corrupt!"; rm -f "$local_file"; exit 1; }
    log INFO "Archive OK"

    # Stop wings
    local wings_up=false
    if systemctl is-active --quiet wings 2>/dev/null; then
        log STEP "Menghentikan Wings..."
        systemctl stop wings && wings_up=true
    fi

    # Snapshot data lama
    local snap="/root/volumes_snapshot_$(date +%H%M%S)"
    if [ -d "$PTERO_PATH" ] && [ "$(ls -A "$PTERO_PATH" 2>/dev/null)" ]; then
        log STEP "Snapshot lama → $snap"
        mv "$PTERO_PATH" "$snap" 2>/dev/null || true
    fi
    mkdir -p "$PTERO_PATH"

    # Extract
    log STEP "Mengekstrak backup..."
    tar -xzf "$local_file" \
        --checkpoint=500 \
        --checkpoint-action=dot \
        -C /var/lib/pterodactyl 2>/dev/null
    echo ""
    log INFO "Ekstraksi selesai"

    # Fix permissions
    log STEP "Fix permissions..."
    local ptero_uid
    ptero_uid=$(id -u pterodactyl 2>/dev/null || echo "988")
    chown -R "${ptero_uid}:${ptero_uid}" "$PTERO_PATH" 2>/dev/null || true
    chmod -R 755 "$PTERO_PATH" 2>/dev/null || true

    # Restart wings
    if $wings_up; then
        log STEP "Menghidupkan Wings..."
        systemctl start wings && sleep 3
        systemctl is-active --quiet wings \
            && log INFO "Wings RUNNING ✓" \
            || log WARN "Wings gagal start — cek: systemctl status wings"
    fi

    rm -f "$local_file"

    echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════╗"
    echo -e "║      ✅ RESTORE SUKSES! MANTAP!       ║"
    echo -e "╠══════════════════════════════════════╣"
    echo -e "║${NC} File     : ${BOLD}$rfile${NC}"
    echo -e "${GREEN}${BOLD}║${NC} Snapshot : ${BOLD}$snap${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"

    log INFO "RESTORE COMPLETE: $rfile"
}

# ─── CRON SCHEDULER ──────────────────────────────────────
setup_cron() {
    echo -e "\n${CYAN}${BOLD}═══════ AUTO BACKUP SCHEDULER ═══════${NC}"
    echo -e "  ${BOLD}1.${NC} Setiap 6 jam"
    echo -e "  ${BOLD}2.${NC} Setiap 12 jam"
    echo -e "  ${BOLD}3.${NC} Setiap hari jam 02:00"
    echo -e "  ${BOLD}4.${NC} Setiap hari jam 00:00 & 12:00"
    echo -e "  ${BOLD}5.${NC} Custom cron expression"
    echo -e "  ${BOLD}6.${NC} ❌ Hapus jadwal"
    echo ""
    read -rp "Pilihan (1-6): " choice

      
    local script_path="/usr/local/bin/bimxyz"
    local cron_cmd="bash $script_path --auto-backup >> $LOG_FILE 2>&1"

    # Hapus entry lama dulu
    crontab -l 2>/dev/null | grep -v "$script_path" | crontab - 2>/dev/null || true


    [ "$choice" == "6" ] && { log INFO "Jadwal dihapus"; return 0; }

    local expr
    case "$choice" in
        1) expr="0 */6 * * *" ;;
        2) expr="0 */12 * * *" ;;
        3) expr="0 2 * * *" ;;
        4) expr="0 0,12 * * *" ;;
        5) read -rp "Cron expression: " expr ;;
        *) log ERROR "Tidak valid"; return 1 ;;
    esac

    ( crontab -l 2>/dev/null; echo "$expr $cron_cmd" ) | crontab -
    log INFO "Cron aktif: [$expr]"
    echo -e "${GREEN}Verifikasi: ${YELLOW}crontab -l${NC}"
}

# ─── STATUS DASHBOARD ────────────────────────────────────
show_status() {
    echo -e "\n${CYAN}${BOLD}═══════ SYSTEM STATUS ═══════${NC}"

    local node="(belum diset)"
    [ -f "$NODE_CONFIG" ] && node=$(cat "$NODE_CONFIG")
    echo -e "  Node       : ${BOLD}$node${NC}"

    if gdrive_is_alive 2>/dev/null; then
        local count; count=$(rclone lsf "$REMOTE_NAME:$GDRIVE_FOLDER" --include "*.tar.gz" 2>/dev/null | wc -l)
        echo -e "  GDrive     : ${GREEN}${BOLD}CONNECTED ✓${NC} ($count backups)"
    else
        echo -e "  GDrive     : ${RED}${BOLD}DISCONNECTED ✗${NC}"
    fi

    local disk; disk=$(df -h "$PTERO_PATH" 2>/dev/null | awk 'NR==2{printf "%s used / %s total (%s)", $3,$2,$5}')
    echo -e "  Disk       : ${BOLD}$disk${NC}"

    if systemctl is-active --quiet wings 2>/dev/null; then
        echo -e "  Wings      : ${GREEN}${BOLD}RUNNING ✓${NC}"
    else
        echo -e "  Wings      : ${RED}${BOLD}STOPPED${NC}"
    fi

    local cron_entry; cron_entry=$(crontab -l 2>/dev/null | grep "/usr/local/bin/bimxyz" || echo "")
    
    if [ -n "$cron_entry" ]; then
        echo -e "  Auto-Backup: ${GREEN}${BOLD}AKTIF${NC} → $cron_entry"
    else
        echo -e "  Auto-Backup: ${YELLOW}${BOLD}TIDAK AKTIF${NC}"
    fi

    local last; last=$(grep "BACKUP COMPLETE\|RESTORE COMPLETE" "$LOG_FILE" 2>/dev/null | tail -1 || echo "")
    [ -n "$last" ] && echo -e "  Last Op    : ${BOLD}$(echo "$last" | cut -d' ' -f1-3)${NC} — $(echo "$last" | cut -d']' -f3-)"
}

# ─── BANNER ──────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo -e "╔═════════════════════════════════════════════════╗"
    echo -e "║    👑 BIMXYZ ULTIMATE BACKUP SYSTEM V${VERSION}    ║"
    echo -e "║       Production Grade | Multi-Server Deploy     ║"
    echo -e "╚═════════════════════════════════════════════════╝${NC}"
    echo -e "  ${YELLOW}Log: $LOG_FILE${NC}\n"
}

# ─── MENU ────────────────────────────────────────────────
show_menu() {
    echo -e "\n${CYAN}${BOLD}MENU UTAMA:${NC}"
    echo -e "  ${BOLD}1.${NC} 🚀 Backup Sekarang"
    echo -e "  ${BOLD}2.${NC} 📥 Restore Backup"
    echo -e "  ${BOLD}3.${NC} ⏰ Setup Auto Backup"
    echo -e "  ${BOLD}4.${NC} 📊 Lihat Status"
    echo -e "  ${BOLD}5.${NC} 🔄 Reset GDrive Auth"
    echo -e "  ${BOLD}6.${NC} 🚪 Keluar"
    echo ""
    read -rp "Pilihan (1-6): " choice

    case "$choice" in
        1) do_backup ;;
        2) do_restore ;;
        3) setup_cron ;;
        4) show_status ;;
        5)
            rclone config delete "$REMOTE_NAME" 2>/dev/null || true
            rm -f "$CONFIG_DIR/service_account.json"
            log INFO "Auth direset. Jalankan ulang."
            ;;
        6) exit 0 ;;
        *) log ERROR "Pilihan tidak valid" ;;
    esac
}

# ─── ENTRY POINT ─────────────────────────────────────────
main() {
    check_root
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"

    # Mode otomatis dari cron — langsung backup, no menu
    if [ "${1:-}" == "--auto-backup" ]; then
        log INFO "=== CRON AUTO-BACKUP TRIGGERED ==="
        install_deps
        setup_gdrive
        do_backup
        exit 0
    fi

    show_banner
    show_status
    install_deps
    setup_gdrive
    show_menu
}

main "$@"