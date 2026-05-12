#!/usr/bin/env bash
# lab.sh — Local test lab for nfs-sync.sh
#
# Simulates a production NFS-sync environment using:
#   Source  : tmpfs mount at /tmp/nfs-lab/mount  (passes mountpoint -q check)
#   Target  : Azurite (Azure Blob emulator) via Podman
#
# Usage:
#   ./lab/lab.sh setup        # start Azurite, mount tmpfs, generate 1000 test files
#   ./lab/lab.sh teardown     # stop everything, unmount, clean up
#   ./lab/lab.sh status       # show current state
#   ./lab/lab.sh run-sync     # run nfs-sync.sh with lab config
#   ./lab/lab.sh run-sync-dry # dry-run (--dry-run flag passed to rclone)
#   ./lab/lab.sh verify       # compare source file count vs objects in Azurite
#   ./lab/lab.sh logs         # tail the most recent sync log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/../rclone/nfs-sync.sh"
LAB_DEFAULTS="$SCRIPT_DIR/lab.defaults"
LAB_RCLONE_CONF="$SCRIPT_DIR/lab.rclone.conf"

LAB_MOUNT="/tmp/nfs-lab/mount"
LAB_LOGS="/tmp/nfs-lab/logs"

AZURITE_NAME="nfs-sync-azurite"
AZURITE_IMAGE="mcr.microsoft.com/azure-storage/azurite"
AZURITE_PORT=10000
BLOB_CONTAINER="lab-content"
SENTINEL=".lab-sentinel"

# -------- Helpers -------------------------------------------------------------

log() { printf '\e[1;34m[lab]\e[0m %s\n' "$*"; }
ok()  { printf '\e[1;32m[ok]\e[0m  %s\n' "$*"; }
err() { printf '\e[1;31m[err]\e[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null || die "required: $1"; }

azurite_running() {
    podman container inspect "$AZURITE_NAME" \
        --format '{{.State.Running}}' 2>/dev/null | grep -q true
}

wait_azurite() {
    local tries=0
    while ! curl -sf "http://127.0.0.1:${AZURITE_PORT}/devstoreaccount1" >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -ge 20 ] && die "Azurite did not start within 10 s"
        sleep 0.5
    done
}

rclone_lab() {
    rclone --config "$LAB_RCLONE_CONF" "$@"
}

# -------- sub: setup ----------------------------------------------------------

cmd_setup() {
    need_cmd podman
    need_cmd rclone
    need_cmd sudo

    # 1. Azurite
    if azurite_running; then
        ok "Azurite already running"
    else
        log "pulling $AZURITE_IMAGE (first run may take a moment)…"
        podman pull -q "$AZURITE_IMAGE"

        log "starting Azurite container…"
        podman run -d \
            --name "$AZURITE_NAME" \
            -p "${AZURITE_PORT}:10000" \
            "$AZURITE_IMAGE" \
            azurite-blob --blobHost 0.0.0.0 --skipApiVersionCheck >/dev/null

        log "waiting for Azurite to accept connections…"
        wait_azurite
        ok "Azurite up on :${AZURITE_PORT}"
    fi

    # 2. tmpfs mount (acts as the "NFS share" — passes mountpoint -q)
    if mountpoint -q "$LAB_MOUNT" 2>/dev/null; then
        ok "tmpfs already mounted at $LAB_MOUNT"
    else
        log "mounting tmpfs at $LAB_MOUNT (needs sudo)…"
        sudo mkdir -p "$LAB_MOUNT"
        sudo mount -t tmpfs -o size=512m tmpfs "$LAB_MOUNT"
        sudo chown "$(id -u):$(id -g)" "$LAB_MOUNT"
        ok "tmpfs mounted at $LAB_MOUNT"
    fi

    mkdir -p "$LAB_LOGS"

    # 3. Sentinel file (preflight guard in nfs-sync.sh)
    touch "$LAB_MOUNT/$SENTINEL"

    # 4. Test data: 1000 files across 4 directory levels
    local file_count
    file_count=$(find "$LAB_MOUNT" -type f -not -name "$SENTINEL" | wc -l)
    if [ "$file_count" -ge 1000 ]; then
        ok "test data already present ($file_count files)"
    else
        log "generating test data (1000 files, 4 directory levels)…"
        gen_testdata
        file_count=$(find "$LAB_MOUNT" -type f -not -name "$SENTINEL" | wc -l)
        ok "generated $file_count files"
    fi

    # 5. Create blob container
    if rclone_lab lsd "lab-azure:" 2>/dev/null | grep -q "$BLOB_CONTAINER"; then
        ok "blob container '$BLOB_CONTAINER' already exists"
    else
        log "creating blob container '$BLOB_CONTAINER'…"
        rclone_lab mkdir "lab-azure:$BLOB_CONTAINER"
        ok "blob container created"
    fi

    printf '\n'
    printf 'Lab ready. MIN_AGE=5s — wait at least 5 s before running sync.\n'
    printf '\n'
    printf '  %s run-sync      # sync source → Azurite\n' "$0"
    printf '  %s run-sync-dry  # dry-run (nothing uploaded)\n' "$0"
    printf '  %s verify        # compare file counts\n' "$0"
    printf '  %s status        # show state\n' "$0"
    printf '  %s teardown      # clean everything up\n' "$0"
}

gen_testdata() {
    # Layout: 5 dirs × 4 subdirs × 4 leaf-dirs = 80 leaf dirs × ~13 files = 1040 files
    # File sizes: 1 KB (most), 50 KB, 500 KB (a few) to test varied payloads.
    # Also creates *.tmp files in a temp/ dir to verify exclude patterns.
    local idx=0
    for l1 in a b c d e; do
        for l2 in 1 2 3 4; do
            for l3 in x y z w; do
                local dir="$LAB_MOUNT/dir-${l1}/sub-${l2}/leaf-${l3}"
                mkdir -p "$dir"
                for f in $(seq -w 1 13); do
                    # Vary file size based on last digit of idx
                    local size=1024
                    case $((idx % 20)) in
                        0) size=512000 ;;   # 500 KB
                        5) size=51200  ;;   # 50 KB
                        *) size=1024   ;;   # 1 KB
                    esac
                    dd if=/dev/urandom bs="$size" count=1 \
                        of="$dir/file-${f}.txt" 2>/dev/null
                    idx=$((idx + 1))
                done
            done
        done
    done

    # Files that must be excluded (*.tmp)
    mkdir -p "$LAB_MOUNT/temp"
    for i in 1 2 3; do
        echo "should not sync" > "$LAB_MOUNT/temp/upload-${i}.tmp"
    done
}

# -------- sub: teardown -------------------------------------------------------

cmd_teardown() {
    log "stopping Azurite…"
    podman rm -f "$AZURITE_NAME" 2>/dev/null && ok "Azurite removed" || ok "Azurite was not running"

    log "unmounting tmpfs…"
    if mountpoint -q "$LAB_MOUNT" 2>/dev/null; then
        sudo umount "$LAB_MOUNT"
        ok "unmounted $LAB_MOUNT"
    else
        ok "$LAB_MOUNT was not mounted"
    fi

    log "removing lab temp dirs…"
    sudo rm -rf /tmp/nfs-lab
    ok "cleaned up /tmp/nfs-lab"
}

# -------- sub: status ---------------------------------------------------------

cmd_status() {
    printf '%-20s %s\n' "Azurite:" "$(azurite_running && echo 'running' || echo 'stopped')"
    printf '%-20s %s\n' "tmpfs mount:" "$(mountpoint -q "$LAB_MOUNT" 2>/dev/null && echo "mounted ($LAB_MOUNT)" || echo 'not mounted')"
    if mountpoint -q "$LAB_MOUNT" 2>/dev/null; then
        local src_files excl_files
        src_files=$(find "$LAB_MOUNT" -type f \
            -not -name "$SENTINEL" \
            -not -name '*.tmp' -not -name '*.swp' \
            -not -name '*.partial' -not -name '*.crdownload' | wc -l)
        excl_files=$(find "$LAB_MOUNT" -type f -name '*.tmp' | wc -l)
        printf '%-20s %s (+ %s excluded *.tmp)\n' "Source files:" "$src_files" "$excl_files"
    fi
    if azurite_running; then
        local blob_count
        blob_count=$(rclone_lab ls "lab-azure:$BLOB_CONTAINER" 2>/dev/null | wc -l || echo "?")
        printf '%-20s %s\n' "Blobs in container:" "$blob_count"
    fi
}

# -------- sub: run-sync -------------------------------------------------------

cmd_run_sync() {
    local dry_run="${1:-}"
    [ -f "$SYNC_SCRIPT" ] || die "$SYNC_SCRIPT not found"
    mountpoint -q "$LAB_MOUNT" || die "tmpfs not mounted — run setup first"
    azurite_running          || die "Azurite not running — run setup first"

    if [ -n "$dry_run" ]; then
        log "dry-run: setting BWLIMIT and injecting --dry-run via wrapper"
        # rclone does not have an env var for --dry-run; we pass it via RCLONE_ARGS
        # nfs-sync.sh does not support extra rclone args directly, so we wrap:
        local tmp_script
        tmp_script=$(mktemp /tmp/nfs-sync-dry.XXXXXX.sh)
        sed 's|rclone "${RC_ARGS\[@\]}"|rclone "${RC_ARGS[@]}" --dry-run|' \
            "$SYNC_SCRIPT" > "$tmp_script"
        chmod +x "$tmp_script"
        env $(grep -v '^#' "$LAB_DEFAULTS" | xargs) bash "$tmp_script"
        rm -f "$tmp_script"
    else
        log "running nfs-sync.sh with lab config (MIN_AGE=5s — sleep 6 s first)…"
        sleep 6
        env $(grep -v '^#' "$LAB_DEFAULTS" | xargs) bash "$SYNC_SCRIPT"
    fi
}

# -------- sub: verify ---------------------------------------------------------

cmd_verify() {
    mountpoint -q "$LAB_MOUNT" || die "tmpfs not mounted"
    azurite_running            || die "Azurite not running"

    local src_files blob_count tmp_count
    src_files=$(find "$LAB_MOUNT" -type f \
        -not -name "$SENTINEL" \
        -not -name '*.tmp' -not -name '*.swp' \
        -not -name '*.partial' -not -name '*.crdownload' | wc -l)
    tmp_count=$(find "$LAB_MOUNT" -type f -name '*.tmp' | wc -l)
    blob_count=$(rclone_lab ls "lab-azure:$BLOB_CONTAINER" 2>/dev/null | wc -l)

    printf 'Source files (excl. excluded patterns): %s\n' "$src_files"
    printf '*.tmp files in source (must NOT sync):  %s\n' "$tmp_count"
    printf 'Objects in Azurite container:           %s\n' "$blob_count"
    printf '\n'

    if [ "$src_files" -eq "$blob_count" ]; then
        ok "counts match — sync is complete"
    elif [ "$blob_count" -eq 0 ]; then
        err "nothing uploaded yet — run: $0 run-sync"
        exit 1
    else
        err "mismatch: $src_files source vs $blob_count blobs"
        exit 1
    fi

    # Spot-check: *.tmp must not appear in Azurite
    local tmp_in_blob
    tmp_in_blob=$(rclone_lab ls "lab-azure:$BLOB_CONTAINER" 2>/dev/null | grep '\.tmp$' | wc -l)
    if [ "$tmp_in_blob" -gt 0 ]; then
        err "FAIL: $tmp_in_blob .tmp files found in Azurite — exclude patterns broken!"
        exit 1
    fi
    ok "no .tmp files in Azurite — exclude patterns work"
}

# -------- sub: logs -----------------------------------------------------------

cmd_logs() {
    local latest
    latest=$(ls -t "$LAB_LOGS"/sync-*.log 2>/dev/null | head -1)
    [ -n "$latest" ] || die "no log files in $LAB_LOGS — run sync first"
    log "tailing $latest"
    tail -40 "$latest"
}

# -------- dispatch ------------------------------------------------------------

CMD="${1:-help}"
case "$CMD" in
    setup)        cmd_setup ;;
    teardown)     cmd_teardown ;;
    status)       cmd_status ;;
    run-sync)     cmd_run_sync ;;
    run-sync-dry) cmd_run_sync dry ;;
    verify)       cmd_verify ;;
    logs)         cmd_logs ;;
    *)
        printf 'Usage: %s setup|teardown|status|run-sync|run-sync-dry|verify|logs\n' "$0"
        exit 1
        ;;
esac
