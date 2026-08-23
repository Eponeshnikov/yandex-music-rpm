#!/usr/bin/env bash
# Install the yandex-music-rpm scripts and patch an existing installation.
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"
LIBDIR="${LIBDIR:-/usr/local/lib/yandex-music-rpm}"
YM_LIB="$repo_dir/lib/ym-common.sh"
# shellcheck source=lib/ym-common.sh
. "$YM_LIB" || { printf 'error: lib/ym-common.sh not found\n' >&2; exit 1; }
ALIAS_NAME=ymupd
want_alias=1 want_patch=1 want_deps=1 want_app=1

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Installs yandex-music-update, yandex-music-install and
patch-yandex-music-updater into /usr/local/bin and adds a shell alias. If Yandex
Music is already installed, patches it so its "Обновить" button works; if it is
not, downloads and installs it (the version from the site's download.json) and
patches that.

Options:
  --alias NAME   Alias name for yandex-music-update (default: ymupd).
  --no-alias     Do not touch ~/.bashrc.
  --no-patch     Do not patch the installed app.
  --no-app       Do not install Yandex Music itself if it is missing.
  --no-deps      Do not install missing dependencies.
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
    --no-app) want_app=0 ;;
    --no-deps) want_deps=0 ;;
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

command -v rpm >/dev/null 2>&1 || die "this installer is for RPM-based distributions"
ym_pm >/dev/null || die "no supported package manager found (dnf, zypper, epm, apt-get)"
log "package manager: $(ym_pm_name)"

root_script=()

mapfile -t missing_required < <(ym_missing_required)
if ((${#missing_required[@]})); then
  packages=()
  for tool in "${missing_required[@]}"; do
    packages+=("$(ym_package_for "$tool" || printf '%s' "$tool")")
  done
  if ((want_deps)); then
    log "missing: ${missing_required[*]} — installing ${packages[*]}"
    root_script+=("$(ym_install_command "${packages[@]}")")
  else
    die "missing required tools: ${missing_required[*]} ($(ym_install_hint "${packages[@]}"))"
  fi
fi

mapfile -t missing_optional < <(ym_missing_optional)
for tool in "${missing_optional[@]:-}"; do
  [[ -n "$tool" ]] || continue
  case "$tool" in
    openssl) log "note: openssl missing — the sha512 from the update feed will not be checked" ;;
    pkexec) log "note: pkexec missing — the app's own update button cannot ask for a password" ;;
    systemd-run) log "note: systemd-run missing — the background install falls back to setsid" ;;
    notify-send) log "note: notify-send missing — no update notifications" ;;
    flock) log "note: flock missing — two clicks on «Обновить» will not be serialized" ;;
  esac
  log "      install it with: $(ym_install_hint "$(ym_package_for "$tool" || printf '%s' "$tool")")"
done

log "installing scripts into $PREFIX"
root_script+=("install -d -m 0755 $PREFIX $LIBDIR")
root_script+=("install -m 0644 $repo_dir/lib/ym-common.sh $LIBDIR/common.sh")
root_script+=("install -m 0755 -t $PREFIX \
  $repo_dir/bin/yandex-music-update \
  $repo_dir/bin/yandex-music-install \
  $repo_dir/bin/patch-yandex-music-updater")

if rpm -q yandexmusic >/dev/null 2>&1; then
  if ((want_patch)); then
    log "Yandex Music is installed, will patch its in-app updater"
    root_script+=("$PREFIX/patch-yandex-music-updater")
  fi
elif ((want_app)); then
  log "Yandex Music is not installed, will download and install it"
  # Same escalation as everything else, so this stays a single password prompt.
  # The site's download.json is the right source for a first install; updates
  # then come from the app's own feed, through the button or yandex-music-update.
  root_script+=("$PREFIX/yandex-music-update --download-json")
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
  log "Yandex Music is not installed — run: $PREFIX/yandex-music-update"
fi

log "done"
