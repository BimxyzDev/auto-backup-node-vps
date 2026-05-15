#!/bin/bash
# ╔═══════════════════════════════════════════════════════════╗
# ║     BIMXYZ ULTIMATE BACKUP SYSTEM V4.1                   ║
# ║     Production Grade | Multi-Server | Auto-Retry         ║
# ╚═══════════════════════════════════════════════════════════╝

set -uo pipefail

# ─── KONSTANTA ───────────────────────────────────────────────
readonly VERSION="4.1"
readonly REMOTE_NAME="gdrive_bimxyz"
readonly GDRIVE_FOLDER="Backup_Bimxyz"
readonly PTERO_PATH="/var/lib/pterodactyl/volumes"
readonly CONFIG_DIR="/root/.bimxyz"
readonly TEMP_DIR="/root/.bimxyz_temp"
readonly NODE_CONFIG="$CONFIG_DIR/node.conf"
readonly FOLDER_ID_CACHE="$CONFIG_DIR/gdrive_folder_id.cache"
readonly LOG_FILE="/var/log/bimxyz_backup.log"
readonly MAX_RETRIES=3
readonly RETENTION_DAYS=7

# ─── WARNA ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

# ─── LOGGING ─────────────────────────────────────────────────
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

# ─── PEMBERSIHAN ─────────────────────────────────────────────
cleanup() {
    local code=$?
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    [ $code -ne 0 ] && log ERROR "Proses dihentikan (kode: $code) — periksa log: $LOG_FILE"
}
trap cleanup EXIT
trap 'log ERROR "Proses dibatalkan oleh pengguna."; exit 130' INT TERM

# ─── PEMERIKSAAN HAK AKSES ROOT ──────────────────────────────
check_root() {
    [ "$EUID" -eq 0 ] && return
    echo -e "${RED}[✗] Skrip ini harus dijalankan sebagai root. Gunakan: sudo bash $0${NC}"
    exit 1
}

# ─── INSTALASI DEPENDENSI ────────────────────────────────────
install_deps() {
    local missing=()
    command -v rclone  &>/dev/null || missing+=("rclone")
    command -v curl    &>/dev/null || missing+=("curl")
    command -v python3 &>/dev/null || missing+=("python3")
    command -v bc      &>/dev/null || missing+=("bc")

    [ ${#missing[@]} -eq 0 ] && return 0

    log STEP "Menginstal dependensi: ${missing[*]}"
    for dep in "${missing[@]}"; do
        if [ "$dep" == "rclone" ]; then
            curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 \
                || { log ERROR "Gagal menginstal rclone."; exit 1; }
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$dep" >/dev/null 2>&1 \
                || { log ERROR "Gagal menginstal $dep."; exit 1; }
        fi
    done
    log INFO "Semua dependensi berhasil diinstal."
}

# ─── PERBAIKAN OTOMATIS KONFIGURASI RCLONE ───────────────────
auto_repair_rclone_config() {
    local sa_file="$CONFIG_DIR/service_account.json"

    if rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
        return 0
    fi

    [ -f "$sa_file" ] || return 1

    log WARN "Remote '$REMOTE_NAME' tidak ditemukan di konfigurasi rclone — mencoba perbaikan otomatis..."

    if ! python3 -c "import json,sys; json.load(open('$sa_file'))" 2>/dev/null; then
        log ERROR "File service_account.json tidak valid — perbaikan otomatis dibatalkan."
        return 1
    fi

    rclone config create "$REMOTE_NAME" drive \
        service_account_file="$sa_file" \
        scope=drive \
        --non-interactive >/dev/null 2>&1 || {
        log ERROR "Perbaikan otomatis gagal membuat remote."
        return 1
    }

    log INFO "Perbaikan otomatis konfigurasi rclone berhasil."
    return 0
}

# ─── PENCARIAN FOLDER ID GOOGLE DRIVE ────────────────────────
resolve_gdrive_folder_id() {
    if [ -f "$FOLDER_ID_CACHE" ]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c %Y "$FOLDER_ID_CACHE" 2>/dev/null || echo 0) ))
        if [ "$cache_age" -lt 86400 ]; then
            cat "$FOLDER_ID_CACHE"
            return 0
        fi
    fi

    log STEP "Mencari Folder ID untuk '$GDRIVE_FOLDER' (Drive Utama & Dibagikan ke Saya)..."

    local folder_id=""

    # Pencarian di Drive Utama
    folder_id=$(rclone lsjson "$REMOTE_NAME:" \
        --drive-trashed-only=false 2>/dev/null \
        | python3 -c "
import json, sys
items = json.load(sys.stdin)
for item in items:
    if item.get('IsDir') and item.get('Name') == '${GDRIVE_FOLDER}':
        print(item.get('ID', ''))
        break
" 2>/dev/null || echo "")

    # Pencarian di folder "Dibagikan ke Saya"
    if [ -z "$folder_id" ]; then
        log STEP "Folder tidak ditemukan di Drive Utama — mencari di folder 'Dibagikan ke Saya'..."
        folder_id=$(rclone lsjson "$REMOTE_NAME:" \
            --drive-shared-with-me \
            --drive-trashed-only=false 2>/dev/null \
            | python3 -c "
import json, sys
items = json.load(sys.stdin)
for item in items:
    if item.get('IsDir') and item.get('Name') == '${GDRIVE_FOLDER}':
        print(item.get('ID', ''))
        break
" 2>/dev/null || echo "")
    fi

    if [ -z "$folder_id" ]; then
        # Buat folder baru jika tidak ditemukan di mana pun
        log WARN "Folder '$GDRIVE_FOLDER' tidak ditemukan — membuat folder baru di Drive Utama..."
        rclone mkdir "$REMOTE_NAME:$GDRIVE_FOLDER" 2>/dev/null || {
            log ERROR "Gagal membuat folder '$GDRIVE_FOLDER' di Google Drive."
            return 1
        }
        folder_id=$(rclone lsjson "$REMOTE_NAME:" \
            --drive-trashed-only=false 2>/dev/null \
            | python3 -c "
import json, sys
items = json.load(sys.stdin)
for item in items:
    if item.get('IsDir') and item.get('Name') == '${GDRIVE_FOLDER}':
        print(item.get('ID', ''))
        break
" 2>/dev/null || echo "")
    fi

    if [ -z "$folder_id" ]; then
        log ERROR "Gagal mendapatkan Folder ID untuk '$GDRIVE_FOLDER'."
        return 1
    fi

    echo "$folder_id" > "$FOLDER_ID_CACHE"
    log INFO "Folder ID ditemukan: $folder_id (disimpan ke cache)."
    echo "$folder_id"
}

# Mendapatkan path remote berdasarkan Folder ID (jika tersedia)
get_remote_target() {
    local folder_id
    folder_id=$(resolve_gdrive_folder_id 2>/dev/null || echo "")
    if [ -n "$folder_id" ]; then
        echo "$REMOTE_NAME:{$folder_id}"
    else
        echo "$REMOTE_NAME:$GDRIVE_FOLDER"
    fi
}

# ─── KONEKSI GOOGLE DRIVE ─────────────────────────────────────
gdrive_is_alive() {
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$" || return 1
    rclone lsd "$REMOTE_NAME:" &>/dev/null || return 1
    return 0
}

setup_gdrive() {
    auto_repair_rclone_config || true

    if gdrive_is_alive; then
        log INFO "Google Drive berhasil terhubung."
        return 0
    fi

    rclone config delete "$REMOTE_NAME" 2>/dev/null || true
    rm -f "$FOLDER_ID_CACHE"

    echo -e "\n${CYAN}${BOLD}═══════ PENGATURAN GOOGLE DRIVE ═══════${NC}"
    echo -e "  ${BOLD}1.${NC} Service Account JSON ${GREEN}[Direkomendasikan — untuk banyak server]${NC}"
    echo -e "  ${BOLD}2.${NC} OAuth Token ${YELLOW}[Untuk 1 server / keperluan pengujian]${NC}"
    echo ""
    read -rp "Pilihan (1/2): " AUTH

    case "$AUTH" in
        1) setup_service_account ;;
        2) setup_oauth ;;
        *) log ERROR "Pilihan tidak valid."; exit 1 ;;
    esac
}

setup_service_account() {
    echo -e "\n${CYAN}PANDUAN PENGATURAN SERVICE ACCOUNT:${NC}"
    echo -e "  1. Buka ${YELLOW}https://console.cloud.google.com/${NC}"
    echo -e "  2. Navigasi ke IAM & Admin → Service Accounts → Create"
    echo -e "  3. Pilih Keys → Add Key → JSON → Download"
    echo -e "  4. Bagikan folder Google Drive ke alamat email service account tersebut"
    echo -e "\n${YELLOW}Tempel isi file JSON di bawah ini, lalu tekan CTRL+D:${NC}"

    mkdir -p "$CONFIG_DIR"
    local sa_file="$CONFIG_DIR/service_account.json"
    cat > "$sa_file"

    python3 -c "import json,sys; json.load(open('$sa_file'))" 2>/dev/null \
        || { log ERROR "Format JSON tidak valid."; rm -f "$sa_file"; exit 1; }
    chmod 600 "$sa_file"

    rclone config create "$REMOTE_NAME" drive \
        service_account_file="$sa_file" \
        scope=drive \
        --non-interactive >/dev/null 2>&1

    gdrive_is_alive \
        || { log ERROR "Koneksi gagal — periksa izin akses service account."; exit 1; }
    log INFO "Service Account berhasil dikonfigurasi."
}

setup_oauth() {
    echo -e "\n${CYAN}Jalankan perintah berikut di Termux, lalu masuk dengan akun Google Drive yang ingin digunakan:${NC}"
    echo -e "  ${YELLOW}pkg update -y && pkg install rclone -y${NC}"
    echo -e "  ${YELLOW}rclone authorize \"drive\"${NC}"
    echo -e "\nTempel token JSON yang dihasilkan di sini:"
    read -rp "> " TOKEN_JSON

    rclone config create "$REMOTE_NAME" drive \
        token="$TOKEN_JSON" \
        scope=drive \
        --non-interactive >/dev/null 2>&1

    gdrive_is_alive \
        || { log ERROR "Token tidak valid atau koneksi gagal."; exit 1; }
    log INFO "Autentikasi OAuth berhasil."
}

# ─── NAMA NODE ───────────────────────────────────────────────
get_node_name() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$NODE_CONFIG" ]; then
        read -rp "Masukkan nama node (contoh: SG-Node-01): " input
        local sanitized
        sanitized=$(echo "$input" | tr -cd '[:alnum:]_-')
        [ -z "$sanitized" ] && { log ERROR "Nama node tidak valid."; exit 1; }
        echo "$sanitized" > "$NODE_CONFIG"
    fi
    cat "$NODE_CONFIG"
}

# ─── PEMERIKSAAN RUANG DISK ───────────────────────────────────
check_disk_space() {
    local src="$1"
    local src_mb; src_mb=$(du -sm "$src" 2>/dev/null | awk '{print $1}')
    local free_mb; free_mb=$(df -m "$TEMP_DIR" | awk 'NR==2{print $4}')
    local need_mb=$(( src_mb + 512 ))

    log STEP "Ukuran sumber: ${src_mb}MB | Ruang tersedia: ${free_mb}MB | Diperlukan: ${need_mb}MB"
    [ "$free_mb" -ge "$need_mb" ] && return 0

    log ERROR "Ruang disk tidak mencukupi. Tersedia: ${free_mb}MB, Diperlukan: ${need_mb}MB."
    exit 1
}

# ─── RCLONE DENGAN MEKANISME PERCOBAAN ULANG ─────────────────
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
        log WARN "Percobaan $attempt/$MAX_RETRIES gagal — mencoba ulang dalam 15 detik..."
        sleep 15
        (( attempt++ )) || true
    done
    log ERROR "Operasi gagal setelah $MAX_RETRIES percobaan."
    return 1
}

# ─── KOMPRESI CERDAS ─────────────────────────────────────────
smart_compress() {
    local src_dir="$1"
    local src_name="$2"
    local dest="$3"

    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)

    local nice_prefix="nice -n 10"
    if command -v ionice &>/dev/null; then
        nice_prefix="ionice -c3 nice -n 10"
    fi

    if command -v pigz &>/dev/null; then
        local threads=$(( cpu_count / 2 ))
        [ "$threads" -lt 1 ] && threads=1
        log STEP "Kompresi paralel menggunakan pigz ($threads thread, prioritas rendah)..."
        $nice_prefix tar \
            --use-compress-program="pigz -p $threads" \
            -f "$dest" \
            --checkpoint=500 \
            --checkpoint-action=dot \
            -c -C "$src_dir" "$src_name" 2>/dev/null
    else
        log STEP "Kompresi menggunakan gzip standar (prioritas rendah)..."
        $nice_prefix tar \
            -czf "$dest" \
            --checkpoint=500 \
            --checkpoint-action=dot \
            -C "$src_dir" "$src_name" 2>/dev/null
    fi
}

# ─── PROSES BACKUP ───────────────────────────────────────────
do_backup() {
    local node; node=$(get_node_name)
    local stamp; stamp=$(date +%Y-%m-%d_%H-%M-%S)
    local fname="${node}_${stamp}.tar.gz"
    local tmpf="$TEMP_DIR/$fname"

    echo -e "\n${CYAN}${BOLD}═══════ MODE BACKUP ═══════${NC}"
    log STEP "Node: $node | File target: $fname"

    [ -d "$PTERO_PATH" ] || { log ERROR "Direktori tidak ditemukan: $PTERO_PATH"; exit 1; }

    mkdir -p "$TEMP_DIR"
    check_disk_space "$PTERO_PATH"

    local remote_target
    remote_target=$(get_remote_target)
    log STEP "Tujuan remote: $remote_target"

    local wings_was_running=false
    if systemctl is-active --quiet wings 2>/dev/null; then
        log STEP "Menghentikan Wings sementara selama proses backup..."
        if systemctl stop wings 2>/dev/null; then
            wings_was_running=true
            log INFO "Wings berhasil dihentikan."
        else
            log WARN "Gagal menghentikan Wings — proses backup tetap dilanjutkan."
        fi
    else
        log INFO "Wings tidak aktif — melanjutkan proses backup."
    fi

    local t0=$SECONDS
    smart_compress "/var/lib/pterodactyl" "volumes" "$tmpf"
    echo ""
    local elapsed=$(( SECONDS - t0 ))
    local fsize; fsize=$(du -sh "$tmpf" | awk '{print $1}')
    log INFO "Kompresi selesai: ${fsize} dalam ${elapsed} detik."

    log STEP "Mengunggah ke Google Drive..."
    rclone_retry copy "$tmpf" "$remote_target" \
        || { log ERROR "Pengunggahan gagal."; exit 1; }

    rm -f "$tmpf"

    if $wings_was_running; then
        log STEP "Menjalankan kembali Wings..."
        if systemctl start wings 2>/dev/null; then
            sleep 3
            if systemctl is-active --quiet wings 2>/dev/null; then
                log INFO "Wings kembali berjalan."
            else
                log WARN "Wings gagal dijalankan — periksa dengan: systemctl status wings"
            fi
        else
            log WARN "Gagal menjalankan Wings — jalankan secara manual: systemctl start wings"
        fi
    fi

    log STEP "Menghapus backup yang lebih lama dari ${RETENTION_DAYS} hari..."
    rclone delete "$remote_target" \
        --min-age "${RETENTION_DAYS}d" \
        --include "${node}_*.tar.gz" 2>/dev/null || true

    echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════╗"
    echo -e "║         ✅ BACKUP BERHASIL!           ║"
    echo -e "╠══════════════════════════════════════╣"
    echo -e "║${NC} Node  : ${BOLD}$node${NC}"
    echo -e "${GREEN}${BOLD}║${NC} File  : ${BOLD}$fname${NC}"
    echo -e "${GREEN}${BOLD}║${NC} Ukuran: ${BOLD}$fsize${NC}"
    echo -e "${GREEN}${BOLD}║${NC} Drive : ${BOLD}$remote_target${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"

    log INFO "BACKUP SELESAI: $fname ($fsize)"
}

# ─── PROSES RESTORE ──────────────────────────────────────────
do_restore() {
    echo -e "\n${CYAN}${BOLD}═══════ MODE RESTORE ═══════${NC}"
    log STEP "Mengambil daftar backup dari Google Drive..."

    local remote_target
    remote_target=$(get_remote_target)

    local list
    list=$(rclone lsf "$remote_target" --include "*.tar.gz" 2>/dev/null | sort -r) || true

    [ -z "$list" ] && { log ERROR "Tidak ada backup yang tersedia di Google Drive. (target: $remote_target)"; exit 1; }

    echo -e "\n${YELLOW}${BOLD}Daftar Backup yang Tersedia:${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────${NC}"

    local -a files
    local i=1
    while IFS= read -r f; do
        files+=("$f")
        local sz
        sz=$(rclone size "$remote_target/$f" --json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); mb=d['bytes']//1024//1024; print(f'{mb}MB')" \
            2>/dev/null || echo "?") || sz="?"
        echo -e "  ${BOLD}[$i]${NC} $f ${YELLOW}($sz)${NC}"
        (( i++ )) || true
    done <<< "$list"

    echo -e "${CYAN}──────────────────────────────────────────────${NC}"
    echo ""
    read -rp "Pilih nomor backup (1-${#files[@]}): " num

    [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#files[@]}" ] \
        || { log ERROR "Nomor yang dimasukkan tidak valid."; exit 1; }

    local rfile="${files[$((num-1))]}"

    echo -e "\n${RED}${BOLD}⚠️  PERINGATAN: TINDAKAN INI TIDAK DAPAT DIBATALKAN! ⚠️${NC}"
    echo -e "${RED}  • Seluruh isi $PTERO_PATH akan dihapus.${NC}"
    echo -e "${YELLOW}  • File   : $rfile${NC}"
    echo -e "${YELLOW}  • Data lama akan dipindahkan ke /root/volumes_snapshot_*${NC}"
    echo ""
    read -rp "Ketik ${BOLD}RESTORE${NC} untuk melanjutkan: " confirm

    [ "$confirm" == "RESTORE" ] || { log WARN "Proses restore dibatalkan."; exit 0; }

    mkdir -p "$TEMP_DIR"
    local local_file="$TEMP_DIR/$rfile"

    log STEP "Mengunduh file: $rfile"
    rclone_retry copy "$remote_target/$rfile" "$TEMP_DIR/" \
        || { log ERROR "Pengunduhan gagal."; exit 1; }

    log STEP "Memverifikasi integritas arsip..."
    tar -tzf "$local_file" >/dev/null 2>&1 \
        || { log ERROR "File backup rusak atau tidak dapat dibaca."; rm -f "$local_file"; exit 1; }
    log INFO "Arsip valid."

    local wings_up=false
    if systemctl is-active --quiet wings 2>/dev/null; then
        log STEP "Menghentikan Wings..."
        systemctl stop wings && wings_up=true
    fi

    local snap="/root/volumes_snapshot_$(date +%H%M%S)"
    if [ -d "$PTERO_PATH" ] && [ "$(ls -A "$PTERO_PATH" 2>/dev/null)" ]; then
        log STEP "Memindahkan data lama ke: $snap"
        mv "$PTERO_PATH" "$snap" 2>/dev/null || true
    fi
    mkdir -p "$PTERO_PATH"

    log STEP "Mengekstrak backup..."
    tar -xzf "$local_file" \
        --checkpoint=500 \
        --checkpoint-action=dot \
        -C /var/lib/pterodactyl 2>/dev/null
    echo ""
    log INFO "Ekstraksi selesai."

    log STEP "Memperbaiki izin akses direktori..."
    local ptero_uid
    ptero_uid=$(id -u pterodactyl 2>/dev/null || echo "988")
    chown -R "${ptero_uid}:${ptero_uid}" "$PTERO_PATH" 2>/dev/null || true
    chmod -R 755 "$PTERO_PATH" 2>/dev/null || true

    if $wings_up; then
        log STEP "Menjalankan kembali Wings..."
        systemctl start wings && sleep 3
        systemctl is-active --quiet wings \
            && log INFO "Wings kembali berjalan." \
            || log WARN "Wings gagal dijalankan — periksa dengan: systemctl status wings"
    fi

    rm -f "$local_file"

    echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════╗"
    echo -e "║         ✅ RESTORE BERHASIL!          ║"
    echo -e "╠══════════════════════════════════════╣"
    echo -e "║${NC} File     : ${BOLD}$rfile${NC}"
    echo -e "${GREEN}${BOLD}║${NC} Snapshot : ${BOLD}$snap${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"

    log INFO "RESTORE SELESAI: $rfile"
}

# ─── PENJADWALAN OTOMATIS (CRON) ─────────────────────────────
setup_cron() {
    echo -e "\n${CYAN}${BOLD}═══════ JADWAL BACKUP OTOMATIS ═══════${NC}"
    echo -e "  ${BOLD}1.${NC} Setiap 6 jam"
    echo -e "  ${BOLD}2.${NC} Setiap 12 jam"
    echo -e "  ${BOLD}3.${NC} Setiap hari pukul 02:00"
    echo -e "  ${BOLD}4.${NC} Setiap hari pukul 00:00 & 12:00"
    echo -e "  ${BOLD}5.${NC} Ekspresi cron kustom"
    echo -e "  ${BOLD}6.${NC} ❌ Hapus jadwal yang ada"
    echo ""
    read -rp "Pilihan (1-6): " choice

    local script_path="/usr/local/bin/bimxyz"
    local cron_cmd="bash $script_path --auto-backup >> $LOG_FILE 2>&1"

    crontab -l 2>/dev/null | grep -v "$script_path" | crontab - 2>/dev/null || true

    [ "$choice" == "6" ] && { log INFO "Jadwal backup otomatis berhasil dihapus."; return 0; }

    local expr
    case "$choice" in
        1) expr="0 */6 * * *" ;;
        2) expr="0 */12 * * *" ;;
        3) expr="0 2 * * *" ;;
        4) expr="0 0,12 * * *" ;;
        5) read -rp "Masukkan ekspresi cron: " expr ;;
        *) log ERROR "Pilihan tidak valid."; return 1 ;;
    esac

    ( crontab -l 2>/dev/null; echo "$expr $cron_cmd" ) | crontab -
    log INFO "Jadwal backup otomatis aktif: [$expr]"
    echo -e "${GREEN}Verifikasi jadwal dengan perintah: ${YELLOW}crontab -l${NC}"
}

# ─── DASBOR STATUS SISTEM ────────────────────────────────────
show_status() {
    echo -e "\n${CYAN}${BOLD}═══════ STATUS SISTEM ═══════${NC}"

    local node="(belum dikonfigurasi)"
    [ -f "$NODE_CONFIG" ] && node=$(cat "$NODE_CONFIG" 2>/dev/null || echo "(belum dikonfigurasi)")
    echo -e "  Node         : ${BOLD}$node${NC}"

    {
        if gdrive_is_alive 2>/dev/null; then
            local remote_target; remote_target=$(get_remote_target 2>/dev/null || echo "$REMOTE_NAME:$GDRIVE_FOLDER")
            local count
            count=$(rclone lsf "$remote_target" --include "*.tar.gz" 2>/dev/null | wc -l) || count="?"
            echo -e "  Google Drive : ${GREEN}${BOLD}TERHUBUNG ✓${NC} ($count backup tersedia)"
        else
            echo -e "  Google Drive : ${RED}${BOLD}TIDAK TERHUBUNG ✗${NC}"
        fi
    } || echo -e "  Google Drive : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    {
        local disk
        disk=$(df -h "$PTERO_PATH" 2>/dev/null | awk 'NR==2{printf "%s terpakai / %s total (%s)", $3,$2,$5}') \
            || disk="(tidak dapat dibaca)"
        echo -e "  Disk         : ${BOLD}$disk${NC}"
    } || echo -e "  Disk         : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    {
        if systemctl is-active --quiet wings 2>/dev/null; then
            echo -e "  Wings        : ${GREEN}${BOLD}BERJALAN ✓${NC}"
        else
            echo -e "  Wings        : ${RED}${BOLD}BERHENTI${NC}"
        fi
    } || echo -e "  Wings        : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    {
        local cron_entry
        cron_entry=$(crontab -l 2>/dev/null | grep "/usr/local/bin/bimxyz" || true)
        if [ -n "$cron_entry" ]; then
            echo -e "  Backup Otomatis: ${GREEN}${BOLD}AKTIF${NC} → $cron_entry"
        else
            echo -e "  Backup Otomatis: ${YELLOW}${BOLD}TIDAK AKTIF${NC}"
        fi
    } || echo -e "  Backup Otomatis: ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    {
        local last
        last=$(grep "BACKUP SELESAI\|RESTORE SELESAI" "$LOG_FILE" 2>/dev/null | tail -1 || true)
        [ -n "$last" ] && echo -e "  Operasi Terakhir: ${BOLD}$(echo "$last" | cut -d' ' -f1-3)${NC} — $(echo "$last" | cut -d']' -f3-)"
    } || true

    echo ""
}

# ─── BANNER ──────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo -e "╔═════════════════════════════════════════════════╗"
    echo -e "║    👑 BIMXYZ ULTIMATE BACKUP SYSTEM V${VERSION}  ║"
    echo -e "║       Production Grade | Multi-Server Deploy     ║"
    echo -e "╚═════════════════════════════════════════════════╝${NC}"
    echo -e "  ${YELLOW}Log: $LOG_FILE${NC}\n"
}

# ─── MENU UTAMA ───────────────────────────────────────────────
show_menu() {
    echo -e "\n${CYAN}${BOLD}MENU UTAMA:${NC}"
    echo -e "  ${BOLD}1.${NC} 🚀 Jalankan Backup Sekarang"
    echo -e "  ${BOLD}2.${NC} 📥 Pulihkan Backup (Restore)"
    echo -e "  ${BOLD}3.${NC} ⏰ Atur Backup Otomatis"
    echo -e "  ${BOLD}4.${NC} 📊 Lihat Status Sistem"
    echo -e "  ${BOLD}5.${NC} 🔄 Reset Autentikasi Google Drive"
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
            rm -f "$FOLDER_ID_CACHE"
            log INFO "Autentikasi berhasil direset. Jalankan skrip kembali untuk mengonfigurasi ulang."
            ;;
        6) exit 0 ;;
        *) log ERROR "Pilihan tidak valid." ;;
    esac
}

# ─── TITIK MASUK UTAMA ───────────────────────────────────────
main() {
    check_root
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"

    if [ "${1:-}" == "--auto-backup" ]; then
        log INFO "=== BACKUP OTOMATIS DIMULAI (CRON) ==="
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
