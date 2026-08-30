#!/bin/bash
set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ─── KONSTANTA ────────────────────────────────────────────────
readonly VERSION="5.1"
readonly REMOTE_NAME="gdrive_bimxyz"
readonly GDRIVE_FOLDER="Backup_Bimxyz"
readonly PTERO_PATH="/var/lib/pterodactyl/volumes"
readonly PTERO_BASE="$(dirname "$PTERO_PATH")"
readonly CONFIG_DIR="/root/.bimxyz"
readonly BACKUP_DIR="/root/bimxyz_backup"
readonly TEMP_DIR="$BACKUP_DIR/.tmp"
readonly NODE_CONFIG="$CONFIG_DIR/node.conf"
readonly LOG_FILE="/var/log/bimxyz_backup.log"
readonly SCRIPT_PATH="$(readlink -f "$0")"
readonly MAX_RETRIES=3
readonly RETENTION_DAYS=3
readonly LIMIT_CPU_QUOTA="50%"
readonly LIMIT_MEM_MAX="300M"

# ─── WARNA ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

# ─── LOGGING ──────────────────────────────────────────────────
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

# ─── PEMBATASAN RESOURCE (CPU & RAM) ──────────────────────────
# Menjalankan sebuah command dengan batas maksimum CPU & RAM,
# supaya node Pterodactyl tetap responsif saat backup berjalan.
run_limited() {
    if command -v systemd-run &>/dev/null && [ -d /sys/fs/cgroup ]; then
        systemd-run --scope --quiet \
            -p CPUQuota="$LIMIT_CPU_QUOTA" \
            -p MemoryMax="$LIMIT_MEM_MAX" \
            -p MemorySwapMax=0 \
            -p IOWeight=10 \
            -p OOMPolicy=continue \
            -- "$@"
        return $?
    fi

    # Fallback jika systemd/cgroup tidak tersedia: nice + ionice + ulimit.
    log WARN "systemd-run tidak tersedia — memakai fallback nice/ionice/ulimit (batas RAM kurang presisi)."
    local nice_prefix="nice -n 19"
    command -v ionice &>/dev/null && nice_prefix="ionice -c3 nice -n 19"
    # ulimit -v dalam KB; LIMIT_MEM_MAX diasumsikan format "<angka>M"
    local mem_kb=$(( ${LIMIT_MEM_MAX%M} * 1024 ))
    $nice_prefix bash -c "ulimit -v $mem_kb; exec \"\$@\"" -- "$@"
}

# ─── INSTALASI DEPENDENSI ─────────────────────────────────────
install_deps() {
    local missing=()
    command -v rclone  &>/dev/null || missing+=("rclone")
    command -v curl    &>/dev/null || missing+=("curl")
    command -v python3 &>/dev/null || missing+=("python3")

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

# ─── SMART SWAP MEMORY & KERNEL OPTIMIZATION ─────────────────
setup_smart_swap() {
    echo -e "\n${CYAN}${BOLD}═══════ MANAJEMEN SWAP & KERNEL OPTIMIZATION ═══════${NC}"

    local current_swap
    current_swap=$(swapon --show --noheadings 2>/dev/null)

    if [ -n "$current_swap" ]; then
        local swap_total; swap_total=$(free -h | awk '/^Swap:/{print $2}')
        local current_swappiness; current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "?")

        echo -e "  ${GREEN}Swap aktif${NC} — Ukuran: ${BOLD}${swap_total}${NC} | vm.swappiness: ${BOLD}${current_swappiness}${NC}"
        swapon --show 2>/dev/null | sed 's/^/    /'
        echo ""
        echo -e "  ${BOLD}1.${NC} ➕ Tambah / Ubah ukuran Swap"
        echo -e "  ${BOLD}2.${NC} 🗑️  Hapus Swap"
        echo -e "  ${BOLD}3.${NC} ⚙️  Optimasi kernel saja (vm.swappiness=10)"
        echo -e "  ${BOLD}4.${NC} ◀️  Kembali ke menu"
        echo ""
        read -rp "Pilihan (1-4): " swap_choice

        case "$swap_choice" in
            1) _create_swap ;;
            2) _delete_swap ;;
            3) _optimize_kernel ;;
            4) return 0 ;;
            *) log ERROR "Pilihan tidak valid." ;;
        esac
    else
        echo -e "  ${YELLOW}Swap belum dikonfigurasi pada sistem ini.${NC}"
        echo ""
        local ram_total; ram_total=$(free -h | awk '/^Mem:/{print $2}')
        local disk_free; disk_free=$(df -h / | awk 'NR==2{print $4}')
        echo -e "  RAM Total       : ${BOLD}${ram_total}${NC}"
        echo -e "  Disk Tersedia   : ${BOLD}${disk_free}${NC}"
        echo ""
        _create_swap
    fi
}

_create_swap() {
    echo -e "\n${CYAN}Berapa GB ukuran Swap yang diinginkan?${NC}"
    echo -e "  ${YELLOW}Rekomendasi: 4-20 GB (sesuaikan dengan kebutuhan)${NC}"
    echo ""

    local swap_size_gb
    while true; do
        read -rp "Ukuran Swap (dalam GB, contoh: 4): " swap_size_gb
        [[ "$swap_size_gb" =~ ^[1-9][0-9]*$ ]] && break
        log WARN "Masukan tidak valid. Masukkan angka bulat positif (dalam GB)."
    done

    local disk_free_mb; disk_free_mb=$(df -m / | awk 'NR==2{print $4}')
    local swap_need_mb=$(( swap_size_gb * 1024 ))
    if [ "$disk_free_mb" -lt "$swap_need_mb" ]; then
        log ERROR "Ruang disk tidak mencukupi. Tersedia: ${disk_free_mb}MB, Diperlukan: ${swap_need_mb}MB."
        return 1
    fi

    if swapon --show --noheadings 2>/dev/null | grep -q "/swapfile"; then
        log STEP "Menonaktifkan swap lama (/swapfile)..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi

    log STEP "Membuat Swap File ${swap_size_gb}GB..."
    dd if=/dev/zero of=/swapfile bs=1G count="$swap_size_gb" status=progress 2>&1 | tail -1
    echo ""
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile

    sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true
    echo "/swapfile none swap sw 0 0" >> /etc/fstab

    log INFO "Swap File ${swap_size_gb}GB berhasil dibuat dan diaktifkan!"
    _optimize_kernel

    echo ""
    echo -e "  ${GREEN}${BOLD}═══ HASIL KONFIGURASI SWAP ═══${NC}"
    free -h | grep -E "Mem:|Swap:" | sed 's/^/    /'
    echo ""
}

_delete_swap() {
    if ! swapon --show --noheadings 2>/dev/null | grep -q "/swapfile"; then
        log WARN "Tidak ada swap file (/swapfile) yang aktif untuk dihapus."
        return 1
    fi

    read -rp "Yakin ingin menghapus swap? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log INFO "Dibatalkan."; return 0; }

    log STEP "Menonaktifkan dan menghapus swap file..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true

    log INFO "Swap berhasil dihapus."
}

_optimize_kernel() {
    log STEP "Mengoptimasi kernel: vm.swappiness=10, vm.vfs_cache_pressure=50..."

    sysctl -w vm.swappiness=10 >/dev/null 2>&1
    if grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^vm.swappiness.*/vm.swappiness=10/' /etc/sysctl.conf
    else
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi

    sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1
    if grep -q "^vm.vfs_cache_pressure" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^vm.vfs_cache_pressure.*/vm.vfs_cache_pressure=50/' /etc/sysctl.conf
    else
        echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    fi

    log INFO "Kernel optimization selesai."
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

# ─── PASTIKAN FOLDER GDRIVE ADA (AUTO-CREATE) ─────────────────
ensure_gdrive_folder() {
    rclone lsf "${REMOTE_NAME}:" 2>/dev/null | grep -q "^${GDRIVE_FOLDER}/$" && return 0
    log STEP "Folder '$GDRIVE_FOLDER' belum ada — membuat folder baru di Google Drive..."
    rclone mkdir "${REMOTE_NAME}:${GDRIVE_FOLDER}" 2>/dev/null \
        || { log ERROR "Gagal membuat folder '$GDRIVE_FOLDER' di Google Drive."; return 1; }
    log INFO "Folder '$GDRIVE_FOLDER' berhasil dibuat."
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
    setup_service_account
}

setup_service_account() {
    echo -e "\n${CYAN}${BOLD}═══════ PENGATURAN GOOGLE DRIVE (SERVICE ACCOUNT) ═══════${NC}"
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
        run_limited rclone "$op" "$@" \
            --progress \
            --transfers=1 \
            --checkers=2 \
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

    # CPU sudah dibatasi oleh cgroup (run_limited), jadi cukup 1 thread pigz
    # agar tidak ada overhead context-switch sia-sia di dalam jatah CPU yang kecil.
    if command -v pigz &>/dev/null; then
        log STEP "Kompresi menggunakan pigz (dibatasi ${LIMIT_CPU_QUOTA} CPU / ${LIMIT_MEM_MAX} RAM)..."
        run_limited tar --use-compress-program="pigz -p 1" \
            -f "$dest" --checkpoint=500 --checkpoint-action=dot \
            -c -C "$src_dir" "$src_name" 2>/dev/null
    else
        log STEP "Kompresi menggunakan gzip standar (dibatasi ${LIMIT_CPU_QUOTA} CPU / ${LIMIT_MEM_MAX} RAM)..."
        run_limited tar -czf "$dest" \
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
    local destf="$BACKUP_DIR/$fname"
    local remote="${REMOTE_NAME}:${GDRIVE_FOLDER}"

    log STEP "=== BACKUP WORKER DIMULAI (PID: $$) ==="
    log STEP "Node: $node | Nama file: $fname"

    [ -d "$PTERO_PATH" ] || { log ERROR "Direktori tidak ditemukan: $PTERO_PATH"; exit 1; }

    mkdir -p "$TEMP_DIR" "$BACKUP_DIR"
    check_disk_space "$PTERO_PATH"
    ensure_gdrive_folder || exit 1

    log STEP "Tujuan remote: $remote"

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
    smart_compress "$PTERO_BASE" "$(basename "$PTERO_PATH")" "$tmpf"
    echo "" >> "$LOG_FILE"
    local elapsed=$(( SECONDS - t0 ))
    local fsize; fsize=$(du -sh "$tmpf" | awk '{print $1}')
    log INFO "Kompresi selesai: ${fsize} dalam ${elapsed} detik."

    log STEP "Mengunggah ke Google Drive ($remote)..."
    rclone_retry copy "$tmpf" "$remote" \
        || { log ERROR "Pengunggahan gagal setelah $MAX_RETRIES percobaan."; exit 1; }

    mv "$tmpf" "$destf"
    log INFO "Backup disimpan lokal: $destf"

    if $wings_was_running; then
        log STEP "Menjalankan kembali Wings..."
        systemctl start wings 2>/dev/null && sleep 3
        systemctl is-active --quiet wings 2>/dev/null \
            && log INFO "Wings kembali berjalan." \
            || log WARN "Wings gagal dijalankan — periksa dengan: systemctl status wings"
    fi

    log STEP "Menghapus backup lokal yang lebih lama dari ${RETENTION_DAYS} hari..."
    find "$BACKUP_DIR" -maxdepth 1 -name "${node}_*.tar.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true

    log STEP "Menghapus backup lama di Google Drive (menyisakan hanya backup yang baru saja diunggah)..."
    local old_remote_files
    old_remote_files=$(rclone lsf "$remote" --include "${node}_*.tar.gz" 2>/dev/null | grep -v "^${fname}$" || true)
    if [ -n "$old_remote_files" ]; then
        while IFS= read -r oldf; do
            [ -z "$oldf" ] && continue
            rclone deletefile "${remote}/${oldf}" 2>/dev/null \
                && log INFO "Backup lama dihapus dari Drive: $oldf" \
                || log WARN "Gagal menghapus backup lama di Drive: $oldf"
        done <<< "$old_remote_files"
    else
        log INFO "Tidak ada backup lama untuk node ini di Google Drive."
    fi

    log INFO "========================================"
    log INFO "  ✅  BACKUP BERHASIL!"
    log INFO "  Node  : $node"
    log INFO "  File  : $fname"
    log INFO "  Ukuran: $fsize"
    log INFO "  Lokal : $destf"
    log INFO "  Drive : $remote"
    log INFO "========================================"
    log INFO "BACKUP SELESAI: $fname ($fsize)"
}

# ─── PROSES BACKUP (dengan SIGHUP-proof background execution) ─
do_backup() {
    echo -e "\n${CYAN}${BOLD}═══════ PROSES BACKUP ═══════${NC}"
    echo -e "${YELLOW}[»] Proses backup dijalankan di background (kebal SIGHUP).${NC}"
    echo -e "${YELLOW}[»] Pantau progress melalui log di bawah ini.${NC}"
    echo -e "${YELLOW}[»] Tekan Ctrl+C kapan saja untuk berhenti memantau —${NC}"
    echo -e "${YELLOW}    proses backup TETAP berjalan di background.${NC}\n"

    nohup bash "$SCRIPT_PATH" --run-worker-backup >> "$LOG_FILE" 2>&1 &
    local bg_pid=$!
    disown "$bg_pid"

    echo -e "${GREEN}[✓] Worker backup berjalan (PID: ${bg_pid}).${NC}"
    echo -e "${CYAN}[»] Menampilkan log secara langsung (Ctrl+C untuk berhenti memantau)...${NC}\n"

    trap - INT
    tail -f "$LOG_FILE" --pid="$bg_pid" 2>/dev/null \
        || tail -f "$LOG_FILE"
    trap 'log ERROR "Proses dibatalkan oleh pengguna."; exit 130' INT TERM

    echo -e "\n${GREEN}${BOLD}[✓] Proses backup telah selesai. Cek log untuk detail: $LOG_FILE${NC}"
}

# ─── LOGIKA INTI RESTORE (dijalankan di background) ──────────
_restore_worker() {
    local rfile="$1"
    local remote="${REMOTE_NAME}:${GDRIVE_FOLDER}"

    log STEP "=== RESTORE WORKER DIMULAI (PID: $$) ==="

    mkdir -p "$TEMP_DIR"
    local local_file="$TEMP_DIR/$rfile"

    log STEP "Mengunduh file: $rfile dari $remote"
    rclone_retry copy --include "$rfile" "$remote" "$TEMP_DIR/" \
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
        -C "$PTERO_BASE" 2>/dev/null
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

    log STEP "Membersihkan snapshot lama (menyisakan 2 snapshot terbaru)..."
    ls -1dt /root/volumes_snapshot_* 2>/dev/null | tail -n +3 | xargs -r rm -rf

    log INFO "========================================"
    log INFO "  ✅  RESTORE BERHASIL!"
    log INFO "  File     : $rfile"
    log INFO "  Snapshot : $snap"
    log INFO "========================================"
    log INFO "RESTORE SELESAI: $rfile"
}

# ─── PROSES RESTORE (dengan SIGHUP-proof background execution) ─
do_restore() {
    echo -e "\n${CYAN}${BOLD}═══════ PROSES RESTORE ═══════${NC}"
    log STEP "Mengambil daftar backup dari Google Drive..."

    local remote="${REMOTE_NAME}:${GDRIVE_FOLDER}"
    local list
    list=$(rclone lsf "$remote" --include "*.tar.gz" 2>/dev/null | sort -r) || true

    [ -z "$list" ] && { log ERROR "Tidak ada backup yang tersedia di Google Drive."; exit 1; }

    echo -e "\n${YELLOW}${BOLD}Daftar Backup yang Tersedia:${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────${NC}"

    local -a files
    local i=1
    while IFS= read -r f; do
        files+=("$f")
        local sz
        sz=$(rclone size "${remote}/$f" --json 2>/dev/null \
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

    echo -en "Ketik ${BOLD}RESTORE${NC} untuk melanjutkan: "
    read -r confirm

    [ "$confirm" == "RESTORE" ] || { log WARN "Proses restore dibatalkan oleh pengguna."; exit 0; }

    echo -e "${YELLOW}[»] Proses restore dijalankan di background (kebal SIGHUP).${NC}"
    echo -e "${YELLOW}[»] Tekan Ctrl+C kapan saja untuk berhenti memantau —${NC}"
    echo -e "${YELLOW}    proses restore TETAP berjalan di background.${NC}\n"

    nohup bash "$SCRIPT_PATH" --run-worker-restore "$rfile" >> "$LOG_FILE" 2>&1 &
    local bg_pid=$!
    disown "$bg_pid"

    echo -e "${GREEN}[✓] Worker restore berjalan (PID: ${bg_pid}).${NC}"
    echo -e "${CYAN}[»] Menampilkan log secara langsung (Ctrl+C untuk berhenti memantau)...${NC}\n"

    trap - INT
    tail -f "$LOG_FILE" --pid="$bg_pid" 2>/dev/null \
        || tail -f "$LOG_FILE"
    trap 'log ERROR "Proses dibatalkan oleh pengguna."; exit 130' INT TERM

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

    echo -e "  ${BOLD}1.${NC} Interval per JAM (contoh: setiap 6 jam) — lebih akurat untuk backup sering"
    echo -e "  ${BOLD}2.${NC} Interval per HARI, pada jam tertentu (WIB)"
    echo ""
    local mode
    while true; do
        read -rp "Pilih mode jadwal (1/2): " mode
        [[ "$mode" == "1" || "$mode" == "2" ]] && break
        log WARN "Pilihan tidak valid. Masukkan 1 atau 2."
    done

    local expr summary_text

    if [ "$mode" == "1" ]; then
        local interval_hours
        while true; do
            read -rp "Backup setiap berapa jam sekali? (contoh: 6, harus habis dibagi 24): " interval_hours
            [[ "$interval_hours" =~ ^[1-9][0-9]*$ ]] && [ "$interval_hours" -le 24 ] && break
            log WARN "Masukan tidak valid. Masukkan angka bulat positif antara 1-24."
        done

        expr="0 */${interval_hours} * * *"
        local cron_cmd="bash $SCRIPT_PATH --auto-backup >> $LOG_FILE 2>&1"

        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
        ( crontab -l 2>/dev/null; echo "$expr $cron_cmd" ) | crontab -

        summary_text="Setiap $interval_hours jam sekali (waktu server: $server_tz)"
    else
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

        expr="${cron_min} ${cron_hour} ${cron_day_field} * *"
        local cron_cmd="bash $SCRIPT_PATH --auto-backup >> $LOG_FILE 2>&1"

        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
        ( crontab -l 2>/dev/null; echo "$expr $cron_cmd" ) | crontab -

        summary_text="Setiap $interval_days hari, pukul $(printf '%02d:%02d' "$cron_hour" "$cron_min") waktu server ($server_tz)"
    fi

    echo ""
    log INFO "Jadwal backup otomatis berhasil dikonfigurasi."
    echo -e "  ${BOLD}Ekspresi Cron${NC}  : ${YELLOW}$expr${NC}"
    echo -e "  ${BOLD}Waktu Eksekusi${NC} : $summary_text"
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
            local count
            count=$(rclone lsf "${REMOTE_NAME}:${GDRIVE_FOLDER}" --include "*.tar.gz" 2>/dev/null | wc -l) || count="?"
            echo -e "  Google Drive : ${GREEN}${BOLD}TERHUBUNG ✓${NC} ($count backup tersedia di '$GDRIVE_FOLDER')"
        else
            echo -e "  Google Drive : ${RED}${BOLD}TIDAK TERHUBUNG ✗${NC}"
        fi
    } || echo -e "  Google Drive : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    {
        local disk
        disk=$(df -h "$PTERO_PATH" 2>/dev/null | awk 'NR==2{printf "%s terpakai / %s total (%s)", $3,$2,$5}') || disk="(tidak dapat dibaca)"
        echo -e "  Disk         : ${BOLD}$disk${NC}"
    } || echo -e "  Disk         : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

    # Swap info
    {
        local swap_info
        swap_info=$(free -h | awk '/^Swap:/{printf "%s terpakai / %s total", $3, $2}')
        if [ "$(free | awk '/^Swap:/{print $2}')" -gt 0 ] 2>/dev/null; then
            echo -e "  Swap         : ${GREEN}${BOLD}AKTIF${NC} ($swap_info) | swappiness=$(cat /proc/sys/vm/swappiness)"
        else
            echo -e "  Swap         : ${YELLOW}${BOLD}TIDAK AKTIF${NC}"
        fi
    } || echo -e "  Swap         : ${YELLOW}${BOLD}PEMERIKSAAN GAGAL${NC}"

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

    {
        if pgrep -f "_backup_worker" >/dev/null; then
            echo -e "  Aktivitas Saat Ini: ${YELLOW}${BOLD}⏳ BACKUP SEDANG BERJALAN...${NC}"
        elif pgrep -f "_restore_worker" >/dev/null; then
            echo -e "  Aktivitas Saat Ini: ${YELLOW}${BOLD}⏳ RESTORE SEDANG BERJALAN...${NC}"
        else
            echo -e "  Aktivitas Saat Ini: ${GREEN}${BOLD}IDLE (Standby)${NC}"
        fi
    }

    {
        local last
        last=$(grep "BACKUP SELESAI\|RESTORE SELESAI" "$LOG_FILE" 2>/dev/null | tail -1 || true)
        [ -n "$last" ] && echo -e "  Operasi Terakhir: ${BOLD}$(echo "$last" | cut -d' ' -f1-3)${NC} — $(echo "$last" | cut -d']' -f3-)"
    } || true

    {
        local local_count
        local_count=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l) || local_count="?"
        echo -e "  Backup Lokal : ${BOLD}$local_count file di $BACKUP_DIR${NC}"
    } || true

    echo ""
}

# ─── BANNER ───────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo -e "╔══════════════════════════════════════════════════╗"
    echo -e "║   👑  BIMXYZ BACKUP SYSTEM V${VERSION}                ║"
    echo -e "║        Pterodactyl Node Auto-Backup               ║"
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
    echo -e "  ${BOLD}7.${NC} 💾 Manajemen Swap & Kernel"
    echo -e "  ${BOLD}8.${NC} 🚪 Keluar"
    echo ""
    read -rp "Pilihan (1-8): " choice

    case "$choice" in
        1) do_backup ;;
        2) do_restore ;;
        3) setup_cron ;;
        4) manage_node_name ;;
        5) show_status ;;
        6)
            rclone config delete "$REMOTE_NAME" 2>/dev/null || true
            rm -f "$CONFIG_DIR/service_account.json"
            log INFO "Autentikasi berhasil direset. Jalankan skrip kembali untuk mengonfigurasi ulang."
            ;;
        7) setup_smart_swap ;;
        8) exit 0 ;;
        *) log ERROR "Pilihan tidak valid." ;;
    esac
}

# ─── TITIK MASUK UTAMA ────────────────────────────────────────
main() {
    check_root
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"

    if [ "${1:-}" == "--auto-backup" ]; then
        log INFO "=== BACKUP OTOMATIS DIMULAI (CRON) ==="
        install_deps
        setup_gdrive
        _backup_worker
        exit 0
    fi

    if [ "${1:-}" == "--run-worker-backup" ]; then
        _backup_worker
        exit 0
    fi

    if [ "${1:-}" == "--run-worker-restore" ]; then
        _restore_worker "$2"
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
