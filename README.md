# nfs-sync

Hardened, idempotent one-shot sync from an NFS mount to any rclone-supported
object store (Azure Blob, S3, GCS, B2, …). Runs as a systemd timer with
gap-based scheduling, flock-based overlap protection, quiescence filtering,
and a mandatory pre-production benchmark gate.

Designed for 1M+ file trees where NFS walk latency is the critical variable.

## How it works

```
NFS mount  ──►  nfs-sync.sh  ──►  rclone sync  ──►  Object Store
               (preflight +         (--fast-list
                flock +              --checksum
                quiescence)          --min-age)
```

- **Polling, not events.** `inotify` does not fire on NFS clients for writes
  made by other hosts. The reconcile loop against the filesystem as
  source-of-truth is intentional.
- **Gap-based timer.** `OnUnitInactiveSec` guarantees a fixed gap between runs
  regardless of how long a run takes — no two syncs can overlap.
- **Quiescence filter.** `--min-age` skips files touched within the last N
  seconds, avoiding uploads of files still being written.
- **Hard loss SLA.** Every file version is eventually synced, even after crash
  or network drop, because each run is a full reconcile.

## Requirements

| Dependency | Min version | Notes |
|---|---|---|
| rclone | 1.58 | `upload_concurrency` (Azure) added in v1.58 |
| bash | 4.4 | `mapfile`, `EPOCHSECONDS` |
| util-linux | any | `flock`, `mountpoint` |
| systemd | any | timer + hardened service unit |

## Installation

### From source (any distro)

```bash
sudo ./rclone/install.sh
```

Idempotent. Existing `/etc/rclone/rclone.conf` and `/etc/default/nfs-sync`
are never overwritten — a `.new` file is written next to them for manual
diffing.

### Packages

Pre-built packages are available for the following targets:

| Format | Targets | Build |
|---|---|---|
| RPM | RHEL 8 / 9 / 10 | `make -C packaging/rpm` |
| DEB | Ubuntu 22/24/26, Debian 12/13 | `make -C packaging/deb` |
| Alpine APKBUILD | Alpine 3.21+ | `abuild -r` in `packaging/alpine/` |
| Nix Flake | x86\_64-linux, aarch64-linux | `nix build .#nfs-sync` in `packaging/nix/` |

## Configuration

### 1. rclone remote (`/etc/rclone/rclone.conf`)

`rclone/rclone.conf` is an annotated template for Azure Blob. Replace or
extend it for your backend. The file is root-owned, mode 0600.

```ini
# Azure Blob example — see rclone docs for S3, GCS, B2, etc.
[my-remote]
type = azureblob
account = mystorageaccount
use_msi = true          # Managed Identity (recommended on Azure VMs)
upload_concurrency = 16
chunk_size = 64M
```

### 2. Environment (`/etc/default/nfs-sync`)

`rclone/nfs-sync.defaults` is the annotated template. Key variables:

| Variable | Default | Description |
|---|---|---|
| `SRC` | `/mnt/nfs/source` | NFS mount path (must be a real mountpoint) |
| `DST` | `remote:bucket` | rclone destination — must match your `rclone.conf` |
| `MOUNT_CHECK_FILE` | _(empty)_ | Sentinel file inside `SRC`; if missing, sync aborts |
| `MIN_AGE` | `30s` | Quiescence window — skip files newer than this |
| `TRANSFERS` | `32` | Parallel upload streams |
| `CHECKERS` | `32` | Parallel checksum / stat workers |
| `MODIFY_WINDOW` | `2s` | mtime tolerance — 2s suits NFS; set to `0` for exact backends |
| `EXCLUDE_PATTERNS` | `*.tmp,*.swp,…` | Comma-separated rclone filter globs |
| `BWLIMIT` | _(empty)_ | Bandwidth cap, e.g. `100M`; empty = unlimited |
| `RCLONE_CONFIG` | `/etc/rclone/rclone.conf` | Config path |

## Benchmark before going live

Run `nfs-sync-bench` against the **real** NFS share and object store before
enabling the timer. It produces three numbers:

```
WALK_TIME_S   — time to stat the entire source tree
RECONCILE_S   — end-to-end sync of an unchanged tree (your latency floor)
UPLOAD_MBPS   — effective upload bandwidth
```

Decision rule:

| Result | Action |
|---|---|
| `RECONCILE_S < SLA × 0.5` | rclone is fine — enable the timer |
| `RECONCILE_S < SLA` | rclone works, but monitor closely |
| `RECONCILE_S >= SLA` | escalate: shorter interval, tree sharding, or custom tool |

```bash
sudo -u nfs-sync nfs-sync-bench
```

## Enabling the timer

```bash
systemctl enable --now nfs-sync.timer   # start on boot + immediately
systemctl status nfs-sync.timer         # next trigger time
journalctl -u nfs-sync.service -f       # live log
tail -f /var/log/nfs-sync/sync-*.log    # per-run log with timing breakdown
```

The timer fires 2 minutes after boot, then runs with a 1-minute gap between
runs. Adjust `OnUnitInactiveSec` in `nfs-sync.timer` for your SLA budget.

## Local lab (no NFS server, no cloud account required)

The `lab/` directory contains a self-contained test environment:

- **Source**: tmpfs mounted at `/tmp/nfs-lab/mount` (satisfies `mountpoint -q`)
- **Target**: Azurite (Azure Blob emulator) via Podman

```bash
sudo ./lab/lab.sh setup        # start Azurite, mount tmpfs, generate 1000 test files
./lab/lab.sh run-sync          # run nfs-sync.sh with lab config
./lab/lab.sh verify            # assert source count == blob count, no .tmp files leaked
./lab/lab.sh logs              # tail the most recent sync log
./lab/lab.sh status            # show current state
sudo ./lab/lab.sh teardown     # stop everything, unmount, clean up
```

Requirements: `podman`, `rclone >= 1.65` (Azurite endpoint support), `sudo`.

## Versioning

`bump-version.sh` updates the version atomically across all six packaging
files (RPM spec, RPM Makefile, Debian changelog, Debian Makefile, Nix flake,
Alpine APKBUILD):

```bash
./bump-version.sh 0.2.0 "Your changelog message"
./bump-version.sh --dry-run 0.2.0   # preview changes without writing
```

## Repository layout

```
rclone/
  nfs-sync.sh          # sync script (installed as /usr/bin/nfs-sync)
  nfs-sync.service     # systemd service unit
  nfs-sync.timer       # systemd timer unit (1 min gap)
  nfs-sync.defaults    # /etc/default/nfs-sync template
  rclone.conf          # rclone.conf template (Azure Blob example)
  sync-bench.sh        # benchmark helper (/usr/bin/nfs-sync-bench)
  install.sh           # source-based installer (idempotent)
lab/
  lab.sh               # lab management script
  lab.defaults         # env overrides for lab runs
  lab.rclone.conf      # Azurite config (well-known dev credentials)
packaging/
  rpm/                 # RPM spec + Makefile (RHEL 8/9/10)
  deb/                 # Debian source package (Ubuntu 22/24/26, Debian 12/13)
  nix/                 # Nix flake + NixOS module
  alpine/              # Alpine APKBUILD + OpenRC init + crond integration
bump-version.sh        # atomic version bump across all packaging files
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
