#!/usr/bin/env bash
# Install the yandex-music-rpm scripts and patch an existing installation.
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"
ALIAS_NAME=ymupd
want_alias=1 want_patch=1 want_deps=1

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Installs yandex-music-update, yandex-music-install and
patch-yandex-music-updater into /usr/local/bin, patches an already installed
Yandex Music so its "Обновить" button works, and adds a shell alias.

Options:
  --alias NAME   Alias name for yandex-music-update (default: ymupd).
  --no-alias     Do not touch ~/.bashrc.
  --no-patch     Do not patch the installed app.
  --no-deps      Do not install missing dependencies (alien).
  --prefix DIR   Install into DIR instead of /usr/local/bin.
  -h, --help     Show this help.
EOF
}

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] error: %s\n' "$*" >&2; exit 1; }

as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif [[ -n "${YM_ROOT_CMD:-}" ]]; then
    $YM_ROOT_CMD "$@"
  elif command -v sudo >/dev/null 2>&1 && { sudo -n true 2>/dev/null || [[ -t 0 ]]; }; then
    sudo "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "no way to become root: install sudo or pkexec"
  fi
}

while (($#)); do
  case "$1" in
    --alias) ALIAS_NAME="${2:?--alias needs a name}"; shift ;;
    --no-alias) want_alias=0 ;;
    --no-patch) want_patch=0 ;;
    --no-deps) want_deps=0 ;;
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

command -v rpm >/dev/null 2>&1 || die "this installer is for RPM-based distributions"
command -v dnf >/dev/null 2>&1 || die "dnf not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v curl >/dev/null 2>&1 || die "curl not found"

missing_deps=()
command -v alien >/dev/null 2>&1 || missing_deps+=(alien)

root_script=()
if ((${#missing_deps[@]})); then
  if ((want_deps)); then
    log "will install missing dependencies: ${missing_deps[*]}"
    root_script+=("dnf install -y ${missing_deps[*]}")
  else
    die "missing dependencies: ${missing_deps[*]} (dnf install -y ${missing_deps[*]})"
  fi
fi

log "installing scripts into $PREFIX"
root_script+=("install -d -m 0755 $PREFIX")
root_script+=("install -m 0755 -t $PREFIX \
  $repo_dir/bin/yandex-music-update \
  $repo_dir/bin/yandex-music-install \
  $repo_dir/bin/patch-yandex-music-updater")

if ((want_patch)) && rpm -q yandexmusic >/dev/null 2>&1; then
  log "Yandex Music is installed, will patch its in-app updater"
  root_script+=("$PREFIX/patch-yandex-music-updater")
fi

# One escalation for the whole job, so the user sees a single password prompt.
as_root /bin/bash -c "set -e; $(printf '%s; ' "${root_script[@]}")"

if ((want_alias)); then
  rc="$HOME/.bashrc"
  marker="# yandex-music-rpm"
  if grep -Fq "$marker" "$rc" 2>/dev/null; then
    log "alias already present in $rc"
  else
    printf '\n%s\nalias %s=%s\n' "$marker" "$ALIAS_NAME" "$PREFIX/yandex-music-update" >>"$rc"
    log "added alias '$ALIAS_NAME' to $rc (open a new shell or: source $rc)"
  fi
fi

if ! rpm -q yandexmusic >/dev/null 2>&1; then
  log "Yandex Music is not installed yet — run: $PREFIX/yandex-music-update"
fi

log "done"
