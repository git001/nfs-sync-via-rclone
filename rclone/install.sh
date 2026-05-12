#!/usr/bin/env bash
# install.sh — Deploy the nfs-sync files to their production paths.
#
# Run as root on the target host:
#   sudo ./install.sh
#
# Idempotent: re-running updates files in place. Existing configs in
# /etc/rclone/rclone.conf and /etc/default/nfs-sync are NOT overwritten —
# you get a *.new file next to them so you can diff/merge yourself.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root" >&2
  exit 1
fi

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
SYSTEM_USER=nfs-sync
SYSTEM_GROUP=nfs-sync

echo "==> Creating system user $SYSTEM_USER"
if ! id -u "$SYSTEM_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin \
          --user-group "$SYSTEM_USER"
fi

echo "==> Creating directories"
install -d -m 0755 /usr/local/bin
install -d -m 0755 /etc/rclone
install -d -m 0755 /etc/default
install -d -m 0755 /etc/systemd/system
install -d -m 0750 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" /var/log/nfs-sync

echo "==> Installing executable"
install -m 0755 "$REPO_DIR/nfs-sync.sh" /usr/bin/nfs-sync

echo "==> Installing systemd units"
install -m 0644 "$REPO_DIR/nfs-sync.service" /etc/systemd/system/nfs-sync.service
install -m 0644 "$REPO_DIR/nfs-sync.timer"   /etc/systemd/system/nfs-sync.timer

echo "==> Installing config templates (non-destructive)"
# rclone.conf contains secrets in some auth modes; root-only.
if [ ! -e /etc/rclone/rclone.conf ]; then
  install -m 0600 -o root -g root "$REPO_DIR/rclone.conf" /etc/rclone/rclone.conf
  echo "    NEW: /etc/rclone/rclone.conf  ← edit auth + account before enabling"
else
  install -m 0600 -o root -g root "$REPO_DIR/rclone.conf" /etc/rclone/rclone.conf.new
  echo "    KEPT existing /etc/rclone/rclone.conf"
  echo "    Wrote /etc/rclone/rclone.conf.new for comparison"
fi

if [ ! -e /etc/default/nfs-sync ]; then
  install -m 0644 "$REPO_DIR/nfs-sync.defaults" /etc/default/nfs-sync
  echo "    NEW: /etc/default/nfs-sync  ← review SRC/DST and tuning"
else
  install -m 0644 "$REPO_DIR/nfs-sync.defaults" /etc/default/nfs-sync.new
  echo "    KEPT existing /etc/default/nfs-sync"
  echo "    Wrote /etc/default/nfs-sync.new for comparison"
fi

echo "==> Installing failure notification unit"
install -m 0644 "$REPO_DIR/nfs-sync-failure.service" /etc/systemd/system/nfs-sync-failure.service

echo "==> Installing benchmark helper"
install -m 0755 "$REPO_DIR/sync-bench.sh" /usr/bin/nfs-sync-bench

echo "==> Installing logrotate config"
install -m 0644 "$REPO_DIR/nfs-sync.logrotate" /etc/logrotate.d/nfs-sync

echo "==> Reloading systemd"
systemctl daemon-reload

cat <<EOF

Done. Next steps:

  1. Edit /etc/rclone/rclone.conf      — set Azure auth + storage account
  2. Edit /etc/default/nfs-sync        — set SRC, DST, tuning
  3. Benchmark BEFORE enabling timer:
       sudo -u $SYSTEM_USER nfs-sync-bench
  4. Once benchmark looks acceptable:
       systemctl enable --now nfs-sync.timer
  5. Watch the first run:
       journalctl -u nfs-sync.service -f
       tail -f /var/log/nfs-sync/sync-*.log

EOF
