# shellcheck shell=bash
#
# Package-manager plumbing and dependency checks shared by the yandex-music-rpm
# scripts. Sourced, never executed.
#
# Supported managers:
#   dnf      Fedora, RHEL, CentOS, Alma, Rocky
#   zypper   openSUSE, SLE
#   epm      ALT Linux and anything else shipping eepm
#   apt-rpm  ALT Linux without eepm (apt-get over rpm)

YM_PACKAGE="${YM_PACKAGE:-yandexmusic}"
YM_OS_RELEASE="${YM_OS_RELEASE:-/etc/os-release}"

ym_have() { command -v "$1" >/dev/null 2>&1; }

# Log through the caller's own logger when it has one.
ym_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$@"
  else
    printf '%s\n' "$*"
  fi
}

ym_os_field() {
  [[ -r "$YM_OS_RELEASE" ]] || return 0
  ( . "$YM_OS_RELEASE" >/dev/null 2>&1; printf '%s' "${!1:-}" )
}

# The distribution's own manager wins over whatever else happens to be
# installed: eepm runs everywhere, but on Fedora dnf is the right answer.
ym_pm() {
  if [[ -n "${YM_PM:-}" ]]; then printf '%s\n' "$YM_PM"; return 0; fi
  local id like pm
  id="$(ym_os_field ID)"
  like="$(ym_os_field ID_LIKE)"
  case " $id $like " in
    *" altlinux "*|*" alt "*)
      ym_have epm && { printf 'epm\n'; return 0; }
      ym_have apt-get && { printf 'apt-rpm\n'; return 0; }
      ;;
    *" suse "*|*" opensuse "*)
      ym_have zypper && { printf 'zypper\n'; return 0; }
      ;;
  esac
  for pm in dnf zypper epm; do
    ym_have "$pm" && { printf '%s\n' "$pm"; return 0; }
  done
  if ym_have apt-get && ym_have rpm; then printf 'apt-rpm\n'; return 0; fi
  return 1
}

ym_pm_name() { ym_pm 2>/dev/null || printf 'none'; }

# eepm's own repack is the native answer on ALT Linux, and it knows how to pull
# in whatever it needs; everywhere else it is alien. alien only counts when
# rpmbuild is there too — it shells out to it and fails late and loudly if not.
ym_converter() {
  if [[ -n "${YM_CONVERTER:-}" ]]; then printf '%s\n' "$YM_CONVERTER"; return 0; fi
  case "$(ym_pm_name)" in
    epm|apt-rpm) ym_have epm && { printf 'epm\n'; return 0; } ;;
  esac
  ym_have alien && ym_have rpmbuild && { printf 'alien\n'; return 0; }
  ym_have epm && { printf 'epm\n'; return 0; }
  return 1
}

ym_installed_version() {
  rpm -q --qf '%{VERSION}' "$YM_PACKAGE" 2>/dev/null || true
}

ym_install_rpm_file() {
  local file="$1"
  case "$(ym_pm_name)" in
    dnf)    dnf install -y --allow-downgrade "$file" ;;
    zypper) zypper --non-interactive install --allow-unsigned-rpm --oldpackage "$file" ;;
    epm)    epm install "$file" || rpm -Uvh --oldpackage "$file" ;;
    apt-rpm) rpm -Uvh --oldpackage "$file" ;;
    *) ym_log "error: no supported package manager found"; return 1 ;;
  esac
}

# What to tell a user who has no working converter at all.
ym_converter_hint() {
  local packages=(rpm-build)
  ym_have alien || ym_have epm || packages+=("$(ym_package_for deb-converter)")
  ym_install_hint "${packages[@]}"
}

# Last resort when the alien path breaks: eepm repacks .deb itself and installs
# its own build dependencies on the way, so it often works where alien did not.
ym_install_deb_epm() {
  ym_have epm || return 1
  ym_log "falling back to epm --repack"
  epm --repack install "$1"
}

# Convert and install a .deb. Returns non-zero on any failure; output of the
# heavy lifting goes wherever the caller pointed stdout/stderr.
ym_install_deb() {
  local deb="$1" workdir="$2" rpm_file
  case "$(ym_converter || true)" in
    alien)
      ym_log "converting deb to rpm with alien"
      # An uncompressed payload cuts the conversion of a ~90 MB package from
      # minutes to seconds; the RPM is a throwaway that the package manager
      # reads back immediately.
      printf '%%_binary_payload w0.gzdio\n' >"$workdir/.rpmmacros"
      if ! ( cd "$workdir" && HOME="$workdir" alien -r --scripts "$(basename -- "$deb")" ); then
        ym_log "error: alien failed"
        ym_install_deb_epm "$deb"
        return
      fi
      rpm_file="$(find "$workdir" -maxdepth 1 -type f -name '*.rpm' | sort | tail -n 1)"
      if [[ -z "$rpm_file" ]]; then
        ym_log "error: alien did not produce an RPM file"
        ym_install_deb_epm "$deb"
        return
      fi
      ym_log "installing $(basename -- "$rpm_file") with $(ym_pm_name)"
      ym_install_rpm_file "$rpm_file"
      ;;
    epm)
      ym_log "repacking and installing with epm"
      epm --repack install "$deb"
      ;;
    *)
      ym_log "error: no way to convert a .deb: $(ym_converter_hint)"
      return 1
      ;;
  esac
}

ym_remove_package() {
  case "$(ym_pm_name)" in
    dnf)    dnf remove -y "$YM_PACKAGE" ;;
    zypper) zypper --non-interactive remove "$YM_PACKAGE" ;;
    epm)    epm remove "$YM_PACKAGE" ;;
    apt-rpm) apt-get remove -y "$YM_PACKAGE" ;;
    *) return 1 ;;
  esac
}

ym_install_packages() {
  (($#)) || return 0
  case "$(ym_pm_name)" in
    dnf)    dnf install -y "$@" ;;
    zypper) zypper --non-interactive install "$@" ;;
    epm)    epm install "$@" ;;
    apt-rpm) apt-get install -y "$@" ;;
    *) return 1 ;;
  esac
}

# --- dependencies ----------------------------------------------------------

# Tools without which nothing works at all.
ym_missing_required() {
  local cmd missing=()
  for cmd in curl rpm python3; do
    ym_have "$cmd" || missing+=("$cmd")
  done
  # rpmbuild does the actual packing for both converters: alien calls it
  # directly, and eepm's repack assures it is there before it starts.
  ym_have rpmbuild || missing+=(rpmbuild)
  ym_have alien || ym_have epm || missing+=(deb-converter)
  ym_pm >/dev/null || missing+=(package-manager)
  ((${#missing[@]})) && printf '%s\n' "${missing[@]}"
  return 0
}

# Tools that only make things nicer; each degrades on its own.
#   openssl      verifies the sha512 from the update feed
#   pkexec       the password prompt the app itself uses for the update button
#   systemd-run  keeps the background install outside the app's cgroup
#   notify-send  the "installing / installed" notifications
#   flock        serializes two clicks on "Обновить"
ym_missing_optional() {
  local cmd missing=()
  for cmd in openssl pkexec systemd-run notify-send flock; do
    ym_have "$cmd" || missing+=("$cmd")
  done
  ((${#missing[@]})) && printf '%s\n' "${missing[@]}"
  return 0
}

# Package that provides a tool, as named by the current manager.
ym_package_for() {
  local tool="$1" pm; pm="$(ym_pm_name)"
  case "$tool" in
    curl) printf 'curl\n' ;;
    rpm) printf 'rpm\n' ;;
    python3) printf 'python3\n' ;;
    openssl) printf 'openssl\n' ;;
    flock) printf 'util-linux\n' ;;
    rpmbuild) printf 'rpm-build\n' ;;
    deb-converter|alien)
      # ALT Linux repacks with eepm instead of alien.
      case "$pm" in
        epm|apt-rpm) printf 'eepm\n' ;;
        *) printf 'alien\n' ;;
      esac
      ;;
    pkexec) printf 'polkit\n' ;;
    systemd-run) printf 'systemd\n' ;;
    notify-send)
      case "$pm" in
        zypper) printf 'libnotify-tools\n' ;;
        *) printf 'libnotify\n' ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# The command that installs these packages, as root.
ym_install_command() {
  case "$(ym_pm_name)" in
    dnf)     printf 'dnf install -y %s\n' "$*" ;;
    zypper)  printf 'zypper --non-interactive install %s\n' "$*" ;;
    epm)     printf 'epm install %s\n' "$*" ;;
    apt-rpm) printf 'apt-get install -y %s\n' "$*" ;;
    *)       return 1 ;;
  esac
}

# The same command as advice for a human, who is probably not root yet.
ym_install_hint() {
  local command
  command="$(ym_install_command "$@")" || { printf 'install: %s\n' "$*"; return 0; }
  [[ $EUID -eq 0 ]] && { printf '%s\n' "$command"; return 0; }
  printf 'sudo %s\n' "$command"
}

# Refuse to run with a broken toolchain, and say exactly how to fix it.
ym_require_deps() {
  local missing=() tool packages=()
  mapfile -t missing < <(ym_missing_required)
  ((${#missing[@]})) || return 0
  for tool in "${missing[@]}"; do
    packages+=("$(ym_package_for "$tool" || printf '%s' "$tool")")
  done
  ym_log "error: missing required tools: ${missing[*]}"
  ym_log "install them with: $(ym_install_hint "${packages[@]}")"
  return 1
}
