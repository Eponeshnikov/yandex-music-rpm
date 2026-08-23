#!/usr/bin/env bash
# Revert the app.asar patch and remove the installed scripts.
set -Eeuo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"

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

root_script=()
if [[ -x "$PREFIX/patch-yandex-music-updater" ]] && rpm -q yandexmusic >/dev/null 2>&1; then
  root_script+=("$PREFIX/patch-yandex-music-updater --revert || true")
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

log "done (the yandexmusic package itself is untouched: dnf remove yandexmusic)"
