#!/usr/bin/env bash
# sync-bench.sh — Measure whether rclone is feasible at your scale.
#
# Run this on the actual NFS-Client host, against the actual NFS share,
# BEFORE committing to rclone as your production sync layer.
#
# It produces three numbers that determine feasibility:
#
#   1. WALK_TIME_S  : how long rclone takes to list+stat the entire tree
#   2. UPLOAD_MBPS  : effective upload bandwidth to Azure Blob
#   3. RECONCILE_S  : end-to-end sync time of an unchanged tree
#                     (this is your minimum SLA latency floor)
#
# Decision rule of thumb:
#   - If RECONCILE_S  <  your SLA budget * 0.5  → rclone reicht.
#   - If RECONCILE_S  <  SLA budget  but close  → rclone reicht, aber
#                                                  monitor closely.
#   - If RECONCILE_S  >= SLA budget             → custom Tool oder
#                                                  Architektur-Änderung nötig.
#
# Run as the same user that will run the production service.

set -euo pipefail

: "${SRC:=/mnt/nfs/source}"
: "${DST:=azureblob:content}"
: "${RCLONE_CONFIG:=/etc/rclone/rclone.conf}"

if [ ! -d "$SRC" ]; then
  echo "FATAL: SRC=$SRC not a directory" >&2
  exit 1
fi

echo "=== Phase 1: walk-only (no upload, no comparison) ==="
echo "Measures pure NFS stat() throughput."
echo
t0=$EPOCHREALTIME
# rclone size walks + stats but doesn't transfer.
SIZE_OUT=$(rclone size "$SRC" --config "$RCLONE_CONFIG" --fast-list 2>&1)
t1=$EPOCHREALTIME
WALK_TIME_S=$(awk "BEGIN{printf \"%.1f\", $t1 - $t0}")
echo "$SIZE_OUT"
echo "WALK_TIME_S=$WALK_TIME_S"
echo

# Extract counts.
FILE_COUNT=$(printf '%s\n' "$SIZE_OUT" | awk '/Total objects:/ {gsub(",", "", $3); print $3}')
TOTAL_BYTES=$(printf '%s\n' "$SIZE_OUT" | awk '/Total size:/ {print $4}')
echo "FILE_COUNT=$FILE_COUNT  TOTAL_BYTES=$TOTAL_BYTES"
echo
echo "Per-file stat latency: $(awk "BEGIN{printf \"%.2f ms\", ($WALK_TIME_S * 1000) / $FILE_COUNT}")"
echo
echo "=== Phase 2: dry-run sync (walk + compare against Azure, no transfer) ==="
echo "Measures Walk + remote list + diff. This is your reconcile floor when"
echo "nothing has changed."
echo
t0=$EPOCHREALTIME
rclone sync "$SRC" "$DST" \
  --config "$RCLONE_CONFIG" \
  --fast-list --checksum --modify-window 2s \
  --transfers 32 --checkers 32 \
  --dry-run --stats 30s --stats-one-line \
  --log-level INFO 2>&1 | tail -20
t1=$EPOCHREALTIME
RECONCILE_S=$(awk "BEGIN{printf \"%.1f\", $t1 - $t0}")
echo
echo "RECONCILE_S=$RECONCILE_S  (reconcile floor for unchanged tree)"
echo

echo "=== Phase 3: small upload throughput probe ==="
echo "Uploads a 100 MB file 3 times to estimate effective MB/s."
echo
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
dd if=/dev/urandom of="$TMPFILE" bs=1M count=100 status=none

for i in 1 2 3; do
  t0=$EPOCHREALTIME
  rclone copyto "$TMPFILE" "$DST/_bench/probe-$i.bin" \
    --config "$RCLONE_CONFIG" --no-check-dest >/dev/null 2>&1
  t1=$EPOCHREALTIME
  d=$(awk "BEGIN{printf \"%.2f\", $t1 - $t0}")
  mbps=$(awk "BEGIN{printf \"%.1f\", 100 / $d}")
  echo "  probe $i: ${d}s = ${mbps} MB/s"
done

# Cleanup probe blobs.
rclone delete "$DST/_bench/" --config "$RCLONE_CONFIG" >/dev/null 2>&1 || true

echo
echo "=========================================================="
echo "Summary:"
echo "  Files          : $FILE_COUNT"
echo "  Total size     : $TOTAL_BYTES"
echo "  Walk time      : ${WALK_TIME_S}s"
echo "  Reconcile time : ${RECONCILE_S}s  ← Compare this to your SLA"
echo "=========================================================="
