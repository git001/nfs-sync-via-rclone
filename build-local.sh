#!/usr/bin/env bash
# Build RPM or DEB packages locally via podman — mirrors GitHub Actions exactly.
#
# Usage:
#   ./build-local.sh [--clean] <target> [<target> ...]
#   ./build-local.sh [--clean] all
#
# Options:
#   --clean   Remove _build/ directories after each successful build
#
# Targets:
#   rpm-el8       quay.io/centos/centos:stream8
#   rpm-el9       quay.io/centos/centos:stream9
#   rpm-el10      quay.io/centos/centos:stream10
#   deb-debian12  debian:bookworm
#   deb-debian13  debian:trixie
#   deb-ubuntu22  ubuntu:22.04
#   deb-ubuntu24  ubuntu:24.04
#   deb-ubuntu26  ubuntu:26.04

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CLEAN=0

run_rpm() {
    local target="$1" image="$2"
    echo ""
    echo "==> BUILD $target ($image)"
    podman run --rm \
        -v "${REPO_ROOT}:/work:Z" \
        "$image" \
        sh -c "
            set -e
            dnf install -y make rpm-build systemd-rpm-macros
            make -C /work/packaging/rpm rpm
        "
    echo "==> ARTIFACTS:"
    ls -lh "${REPO_ROOT}/packaging/rpm/_build/RPMS/noarch/"*.rpm 2>/dev/null || true
    [[ "$CLEAN" -eq 1 ]] && make -C "${REPO_ROOT}/packaging/rpm" clean
}

run_deb() {
    local target="$1" image="$2"
    echo ""
    echo "==> BUILD $target ($image)"
    podman run --rm \
        -v "${REPO_ROOT}:/work:Z" \
        "$image" \
        sh -c "
            set -e
            apt-get update -q
            apt-get install -y --no-install-recommends \
                build-essential dpkg-dev debhelper fakeroot
            make -C /work/packaging/deb deb
        "
    echo "==> ARTIFACTS:"
    ls -lh "${REPO_ROOT}/packaging/deb/_build/"*.deb 2>/dev/null || true
    [[ "$CLEAN" -eq 1 ]] && make -C "${REPO_ROOT}/packaging/deb" clean
}

build_target() {
    case "$1" in
        rpm-el8)      run_rpm rpm-el8  quay.io/centos/centos:stream8  ;;
        rpm-el9)      run_rpm rpm-el9  quay.io/centos/centos:stream9  ;;
        rpm-el10)     run_rpm rpm-el10 quay.io/centos/centos:stream10 ;;
        deb-debian12) run_deb deb-debian12 debian:bookworm ;;
        deb-debian13) run_deb deb-debian13 debian:trixie  ;;
        deb-ubuntu22) run_deb deb-ubuntu22 ubuntu:22.04   ;;
        deb-ubuntu24) run_deb deb-ubuntu24 ubuntu:24.04   ;;
        deb-ubuntu26) run_deb deb-ubuntu26 ubuntu:26.04   ;;
        *) echo "Unknown target: $1"; exit 1 ;;
    esac
}

ALL_TARGETS=(rpm-el8 rpm-el9 rpm-el10 deb-debian12 deb-debian13 deb-ubuntu22 deb-ubuntu24 deb-ubuntu26)

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [--clean] <target|all> [...]"
    echo "Targets: ${ALL_TARGETS[*]}"
    exit 1
fi

TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        all)     TARGETS=("${ALL_TARGETS[@]}") ;;
        *)       TARGETS+=("$arg") ;;
    esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "Error: no build target specified."
    exit 1
fi

FAILED=()
for t in "${TARGETS[@]}"; do
    if ! build_target "$t"; then
        FAILED+=("$t")
    fi
done

echo ""
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "==> All builds succeeded."
else
    echo "==> FAILED: ${FAILED[*]}"
    exit 1
fi
