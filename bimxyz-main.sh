#!/bin/bash
# ╔═══════════════════════════════════════════════════════════╗
# ║     BIMXYZ ULTIMATE BACKUP SYSTEM V4.1                   ║
# ║     Production Grade | Multi-Server | Auto-Retry         ║
# ║     Optimized: Folder-ID Detection, Safe Pipefail,       ║
# ║                Smart Compression, Auto-Repair Config      ║
# ╚═══════════════════════════════════════════════════════════╝

# [FIX #2] — Jangan gunakan set -e mentah. Gunakan -uo pipefail saja.
# Error handling per-perintah kritis lebih aman daripada set -e global
# yang bisa membunuh script hanya karena grep tidak menemukan hasil.
set -uo pipefail

# ─── CONSTANTS ───────────────────────────────────────────────
readonly VERSION="4.1"
readonly REMOTE_NAME="gdrive_bimxyz"
readonly GDRIVE_FOLDER="Backup_Bimxyz"
readonly PTERO_PATH="/var/lib/pterodactyl/volumes"
readonly CONFIG_DIR="/root/.bimxyz"
readonly TEMP_DIR="/root/.bimxyz_temp"
readonly NODE_CONFIG="$CONFIG_DIR/node.conf"
readonly FOLDER_ID_CACHE="$CONFIG_DIR/gdrive_folder_id.cache"  # [FIX #1] Cache Folder ID
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

# ─── CLEANUP ─────────────────────────────────────────────────
cleanup() {
    local code=$?
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    [ $code -ne 0 ] && log ERROR "Terminated (exit $code) — cek: $LOG_FILE"
}
trap cleanup EXIT
trap 'log ERROR "Interrupted!"; exit 130' INT TERM

# ─── ROOT CHECK ──────────────────────────────────────────────
check_root() {
    [ "$EUID" -eq 0 ] && return
    echo -e "${RED}[✗] Harus root. Jalankan: sudo bash $0${NC}"
    exit 1
}

# ─── DEPENDENCIES ────────────────────────────────────────────
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

# ─── AUTO-REPAIR CONFIG [FIX #5] ─────────────────────────────
# Jika rclone.conf hilang/tidak ada remote, tapi service_account.json
# masih ada di CONFIG_DIR, lakukan auto-config ulang secara silent.
auto_repair_rclone_config() {
    local sa_file="$CONFIG_DIR/service_account.json"

    # Sudah ada remote yang valid — tidak perlu repair
    if rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
        return 0
    fi

    # Tidak ada SA file — tidak bisa auto-repair
    [ -f "$sa_file" ] || return 1

    log WARN "Remote '$REMOTE_NAME' hilang dari rclone.conf — mencoba auto-repair..."

    # Validasi JSON dulu sebelum dipakai
    if ! python3 -c "import json,sys; json.load(open('$sa_file'))" 2>/dev/null; then
        log ERROR "service_account.json tidak valid — auto-repair dibatalkan"
        return 1
    fi

    rclone config create "$REMOTE_NAME" drive \
        service_account_file="$sa_file" \
        scope=drive \
        --non-interactive >/dev/null 2>&1 || {
        log ERROR "Auto-repair gagal membuat remote"
        return 1
    }

    log INFO "Auto-repair rclone config berhasil (dari service_account.json)"
    return 0
}

# ─── RESOLVE GDRIVE FOLDER ID [FIX #1] ───────────────────────
# Masalah utama Exit 3: rclone lsd hanya mencari di Root Drive.
# Folder yang di-share via "Shared with me" tidak akan terdeteksi.
# Solusi: Gunakan rclone backend 'find' untuk mencari Folder ID,
# kemudian cache ID-nya agar tidak perlu query ulang setiap run.
resolve_gdrive_folder_id() {
    # Gunakan cache jika masih valid (< 24 jam)
    if [ -f "$FOLDER_ID_CACHE" ]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c %Y "$FOLDER_ID_CACHE" 2>/dev/null || echo 0) ))
        if [ "$cache_age" -lt 86400 ]; then
            cat "$FOLDER_ID_CACHE"
            return 0
        fi
    fi

    log STEP "Mencari Folder ID untuk '$GDRIVE_FOLDER' (Root + Shared with me)..."

    local folder_id=""

    # Metode 1: Cari di Root Drive dulu (paling cepat)
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

    # Metode 2: Cari di 'Shared with me' jika tidak ditemukan di Root
    if [ -z "$folder_id" ]; then
        log STEP "Tidak ada di Root — mencari di 'Shared with me'..."
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
        # Metode 3 (fallback): Buat folder baru di Root Drive
        log WARN "Folder '$GDRIVE_FOLDER' tidak ditemukan — membuat folder baru di Root..."
        rclone mkdir "$REMOTE_NAME:$GDRIVE_FOLDER" 2>/dev/null || {
            log ERROR "Gagal membuat folder '$GDRIVE_FOLDER' di GDrive"
            return 1
        }
        # Query lagi setelah dibuat
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
        log ERROR "Gagal resolve Folder ID untuk '$GDRIVE_FOLDER'"
        return 1
    fi

    # Simpan ke cache
    echo "$folder_id" > "$FOLDER_ID_CACHE"
    log INFO "Folder ID ditemukan: $folder_id (di-cache)"
    echo "$folder_id"
}

# Helper: bangun remote path berdasarkan Folder ID jika tersedia
# Menggunakan format --drive-root-folder-id agar tidak tergantung path string
get_remote_target() {
    local folder_id
    folder_id=$(resolve_gdrive_folder_id 2>/dev/null || echo "")
    if [ -n "$folder_id" ]; then
        # Pakai ID langsung — ini bypass masalah "Shared with me" sepenuhnya
        echo "$REMOTE_NAME:{$folder_id}"
    else
        # Fallback ke path string biasa
        echo "$REMOTE_NAME:$GDRIVE_FOLDER"
    fi
}

# ─── GDRIVE SETUP ────────────────────────────────────────────
gdrive_is_alive() {
    # [FIX #2] Jangan biarkan ini membunuh script via set -e
    # Setiap sub-perintah sudah di-handle dengan || false secara eksplisit
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$" || return 1
    rclone lsd "$REMOTE_NAME:" &>/dev/null || return 1
    return 0
}

setup_gdrive() {
    # [FIX #5] Coba auto-repair dulu sebelum minta setup manual
    auto_repair_rclone_config || true

    if gdrive_is_alive; then
        log INFO "GDrive terhubung ✓"
        return 0
    fi

    # Hapus remote rusak
    rclone config delete "$REMOTE_NAME" 2>/dev/null || true
    # Invalidasi cache Folder ID jika remote direset
    rm -f "$FOLDER_ID_CACHE"

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
    log INFO "Service Account berhasil dikonfigurasi"
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

# ─── NODE NAME ───────────────────────────────────────────────
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

# ─── DISK SPACE CHECK ────────────────────────────────────────
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

# ─── RCLONE WITH RETRY ───────────────────────────────────────
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
        (( attempt++ )) || true
    done
    log ERROR "Gagal setelah $MAX_RETRIES attempts"
    return 1
}

# ─── SMART COMPRESSION [FIX #4] ──────────────────────────────
# Gunakan 'nice' untuk menurunkan prioritas CPU proses tar.
# Deteksi jumlah CPU core; jika tersedia pigz, gunakan --use-compress-program
# untuk parallel compression. Fallback ke gzip single-thread jika pigz tidak ada.
smart_compress() {
    local src_dir="$1"    # direktori parent (-C target)
    local src_name="$2"   # nama relatif yang dikompress
    local dest="$3"       # path output .tar.gz

    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)

    # Turunkan prioritas CPU agar tidak mengganggu proses lain (nice=10)
    # ionice -c3 = idle I/O class (jika tersedia)
    local nice_prefix="nice -n 10"
    if command -v ionice &>/dev/null; then
        nice_prefix="ionice -c3 nice -n 10"
    fi

    if command -v pigz &>/dev/null; then
        # pigz: parallel gzip — gunakan setengah CPU agar tidak monopoli
        local threads=$(( cpu_count / 2 ))
        [ "$threads" -lt 1 ] && threads=1
        log STEP "Kompresi parallel (pigz, $threads threads, nice=10)..."
        $nice_prefix tar \
            --use-compress-program="pigz -p $threads" \
            -f "$dest" \
            --checkpoint=500 \
            --checkpoint-action=dot \
            -c -C "$src_dir" "$src_name" 2>/dev/null
    else
        # Fallback: gzip single-thread dengan nice
        log STEP "Kompresi gzip standard (nice=10)..."
        $nice_prefix tar \
            -czf "$dest" \
            --checkpoint=500 \
            --checkpoint-action=dot \
            -C "$src_dir" "$src_name" 2>/dev/null
    fi
}

# ─── BACKUP ──────────────────────────────────────────────────
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

    # Resolve remote target (dengan Folder ID jika tersedia)
    local remote_target
    remote_target=$(get_remote_target)
    log STEP "Remote target: $remote_target"

    # Compress — [FIX #4] Smart compression dengan nice + pigz jika ada
    local t0=$SECONDS
    smart_compress "/var/lib/pterodactyl" "volumes" "$tmpf"
    echo ""
    local elapsed=$(( SECONDS - t0 ))
    local fsize; fsize=$(du -sh "$tmpf" | awk '{print $1}')
    log INFO "Kompresi selesai: ${fsize} dalam ${elapsed}s"

    # Upload — [FIX #1] Gunakan remote_target (Folder ID aware)
    log STEP "Upload ke Google Drive..."
    rclone_retry copy "$tmpf" "$remote_target" \
        || { log ERROR "Upload gagal!"; exit 1; }

    rm -f "$tmpf"

    # Retention cleanup — [FIX #2] || true sudah ada, tapi pastikan eksplisit
    log STEP "Hapus backup >${RETENTION_DAYS} hari..."
    rclone delete "$remote_target" \
        --min-age "${RETENTION_DAYS}d" \
        --include "${node}_*.tar.gz" 2>/dev/null || true

    echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════╗"
    echo -e "║       ✅ BACKUP SUKSES! GACOR!        ║"
    echo -e "╠══════════════════════════════════════╣"
    echo -e "║${NC} Node  : ${BOLD}$node${NC}"
    echo -e "${GREEN}${BOLD}║${NC} File  : ${BOLD}$fname${NC}"
    echo -e "${GREEN}${BOLD}║${NC} Size  : ${BOLD}$fsize${NC}"
    echo -e "${GREEN}${BOLD}║${NC} Drive : ${BOLD}$remote_target${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"

    log INFO "BACKUP COMPLETE: $fname ($fsize)"
}

# ─── RESTORE ─────────────────────────────────────────────────
do_restore() {
    echo -e "\n${CYAN}${BOLD}═══════ RESTORE MODE ═══════${NC}"
    log STEP "Mengambil daftar backup dari GDrive..."

    # [FIX #1] Gunakan remote_target yang Folder ID aware
    local remote_target
    remote_target=$(get_remote_target)

    # [FIX #2] Jangan biarkan kegagalan lsf membunuh script
    local list
    list=$(rclone lsf "$remote_target" --include "*.tar.gz" 2>/dev/null | sort -r) || true

    [ -z "$list" ] && { log ERROR "Tidak ada backup di GDrive! (target: $remote_target)"; exit 1; }

    echo -e "\n${YELLOW}${BOLD}Daftar Backup:${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────${NC}"

    local -a files
    local i=1
    while IFS= read -r f; do
        files+=("$f")
        local sz
        # [FIX #2] Jangan biarkan kegagalan size query membunuh script
        sz=$(rclone size "$remote_target/$f" --json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); mb=d['bytes']//1024//1024; print(f'{mb}MB')" \
            2>/dev/null || echo "?") || sz="?"
        echo -e "  ${BOLD}[$i]${NC} $f ${YELLOW}($sz)${NC}"
        (( i++ )) || true
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
    rclone_retry copy "$remote_target/$rfile" "$TEMP_DIR/" \
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

# ─── CRON SCHEDULER ──────────────────────────────────────────
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

    # Hapus entry lama dulu — [FIX #2] || true eksplisit
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

# ─── STATUS DASHBOARD [FIX #3] ───────────────────────────────
# Setiap blok pengecekan dijalankan secara independen dengan || true
# sehingga error di satu blok tidak mencegah blok lain tampil.
show_status() {
    echo -e "\n${CYAN}${BOLD}═══════ SYSTEM STATUS ═══════${NC}"

    # Node name — aman, tidak bisa gagal
    local node="(belum diset)"
    [ -f "$NODE_CONFIG" ] && node=$(cat "$NODE_CONFIG" 2>/dev/null || echo "(belum diset)")
    echo -e "  Node       : ${BOLD}$node${NC}"

    # GDrive status — blok independen, tidak bunuh dashboard jika error
    {
        if gdrive_is_alive 2>/dev/null; then
            local remote_target; remote_target=$(get_remote_target 2>/dev/null || echo "$REMOTE_NAME:$GDRIVE_FOLDER")
            local count
            # [FIX #2] grep pada output kosong tidak boleh kill script
            count=$(rclone lsf "$remote_target" --include "*.tar.gz" 2>/dev/null | wc -l) || count="?"
            echo -e "  GDrive     : ${GREEN}${BOLD}CONNECTED ✓${NC} ($count backups)"
        else
            echo -e "  GDrive     : ${RED}${BOLD}DISCONNECTED ✗${NC}"
        fi
    } || echo -e "  GDrive     : ${YELLOW}${BOLD}CEK GAGAL${NC}"

    # Disk usage — blok independen
    {
        local disk
        disk=$(df -h "$PTERO_PATH" 2>/dev/null | awk 'NR==2{printf "%s used / %s total (%s)", $3,$2,$5}') \
            || disk="(tidak dapat dibaca)"
        echo -e "  Disk       : ${BOLD}$disk${NC}"
    } || echo -e "  Disk       : ${YELLOW}${BOLD}CEK GAGAL${NC}"

    # Wings status — blok independen
    {
        if systemctl is-active --quiet wings 2>/dev/null; then
            echo -e "  Wings      : ${GREEN}${BOLD}RUNNING ✓${NC}"
        else
            echo -e "  Wings      : ${RED}${BOLD}STOPPED${NC}"
        fi
    } || echo -e "  Wings      : ${YELLOW}${BOLD}CEK GAGAL${NC}"

    # Cron status — [FIX #2] grep tidak boleh membunuh script jika tidak ada hasil
    {
        local cron_entry
        cron_entry=$(crontab -l 2>/dev/null | grep "/usr/local/bin/bimxyz" || true)
        if [ -n "$cron_entry" ]; then
            echo -e "  Auto-Backup: ${GREEN}${BOLD}AKTIF${NC} → $cron_entry"
        else
            echo -e "  Auto-Backup: ${YELLOW}${BOLD}TIDAK AKTIF${NC}"
        fi
    } || echo -e "  Auto-Backup: ${YELLOW}${BOLD}CEK GAGAL${NC}"

    # Last operation — [FIX #2] grep tidak boleh membunuh script
    {
        local last
        last=$(grep "BACKUP COMPLETE\|RESTORE COMPLETE" "$LOG_FILE" 2>/dev/null | tail -1 || true)
        [ -n "$last" ] && echo -e "  Last Op    : ${BOLD}$(echo "$last" | cut -d' ' -f1-3)${NC} — $(echo "$last" | cut -d']' -f3-)"
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

# ─── MENU ────────────────────────────────────────────────────
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
            rm -f "$FOLDER_ID_CACHE"   # Invalidasi cache Folder ID
            log INFO "Auth direset. Jalankan ulang."
            ;;
        6) exit 0 ;;
        *) log ERROR "Pilihan tidak valid" ;;
    esac
}

# ─── ENTRY POINT ─────────────────────────────────────────────
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
