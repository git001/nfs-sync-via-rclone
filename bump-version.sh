#!/usr/bin/env bash
# bump-version.sh — Update the nfs-sync version in all packaging files.
#
# Usage:
#   ./bump-version.sh 0.2.0
#   ./bump-version.sh 0.2.0 "Fix quiescence race; bump rclone min version"
#   ./bump-version.sh --dry-run 0.2.0
#
# What it touches:
#   packaging/rpm/nfs-sync.spec       — Version: line, prepends %changelog entry
#   packaging/rpm/Makefile            — VERSION := line
#   packaging/deb/debian/changelog    — prepends a new top entry
#   packaging/deb/Makefile            — VERSION := line
#   packaging/nix/flake.nix           — version = "..."; line
#   packaging/alpine/APKBUILD         — pkgver= line, resets pkgrel=0
#
# Refuses to run if any of the target files have uncommitted changes that
# don't match the expected current-version pattern (safety: don't clobber
# half-edited files). Override with --force.

set -euo pipefail

DRY_RUN=0
FORCE=0
NEW_VERSION=""
MESSAGE=""

usage() {
  sed -n 's/^# \{0,1\}//;1,/^$/p' "$0" | sed -n '2,/^Usage:/p; /^Usage:/,$p' | head -30
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    -h|--help) usage ;;
    -*)        echo "unknown flag: $1" >&2; usage ;;
    *)
      if [ -z "$NEW_VERSION" ]; then
        NEW_VERSION="$1"
      elif [ -z "$MESSAGE" ]; then
        MESSAGE="$1"
      else
        echo "too many positional args" >&2; usage
      fi
      shift
      ;;
  esac
done

[ -n "$NEW_VERSION" ] || usage

# Validate semver-ish: N.N.N optionally followed by -<pre>.
if ! printf '%s' "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$'; then
  echo "error: '$NEW_VERSION' is not a valid version (expected N.N.N[-pre])" >&2
  exit 2
fi

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$REPO_ROOT"

# Detect current version from the RPM spec (canonical source).
SPEC=packaging/rpm/nfs-sync.spec
CURRENT_VERSION=$(awk '/^Version:/ {print $2; exit}' "$SPEC")
if [ -z "$CURRENT_VERSION" ]; then
  echo "error: could not read current version from $SPEC" >&2
  exit 3
fi

if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
  echo "error: current version is already $NEW_VERSION; nothing to do" >&2
  exit 4
fi

echo "bumping nfs-sync: $CURRENT_VERSION → $NEW_VERSION"
[ $DRY_RUN -eq 1 ] && echo "(dry run — no files will be modified)"
echo

# RFC 5322 date for debian/changelog
DATE_RFC=$(date -R)
# Human date for rpm %changelog (* Day MonthName DD YYYY ...)
DATE_RPM=$(LC_ALL=C date '+%a %b %d %Y')
DEFAULT_MSG="Bump to $NEW_VERSION."
MSG="${MESSAGE:-$DEFAULT_MSG}"
AUTHOR="${PACKAGER:-Build Bot <noreply@example.invalid>}"

# ---------- Safety: each target must currently contain CURRENT_VERSION -----
check_current() {
  local file="$1" pattern="$2"
  if ! grep -qE "$pattern" "$file"; then
    echo "FAIL: $file does not contain expected current-version pattern" >&2
    echo "      pattern: $pattern" >&2
    [ $FORCE -eq 1 ] && return 0
    return 1
  fi
}

# Quote current version for regex use.
CV_RE=$(printf '%s' "$CURRENT_VERSION" | sed 's/[][\/.^$*]/\\&/g')

check_current packaging/rpm/nfs-sync.spec  "^Version:[[:space:]]+${CV_RE}$"     || exit 5
check_current packaging/rpm/Makefile       "^VERSION[[:space:]]*:=[[:space:]]*${CV_RE}$" || exit 5
check_current packaging/deb/debian/changelog "^nfs-sync \\(${CV_RE}-[0-9]+\\)" || exit 5
check_current packaging/deb/Makefile       "^VERSION[[:space:]]*:=[[:space:]]*${CV_RE}$" || exit 5
check_current packaging/nix/flake.nix      "version[[:space:]]*=[[:space:]]*\"${CV_RE}\";" || exit 5
check_current packaging/alpine/APKBUILD    "^pkgver=${CV_RE}$" || exit 5

# ---------- Apply edits -----------------------------------------------------
apply() {
  if [ $DRY_RUN -eq 1 ]; then
    echo "  would edit: $1"
  else
    echo "  editing:    $1"
  fi
}

run_sed() {
  local file="$1" expr="$2"
  if [ $DRY_RUN -eq 1 ]; then
    # Show first matching line before/after
    diff <(grep -nE "$3" "$file" || true) \
         <(sed -E "$expr" "$file" | grep -nE "$3" || true) | head -10 || true
  else
    sed -i -E "$expr" "$file"
  fi
}

# 1. RPM spec — Version: line + prepend %changelog entry
apply packaging/rpm/nfs-sync.spec
run_sed packaging/rpm/nfs-sync.spec \
  "s/^Version:[[:space:]]+${CV_RE}$/Version:        ${NEW_VERSION}/" \
  "^Version:"

if [ $DRY_RUN -eq 0 ]; then
  # Prepend a new entry directly under the "%changelog" line.
  awk -v new_ver="$NEW_VERSION" -v date_rpm="$DATE_RPM" \
      -v author="$AUTHOR" -v msg="$MSG" '
    /^%changelog$/ {
      print
      printf "* %s %s - %s-1\n- %s\n\n", date_rpm, author, new_ver, msg
      next
    }
    { print }
  ' packaging/rpm/nfs-sync.spec > packaging/rpm/nfs-sync.spec.tmp \
    && mv packaging/rpm/nfs-sync.spec.tmp packaging/rpm/nfs-sync.spec
fi

# 2. RPM Makefile
apply packaging/rpm/Makefile
run_sed packaging/rpm/Makefile \
  "s/^VERSION[[:space:]]*:=[[:space:]]*${CV_RE}$/VERSION := ${NEW_VERSION}/" \
  "^VERSION"

# 3. Debian changelog — prepend new entry
apply packaging/deb/debian/changelog
if [ $DRY_RUN -eq 0 ]; then
  {
    printf 'nfs-sync (%s-1) unstable; urgency=medium\n\n  * %s\n\n -- %s  %s\n\n' \
      "$NEW_VERSION" "$MSG" "$AUTHOR" "$DATE_RFC"
    cat packaging/deb/debian/changelog
  } > packaging/deb/debian/changelog.tmp \
    && mv packaging/deb/debian/changelog.tmp packaging/deb/debian/changelog
fi

# 4. Debian Makefile
apply packaging/deb/Makefile
run_sed packaging/deb/Makefile \
  "s/^VERSION[[:space:]]*:=[[:space:]]*${CV_RE}$/VERSION := ${NEW_VERSION}/" \
  "^VERSION"

# 5. Nix flake
apply packaging/nix/flake.nix
run_sed packaging/nix/flake.nix \
  "s/version[[:space:]]*=[[:space:]]*\"${CV_RE}\";/version = \"${NEW_VERSION}\";/" \
  "version[[:space:]]*="

# 6. Alpine APKBUILD — bump pkgver, reset pkgrel to 0
apply packaging/alpine/APKBUILD
run_sed packaging/alpine/APKBUILD \
  "s/^pkgver=${CV_RE}$/pkgver=${NEW_VERSION}/; s/^pkgrel=[0-9]+$/pkgrel=0/" \
  "^(pkgver|pkgrel)="

# 7. CHANGELOG.md — regenerate via git-cliff (optional, requires git-cliff in PATH)
if command -v git-cliff >/dev/null 2>&1; then
  apply CHANGELOG.md
  if [ $DRY_RUN -eq 0 ]; then
    git-cliff --tag "v$NEW_VERSION" -o CHANGELOG.md
  fi
else
  echo "  (CHANGELOG.md skipped — git-cliff not in PATH)"
  echo "  install: https://git-cliff.org/docs/installation"
fi

echo
if [ $DRY_RUN -eq 1 ]; then
  echo "dry run complete — nothing was changed."
else
  echo "version bumped to $NEW_VERSION."
  echo
  echo "next steps:"
  echo "  git diff                       # review"
  echo "  git add -p"
  echo "  git commit -m 'release: $NEW_VERSION'"
  echo "  git tag v$NEW_VERSION"
  echo "  git push && git push --tags    # triggers CI release build"
fi
