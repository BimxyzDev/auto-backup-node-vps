#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║   BIMXYZ ULTIMATE BACKUP SYSTEM V5.0                        ║
# ║   Enterprise Grade | Multi-Server | Timezone-Aware Cron     ║
# ╚══════════════════════════════════════════════════════════════╝

set -uo pipefail

# ─── KONSTANTA ────────────────────────────────────────────────
readonly VERSION="5.0"
readonly REMOTE_NAME="gdrive_bimxyz"
readonly GDRIVE_FOLDER="Backup_Bimxyz"
readonly PTERO_PATH="/var/lib/pterodactyl/volumes"
readonly CONFIG_DIR="/root/.bimxyz"
readonly TEMP_DIR="/root/.bimxyz_temp"
readonly NODE_CONFIG="$CONFIG_DIR/node.conf"
readonly FOLDER_ID_CACHE="$CONFIG_DIR/gdrive_folder_id.cache"
readonly LOG_FILE="/var/log/bimxyz_backup.log"
readonly SCRIPT_PATH="/usr/local/bin/bimxyz"
readonly MAX_RETRIES=3
readonly RETENTION_DAYS=7

# ─── WARNA ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

# ─── LOGGING ──────────────────────────────────────────────────
# FIX #2: Semua echo -e dekoratif dialihkan ke stderr (>&2)
# sehingga tidak merusak command substitution seperti:
#   folder_id=$(resolve_gdrive_folder_id)
log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    case "$level" in
        INFO)  echo -e "${GREEN}[✓] $msg${NC}" >&2 ;;
        WARN)  echo -e "${YELLOW}[!] $msg${NC}" >&2 ;;
        ERROR) echo -e "${RED}[✗] $msg${NC}" >&2 ;;
        STEP)  echo -e "${CYAN}[»] $msg${NC}" >&2 ;;
    esac
}


# ─── PEMBERSIHAN ──────────────────────────────────────────────
cleanup() {
    local code=$?
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    [ $code -ne 0 ] && log ERROR "Proses dihentikan (kode keluar: $code) — periksa log: $LOG_FILE"
}
trap cleanup EXIT
trap 'log ERROR "Proses dibatalkan oleh pengguna."; exit 130' INT TERM

# ─── PEMERIKSAAN HAK AKSES ROOT ───────────────────────────────
check_root() {
    [ "$EUID" -eq 0 ] && return
    echo -e "${RED}[✗] Skrip ini harus dijalankan sebagai root. Gunakan: sudo bash $0${NC}"
    exit 1
}

# ─── INSTALASI DEPENDENSI ─────────────────────────────────────
install_deps() {
    local missing=()
    command -v rclone  &>/dev/null || missing+=("rclone")
    command -v curl    &>/dev/null || missing+=("curl")
    command -v python3 &>/dev/null || missing+=("python3")
    command -v bc      &>/dev/null || missing+=("bc")

    [ ${#missing[@]} -eq 0 ] && return 0

    log STEP "Menginstal dependensi yang diperlukan: ${missing[*]}"
    for dep in "${missing[@]}"; do
        if [ "$dep" == "rclone" ]; then
            curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 \
                || { log ERROR "Gagal menginstal rclone."; exit 1; }
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$dep" >/dev/null 2>&1 \
                || { log ERROR "Gagal menginstal $dep."; exit 1; }
        fi
    done
    log INFO "Seluruh dependensi berhasil diinstal."
}

# ─── PERBAIKAN OTOMATIS KONFIGURASI RCLONE ────────────────────
auto_repair_rclone_config() {
    local sa_file="$CONFIG_DIR/service_account.json"

    rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$" && return 0
    [ -f "$sa_file" ] || return 1

    log WARN "Remote '$REMOTE_NAME' tidak ditemukan — menjalankan perbaikan otomatis..."

    python3 -c "import json,sys; json.load(open('$sa_file'))" 2>/dev/null \
        || { log ERROR "File service_account.json tidak valid — perbaikan dibatalkan."; return 1; }

    rclone config create "$REMOTE_NAME" drive \
        service_account_file="$sa_file" \
        scope=drive \
        --non-interactive >/dev/null 2>&1 \
        || { log ERROR "Perbaikan otomatis gagal membuat remote."; return 1; }

    log INFO "Perbaikan otomatis konfigurasi rclone berhasil."
}

# ─── PENCARIAN FOLDER ID GOOGLE DRIVE ─────────────────────────
_gdrive_lsjson_find() {
    python3 -c "
import json, sys
items = json.load(sys.stdin)
for item in items:
    if item.get('IsDir') and item.get('Name') == '${GDRIVE_FOLDER}':
        print(item.get('ID', ''))
        break
" 2>/dev/null || echo ""
}

resolve_gdrive_folder_id() {
    if [ -f "$FOLDER_ID_CACHE" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$FOLDER_ID_CACHE" 2>/dev/null || echo 0) ))
        [ "$age" -lt 86400 ] && { cat "$FOLDER_ID_CACHE"; return 0; }
    fi

    log STEP "Mencari Folder ID untuk '$GDRIVE_FOLDER'..."

    local folder_id
    folder_id=$(rclone lsjson "$REMOTE_NAME:" --drive-trashed-only=false 2>/dev/null | _gdrive_lsjson_find)

    if [ -z "$folder_id" ]; then
        log STEP "Tidak ditemukan di Drive Utama — mencari di folder 'Dibagikan ke Saya'..."
        folder_id=$(rclone lsjson "$REMOTE_NAME:" --drive-shared-with-me --drive-trashed-only=false 2>/dev/null | _gdrive_lsjson_find)
    fi

    if [ -z "$folder_id" ]; then
        log WARN "Folder '$GDRIVE_FOLDER' tidak ditemukan — membuat folder baru..."
        rclone mkdir "$REMOTE_NAME:$GDRIVE_FOLDER" 2>/dev/null \
            || { log ERROR "Gagal membuat folder '$GDRIVE_FOLDER' di Google Drive."; return 1; }
        folder_id=$(rclone lsjson "$REMOTE_NAME:" --drive-trashed-only=false 2>/dev/null | _gdrive_lsjson_find)
    fi

    [ -z "$folder_id" ] && { log ERROR "Gagal mendapatkan Folder ID untuk '$GDRIVE_FOLDER'."; return 1; }

    echo "$folder_id" > "$FOLDER_ID_CACHE"
    log INFO "Folder ID ditemukan: $folder_id (tersimpan di cache)."
    echo "$folder_id"
}

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
    echo -e "\n${CYAN}Jalankan perintah berikut di Termux, lalu masuk menggunakan akun Google Drive yang dituju:${NC}"
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

# ─── MANAJEMEN NAMA NODE ──────────────────────────────────────
manage_node_name() {
    echo -e "\n${CYAN}${BOLD}═══════ PENGATURAN NAMA NODE SERVER ═══════${NC}"

    local current="(belum dikonfigurasi)"
    [ -f "$NODE_CONFIG" ] && current=$(cat "$NODE_CONFIG" 2>/dev/null || echo "(belum dikonfigurasi)")
    echo -e "  Nama node saat ini : ${BOLD}${current}${NC}"
    echo ""
    read -rp "Masukkan nama node baru (contoh: SG-Node-01): " input

    local sanitized
    sanitized=$(echo "$input" | tr -cd '[:alnum:]_-')
    [ -z "$sanitized" ] && { log ERROR "Nama node tidak valid. Hanya huruf, angka, tanda hubung, dan garis bawah yang diizinkan."; return 1; }

    mkdir -p "$CONFIG_DIR"
    echo "$sanitized" > "$NODE_CONFIG"
    log INFO "Nama node berhasil disimpan: $sanitized"
}

get_node_name() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$NODE_CONFIG" ]; then
        log WARN "Nama node belum dikonfigurasi. Silakan atur terlebih dahulu."
        manage_node_name || exit 1
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

# ─── RCLONE DENGAN MEKANISME PERCOBAAN ULANG ──────────────────
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
        log WARN "Percobaan ke-${attempt}/${MAX_RETRIES} gagal — mencoba ulang dalam 15 detik..."
        sleep 15
        (( attempt++ )) || true
    done
    log ERROR "Operasi gagal setelah $MAX_RETRIES kali percobaan."
    return 1
}

# ─── KOMPRESI CERDAS ──────────────────────────────────────────
smart_compress() {
    local src_dir="$1" src_name="$2" dest="$3"
    local cpu_count; cpu_count=$(nproc 2>/dev/null || echo 1)
    local nice_prefix="nice -n 10"
    command -v ionice &>/dev/null && nice_prefix="ionice -c3 nice -n 10"

    if command -v pigz &>/dev/null; then
        local threads=$(( cpu_count / 2 )); [ "$threads" -lt 1 ] && threads=1
        log STEP "Kompresi paralel menggunakan pigz ($threads thread, prioritas rendah)..."
        $nice_prefix tar --use-compress-program="pigz -p $threads" \
            -f "$dest" --checkpoint=500 --checkpoint-action=dot \
            -c -C "$src_dir" "$src_name" 2>/dev/null
    else
        log STEP "Kompresi menggunakan gzip standar (prioritas rendah)..."
        $nice_prefix tar -czf "$dest" \
            --checkpoint=500 --checkpoint-action=dot \
            -C "$src_dir" "$src_name" 2>/dev/null
    fi
}

# ─── LOGIKA INTI BACKUP (dijalankan di background) ────────────
_backup_worker() {
    local node; node=$(get_node_name)
    local stamp; stamp=$(date +%Y-%m-%d_%H-%M-%S)
    local fname="${node}_${stamp}.tar.gz"
    local tmpf="$TEMP_DIR/$fname"

    log STEP "=== BACKUP WORKER DIMULAI (PID: $$) ==="
    log STEP "Node: $node | Nama file: $fname"

    [ -d "$PTERO_PATH" ] || { log ERROR "Direktori tidak ditemukan: $PTERO_PATH"; exit 1; }

    mkdir -p "$TEMP_DIR"
    check_disk_space "$PTERO_PATH"

    local remote_target; remote_target=$(get_remote_target)
    log STEP "Tujuan remote: $remote_target"

    local wings_was_running=false
    if systemctl is-active --quiet wings 2>/dev/null; then
        log STEP "Menghentikan Wings sementara selama proses backup..."
        systemctl stop wings 2>/dev/null \
            && wings_was_running=true && log INFO "Wings berhasil dihentikan." \
            || log WARN "Gagal menghentikan Wings — proses backup tetap dilanjutkan."
    else
        log INFO "Wings tidak aktif — melanjutkan proses backup."
    fi

    local t0=$SECONDS
    smart_compress "/var/lib/pterodactyl" "volumes" "$tmpf"
    echo "" >> "$LOG_FILE"
    local elapsed=$(( SECONDS - t0 ))
    local fsize; fsize=$(du -sh "$tmpf" | awk '{print $1}')
    log INFO "Kompresi selesai: ${fsize} dalam ${elapsed} detik."

    log STEP "Mengunggah ke Google Drive..."
    rclone_retry copy "$tmpf" "$remote_target" \
        || { log ERROR "Pengunggahan gagal."; exit 1; }

    rm -f "$tmpf"

    if $wings_was_running; then
        log STEP "Menjalankan kembali Wings..."
        systemctl start wings 2>/dev/null && sleep 3
        systemctl is-active --quiet wings 2>/dev/null \
            && log INFO "Wings kembali berjalan." \
            || log WARN "Wings gagal dijalankan — periksa dengan: systemctl status wings"
    fi

    log STEP "Menghapus backup yang lebih lama dari ${RETENTION_DAYS} hari..."
    rclone delete "$remote_target" \
        --min-age "${RETENTION_DAYS}d" \
        --include "${node}_*.tar.gz" 2>/dev/null || true

    log INFO "========================================"
    log INFO "  ✅  BACKUP BERHASIL!"
    log INFO "  Node  : $node"
    log INFO "  File  : $fname"
    log INFO "  Ukuran: $fsize"
    log INFO "  Drive : $remote_target"
    log INFO "========================================"
    log INFO "BACKUP SELESAI: $fname ($fsize)"
}

# ─── PROSES BACKUP (dengan SIGHUP-proof background execution) ─
# FIX #1: Operasi berat dilempar ke background via nohup + subshell,
# layar foreground otomatis menjalankan `tail -f` untuk memantau log.
# Ctrl+C atau putusnya SSH hanya mematikan tail, bukan worker.
do_backup() {
    echo -e "\n${CYAN}${BOLD}═══════ PROSES BACKUP ═══════${NC}"
    echo -e "${YELLOW}[»] Proses backup dijalankan di background (kebal SIGHUP).${NC}"
    echo -e "${YELLOW}[»] Pantau progress melalui log di bawah ini.${NC}"
    echo -e "${YELLOW}[»] Tekan Ctrl+C kapan saja untuk berhenti memantau —${NC}"
    echo -e "${YELLOW}    proses backup TETAP berjalan di background.${NC}\n"

    # Jalankan worker di background, kebal SIGHUP, stdout+stderr masuk ke log
    nohup bash -c "
        source '$SCRIPT_PATH'
        _backup_worker
    " >> "$LOG_FILE" 2>&1 &
    local bg_pid=$!
    disown "$bg_pid"

    echo -e "${GREEN}[✓] Worker backup berjalan (PID: ${bg_pid}).${NC}"
    echo -e "${CYAN}[»] Menampilkan log secara langsung (Ctrl+C untuk berhenti memantau)...${NC}\n"

    # Tail log hingga kata kunci selesai terdeteksi atau pengguna Ctrl+C
    # Menggunakan subshell agar trap INT hanya mematikan tail, bukan skrip utama
    (
        trap 'exit 0' INT
        tail -f "$LOG_FILE" --pid="$bg_pid" 2>/dev/null \
            || tail -f "$LOG_FILE"
    ) &
    local tail_pid=$!

    # Tunggu worker selesai, lalu hentikan tail
    wait "$bg_pid" 2>/dev/null || true
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true

    echo -e "\n${GREEN}${BOLD}[✓] Proses backup telah selesai. Cek log untuk detail: $LOG_FILE${NC}"
}

# ─── LOGIKA INTI RESTORE (dijalankan di background) ───────────
_restore_worker() {
    local rfile="$1"
    local remote_target="$2"

    log STEP "=== RESTORE WORKER DIMULAI (PID: $$) ==="

    mkdir -p "$TEMP_DIR"
    local local_file="$TEMP_DIR/$rfile"

    log STEP "Mengunduh file: $rfile"
    rclone_retry copy "$remote_target/$rfile" "$TEMP_DIR/" \
        || { log ERROR "Pengunduhan gagal."; exit 1; }

    log STEP "Memverifikasi integritas arsip..."
    tar -tzf "$local_file" >/dev/null 2>&1 \
        || { log ERROR "File backup rusak atau tidak dapat dibaca."; rm -f "$local_file"; exit 1; }
    log INFO "Integritas arsip terverifikasi."

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

    log STEP "Mengekstrak arsip backup..."
    tar -xzf "$local_file" \
        --checkpoint=500 \
        --checkpoint-action=dot \
        -C /var/lib/pterodactyl 2>/dev/null
    echo "" >> "$LOG_FILE"
    log INFO "Ekstraksi selesai."

    log STEP "Memperbaiki izin akses direktori..."
    local ptero_uid; ptero_uid=$(id -u pterodactyl 2>/dev/null || echo "988")
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

    log INFO "========================================"
    log INFO "  ✅  RESTORE BERHASIL!"
    log INFO "  File     : $rfile"
    log INFO "  Snapshot : $snap"
    log INFO "========================================"
    log INFO "RESTORE SELESAI: $rfile"
}

# ─── PROSES RESTORE (dengan SIGHUP-proof background execution) ─
# FIX #1: Sama seperti do_backup — bagian interaktif (pilih file,
# konfirmasi) tetap di foreground. Setelah konfirmasi, worker
# dikirim ke background dan layar menampilkan tail -f log.
# FIX #3: Prompt konfirmasi menggunakan echo -en + read -r terpisah
# agar kode ANSI tidak muncul sebagai teks mentah di Termux/klien SSH.
do_restore() {
    echo -e "\n${CYAN}${BOLD}═══════ PROSES RESTORE ═══════${NC}"
    log STEP "Mengambil daftar backup dari Google Drive..."

    local remote_target; remote_target=$(get_remote_target)
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
            2>/dev/null || echo "?")
        echo -e "  ${BOLD}[$i]${NC} $f ${YELLOW}($sz)${NC}"
        (( i++ )) || true
    done <<< "$list"

    echo -e "${CYAN}──────────────────────────────────────────────${NC}"
    echo ""
    read -rp "Pilih nomor backup (1-${#files[@]}): " num

    [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#files[@]}" ] \
        || { log ERROR "Nomor yang dimasukkan tidak valid."; exit 1; }

    local rfile="${files[$((num-1))]}"

    echo -e "\n${RED}${BOLD}⚠️   PERINGATAN: TINDAKAN INI TIDAK DAPAT DIBATALKAN! ⚠️${NC}"
    echo -e "${RED}  • Seluruh isi $PTERO_PATH akan dihapus.${NC}"
    echo -e "${YELLOW}  • File   : $rfile${NC}"
    echo -e "${YELLOW}  • Data lama akan dipindahkan ke /root/volumes_snapshot_*${NC}"
    echo ""

    # FIX #3: Pisahkan echo prompt dan read agar ANSI color
    # tidak muncul sebagai karakter mentah di Termux / klien SSH tertentu
    echo -en "Ketik ${BOLD}RESTORE${NC} untuk melanjutkan: "
    read -r confirm

    [ "$confirm" == "RESTORE" ] || { log WARN "Proses restore dibatalkan oleh pengguna."; exit 0; }

    echo -e "${YELLOW}[»] Proses restore dijalankan di background (kebal SIGHUP).${NC}"
    echo -e "${YELLOW}[»] Tekan Ctrl+C kapan saja untuk berhenti memantau —${NC}"
    echo -e "${YELLOW}    proses restore TETAP berjalan di background.${NC}\n"

    # Ekspor variabel yang dibutuhkan worker, lalu lempar ke background
    local escaped_rfile; escaped_rfile=$(printf '%q' "$rfile")
    local escaped_target; escaped_target=$(printf '%q' "$remote_target")

    nohup bash -c "
        source '$SCRIPT_PATH'
        _restore_worker $escaped_rfile $escaped_target
    " >> "$LOG_FILE" 2>&1 &
    local bg_pid=$!
    disown "$bg_pid"

    echo -e "${GREEN}[✓] Worker restore berjalan (PID: ${bg_pid}).${NC}"
    echo -e "${CYAN}[»] Menampilkan log secara langsung (Ctrl+C untuk berhenti memantau)...${NC}\n"

    (
        trap 'exit 0' INT
        tail -f "$LOG_FILE" --pid="$bg_pid" 2>/dev/null \
            || tail -f "$LOG_FILE"
    ) &
    local tail_pid=$!

    wait "$bg_pid" 2>/dev/null || true
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true

    echo -e "\n${GREEN}${BOLD}[✓] Proses restore telah selesai. Cek log untuk detail: $LOG_FILE${NC}"
}

# ─── PENJADWALAN OTOMATIS (CRON) DENGAN KONVERSI TIMEZONE ─────
setup_cron() {
    echo -e "\n${CYAN}${BOLD}═══════ JADWAL BACKUP OTOMATIS ═══════${NC}"

    local server_tz
    server_tz=$(timedatectl show --property=Timezone --value 2>/dev/null \
        || cat /etc/timezone 2>/dev/null \
        || echo "UTC")

    echo -e "  Zona waktu server saat ini : ${BOLD}${server_tz}${NC}"
    echo ""

    local interval_days
    while true; do
        read -rp "Backup setiap berapa hari sekali? (contoh: 1): " interval_days
        [[ "$interval_days" =~ ^[1-9][0-9]*$ ]] && break
        log WARN "Masukan tidak valid. Masukkan angka bulat positif."
    done

    local wib_time
    while true; do
        read -rp "Jam berapa backup dieksekusi? (Format HH:MM, Zona Waktu WIB): " wib_time
        [[ "$wib_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
        log WARN "Format waktu tidak valid. Gunakan format HH:MM (contoh: 02:00)."
    done

    local wib_hour wib_min
    wib_hour=$(echo "$wib_time" | cut -d: -f1 | sed 's/^0//')
    wib_min=$(echo "$wib_time"  | cut -d: -f2 | sed 's/^0//')

    local cron_hour cron_min
    if [ "$server_tz" == "Asia/Jakarta" ] || [ "$server_tz" == "WIB" ]; then
        cron_hour=$wib_hour
        cron_min=$wib_min
        log INFO "Server sudah berada di zona waktu WIB — tidak diperlukan konversi."
    else
        log STEP "Server berada di zona waktu '$server_tz' — mengonversi waktu WIB ke zona waktu server..."

        local offset_seconds
        offset_seconds=$(python3 -c "
import datetime, zoneinfo, sys
try:
    tz = zoneinfo.ZoneInfo('$server_tz')
    now = datetime.datetime.now(tz)
    offset_wib = 7 * 3600
    server_offset = int(now.utcoffset().total_seconds())
    print(server_offset - offset_wib)
except Exception as e:
    sys.exit(1)
" 2>/dev/null) || {
            log WARN "Konversi timezone otomatis gagal — menggunakan waktu WIB secara langsung sebagai fallback."
            offset_seconds=0
        }

        local wib_total_min=$(( wib_hour * 60 + wib_min ))
        local offset_min=$(( offset_seconds / 60 ))
        local server_total_min=$(( (wib_total_min + offset_min + 1440) % 1440 ))

        cron_hour=$(( server_total_min / 60 ))
        cron_min=$(( server_total_min % 60 ))

        log INFO "Waktu WIB ${wib_time} dikonversi menjadi pukul $(printf '%02d:%02d' "$cron_hour" "$cron_min") waktu server ($server_tz)."
    fi

    local cron_day_field="*"
    [ "$interval_days" -gt 1 ] && cron_day_field="*/${interval_days}"

    local expr="${cron_min} ${cron_hour} ${cron_day_field} * *"
    local cron_cmd="bash $SCRIPT_PATH --auto-backup >> $LOG_FILE 2>&1"

    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
    ( crontab -l 2>/dev/null; echo "$expr $cron_cmd" ) | crontab -

    echo ""
    log INFO "Jadwal backup otomatis berhasil dikonfigurasi."
    echo -e "  ${BOLD}Ekspresi Cron${NC}  : ${YELLOW}$expr${NC}"
    echo -e "  ${BOLD}Waktu Eksekusi${NC} : Setiap $interval_days hari, pukul $(printf '%02d:%02d' "$cron_hour" "$cron_min") waktu server ($server_tz)"
    echo -e "  ${BOLD}Verifikasi${NC}     : ${CYAN}crontab -l${NC}"
    echo ""

    echo -e "  ${BOLD}6.${NC} ❌ Hapus jadwal yang ada"
    read -rp "Ketik '6' untuk menghapus jadwal yang ada, atau tekan Enter untuk kembali: " opt
    if [ "${opt:-}" == "6" ]; then
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
        log INFO "Jadwal backup otomatis berhasil dihapus."
    fi
}

# ─── DASBOR STATUS SISTEM ─────────────────────────────────────
show_status() {
    echo -e "\n${CYAN}${BOLD}═══════ STATUS SISTEM ═══════${NC}"

    local node="(belum dikonfigurasi)"
    [ -f "$NODE_CONFIG" ] && node=$(cat "$NODE_CONFIG" 2>/dev/null || echo "(belum dikonfigurasi)")
    echo -e "  Node Server  : ${BOLD}$node${NC}"

    local server_tz
    server_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "Tidak diketahui")
    echo -e "  Zona Waktu   : ${BOLD}$server_tz${NC}"

    {
        if gdrive_is_alive 2>/dev/null; then
            local remote_target; remote_target=$(get_remote_target 2>/dev/null || echo "$REMOTE_NAME:$GDRIVE_FOLDER")
            local count; count=$(rclone lsf "$remote_target" --include "*.tar.gz" 2>/dev/null | wc -l) || count="?"
            echo -e "  Google Drive : ${GREEN}${BOLD}TERHUBUNG ✓${NC} ($count backup tersedia)"
        else
            echo -e "  Google Drive : ${RED}${BOLD}TIDAK TERHUBUNG ✗${NC}"
        fi
    } || echo -e "  Google Drive : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    {
        local disk
        disk=$(df -h "$PTERO_PATH" 2>/dev/null | awk 'NR==2{printf "%s terpakai / %s total (%s)", $3,$2,$5}') || disk="(tidak dapat dibaca)"
        echo -e "  Disk         : ${BOLD}$disk${NC}"
    } || echo -e "  Disk         : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    {
        systemctl is-active --quiet wings 2>/dev/null \
            && echo -e "  Wings        : ${GREEN}${BOLD}BERJALAN ✓${NC}" \
            || echo -e "  Wings        : ${RED}${BOLD}BERHENTI${NC}"
    } || echo -e "  Wings        : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    {
        local cron_entry
        cron_entry=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH" || true)
        if [ -n "$cron_entry" ]; then
            echo -e "  Backup Otomatis : ${GREEN}${BOLD}AKTIF${NC} → $cron_entry"
        else
            echo -e "  Backup Otomatis : ${YELLOW}${BOLD}TIDAK AKTIF${NC}"
        fi
    } || echo -e "  Backup Otomatis : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    # --- INDIKATOR PROSES BACKGROUND ---
    {
        if pgrep -f "_backup_worker" >/dev/null; then
            echo -e "  Aktivitas Saat Ini: ${YELLOW}${BOLD}⏳ BACKUP SEDANG BERJALAN...${NC}"
        elif pgrep -f "_restore_worker" >/dev/null; then
            echo -e "  Aktivitas Saat Ini: ${YELLOW}${BOLD}⏳ RESTORE SEDANG BERJALAN...${NC}"
        else
            echo -e "  Aktivitas Saat Ini: ${GREEN}${BOLD}IDLE (Standby)${NC}"
        fi
    }
    # -----------------------------------

    {
        local last
        last=$(grep "BACKUP SELESAI\|RESTORE SELESAI" "$LOG_FILE" 2>/dev/null | tail -1 || true)
        [ -n "$last" ] && echo -e "  Operasi Terakhir: ${BOLD}$(echo "$last" | cut -d' ' -f1-3)${NC} — $(echo "$last" | cut -d']' -f3-)"
    } || true

    echo ""
}


# ─── BANNER ───────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo -e "╔══════════════════════════════════════════════════╗"
    echo -e "║   👑  BIMXYZ ULTIMATE BACKUP SYSTEM V${VERSION}       ║"
    echo -e "║        Enterprise Grade | Multi-Server Deploy     ║"
    echo -e "╚══════════════════════════════════════════════════╝${NC}"
    echo -e "  ${YELLOW}Log: $LOG_FILE${NC}\n"
}

# ─── MENU UTAMA ───────────────────────────────────────────────
show_menu() {
    echo -e "\n${CYAN}${BOLD}MENU UTAMA:${NC}"
    echo -e "  ${BOLD}1.${NC} 🚀 Jalankan Backup Sekarang"
    echo -e "  ${BOLD}2.${NC} 📥 Pulihkan Backup (Restore)"
    echo -e "  ${BOLD}3.${NC} ⏰ Atur Jadwal Backup Otomatis"
    echo -e "  ${BOLD}4.${NC} 🖥️  Atur / Ubah Nama Node Server"
    echo -e "  ${BOLD}5.${NC} 📊 Lihat Status Sistem"
    echo -e "  ${BOLD}6.${NC} 🔄 Reset Autentikasi Google Drive"
    echo -e "  ${BOLD}7.${NC} 🚪 Keluar"
    echo ""
    read -rp "Pilihan (1-7): " choice

    case "$choice" in
        1) do_backup ;;
        2) do_restore ;;
        3) setup_cron ;;
        4) manage_node_name ;;
        5) show_status ;;
        6)
            rclone config delete "$REMOTE_NAME" 2>/dev/null || true
            rm -f "$CONFIG_DIR/service_account.json" "$FOLDER_ID_CACHE"
            log INFO "Autentikasi berhasil direset. Jalankan skrip kembali untuk mengonfigurasi ulang."
            ;;
        7) exit 0 ;;
        *) log ERROR "Pilihan tidak valid." ;;
    esac
}

# ─── TITIK MASUK UTAMA ────────────────────────────────────────
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

    install_deps
    setup_gdrive

    while true; do
        show_banner
        show_status
        show_menu
        
        echo -e "\n${CYAN}──────────────────────────────────────────────${NC}"
        read -rp "Tekan [ENTER] untuk kembali ke Menu Utama..."
    done
}

main "$@"
