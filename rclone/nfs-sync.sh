#!/usr/bin/env bash
# nfs-sync.sh — One-shot NFS → Object Store reconcile, hardened for 1M+ files.
#
# Designed to be invoked by the systemd timer (see sync.timer / sync.service).
# Idempotent: safe to re-run. Persistent log per run with timing breakdown.
#
# Works with any rclone backend (Azure Blob, S3, GCS, B2, SFTP, …).
# Backend-specific tuning (chunk_size, upload_concurrency, …) belongs in
# rclone.conf, not here.
#
# Strategy:
#   1. Pre-flight: verify NFS mount is mounted AND readable.
#   2. Acquire flock so two timer ticks can't overlap.
#   3. rclone sync with:
#        --fast-list              : single listing call where supported
#        --checksum               : compare checksums not just mtime (NFS races)
#        --min-age 30s            : quiescence filter (skip files just touched)
#        --transfers 32           : parallel uploads
#        --checkers 32            : parallel stat / hash checks
#        --use-mmap               : zero-copy reads of large files
#        --modify-window $MODIFY_WINDOW : mtime tolerance (2s suits NFS)
#   4. Tee output to a rotating per-run log; emit summary metrics.
#
# Exit codes:
#   0  : success
#   1  : preflight failed (mount missing)
#   2  : another sync still running (flock contention) — NOT an error
#   3+ : rclone error (preserved)

set -euo pipefail

# -------- Configuration (override via /etc/default/nfs-sync) ----------------
: "${SRC:=/mnt/nfs/source}"
: "${DST:=remote:bucket}"
: "${RCLONE_CONFIG:=/etc/rclone/rclone.conf}"
: "${LOG_DIR:=/var/log/nfs-sync}"
: "${LOCK_FILE:=/var/run/nfs-sync.lock}"
: "${TRANSFERS:=32}"
: "${CHECKERS:=32}"
: "${MIN_AGE:=30s}"
: "${MOUNT_CHECK_FILE:=}"     # optional sentinel file inside SRC to verify
: "${EXCLUDE_PATTERNS:=*.tmp,*.swp,.~lock*,*.partial,.git/**,*.crdownload}"
: "${MODIFY_WINDOW:=2s}"        # mtime tolerance; 2s suits NFS, 0 for local/exact backends
: "${BWLIMIT:=}"               # e.g. "100M" to cap to 100 MB/s, "" = unlimited

[ -f /etc/default/nfs-sync ] && . /etc/default/nfs-sync

mkdir -p "$LOG_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/sync-$RUN_ID.log"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE" >&2; }

# -------- Preflight ---------------------------------------------------------
preflight() {
  if ! mountpoint -q "$SRC"; then
    log "FATAL: $SRC is not a mountpoint"
    exit 1
  fi
  if [ -n "$MOUNT_CHECK_FILE" ] && [ ! -e "$SRC/$MOUNT_CHECK_FILE" ]; then
    log "FATAL: sentinel $SRC/$MOUNT_CHECK_FILE missing — NFS likely stale"
    exit 1
  fi
  if ! command -v rclone >/dev/null; then
    log "FATAL: rclone not in PATH"
    exit 1
  fi
}

# -------- Build rclone arg list --------------------------------------------
build_args() {
  local args=(
    sync
    "$SRC" "$DST"
    --config "$RCLONE_CONFIG"
    --fast-list
    --checksum
    --modify-window "$MODIFY_WINDOW"
    --min-age "$MIN_AGE"
    --transfers "$TRANSFERS"
    --checkers "$CHECKERS"
    --use-mmap
    --retries 5
    --retries-sleep 10s
    --low-level-retries 20
    --stats 30s
    --stats-one-line
    --log-format date,time,UTC
    --log-level INFO
  )

  # Pattern excludes (comma-separated → --exclude per item).
  IFS=',' read -r -a patterns <<< "$EXCLUDE_PATTERNS"
  for p in "${patterns[@]}"; do
    [ -n "$p" ] && args+=(--exclude "$p")
  done

  [ -n "$BWLIMIT" ] && args+=(--bwlimit "$BWLIMIT")

  printf '%s\n' "${args[@]}"
}

# -------- Main --------------------------------------------------------------
main() {
  log "run_id=$RUN_ID src=$SRC dst=$DST"
  preflight

  # Acquire lock; if another instance is running, exit 2 (success-like).
  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    log "another sync in progress; skipping this tick"
    exit 2
  fi

  log "starting rclone sync"
  local start_s=$EPOCHSECONDS

  mapfile -t RC_ARGS < <(build_args)
  if rclone "${RC_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
    local end_s=$EPOCHSECONDS
    log "OK duration_s=$((end_s - start_s))"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$LOG_DIR/.last-ok"
  else
    local rc=${PIPESTATUS[0]}
    log "FAIL rc=$rc"
    exit $((10 + rc))
  fi
}

main "$@"
