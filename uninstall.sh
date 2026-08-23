#!/usr/bin/env bash
# Remove Yandex Music, the installed scripts and the shell alias.
set -Eeuo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"
remove_app=1

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--keep-app]

Removes the yandexmusic package with dnf, deletes the scripts from
/usr/local/bin and drops the alias from ~/.bashrc.

Options:
  --keep-app   Keep Yandex Music installed; only revert the app.asar patch and
               remove the scripts.
  -h, --help   Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --keep-app) remove_app=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[uninstall] error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '[uninstall] %s\n' "$*"; }
die() { printf '[uninstall] error: %s\n' "$*" >&2; exit 1; }

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

# dnf would happily pull the files out from under a running app; stop it first.
stop_app() {
  local proc exe pids=()
  for proc in /proc/[0-9]*; do
    exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
    [[ "$exe" == /opt/Яндекс\ Музыка/* ]] && pids+=("${proc#/proc/}")
  done
  ((${#pids[@]})) || return 0
  log "stopping the running app"
  kill -TERM "${pids[@]}" 2>/dev/null || true
  sleep 3
  kill -KILL "${pids[@]}" 2>/dev/null || true
}

root_script=()
if rpm -q yandexmusic >/dev/null 2>&1; then
  if ((remove_app)); then
    stop_app
    log "removing the yandexmusic package"
    root_script+=("dnf remove -y yandexmusic")
  elif [[ -x "$PREFIX/patch-yandex-music-updater" ]]; then
    log "keeping Yandex Music, reverting the in-app updater patch"
    root_script+=("$PREFIX/patch-yandex-music-updater --revert || true")
  fi
fi
root_script+=("rm -f $PREFIX/yandex-music-update $PREFIX/yandex-music-install $PREFIX/patch-yandex-music-updater")

as_root /bin/bash -c "set -e; $(printf '%s; ' "${root_script[@]}")"

rc="$HOME/.bashrc"
if grep -Fq '# yandex-music-rpm' "$rc" 2>/dev/null; then
  log "removing alias from $rc"
  python3 - "$rc" <<'PY'
import sys
from pathlib import Path

rc = Path(sys.argv[1])
lines = rc.read_text().splitlines(keepends=True)
out, skip = [], 0
for line in lines:
    if line.strip() == "# yandex-music-rpm":
        skip = 1
        continue
    if skip and line.startswith("alias "):
        skip = 0
        continue
    skip = 0
    out.append(line)
rc.write_text("".join(out))
PY
fi

if ((remove_app)); then
  log "done"
else
  log "done (Yandex Music left installed: dnf remove yandexmusic)"
fi
