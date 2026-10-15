#!/usr/bin/env bash
#
# install-claude-desktop.sh
#
# Installs Anthropic's official Claude Desktop (Linux beta) on distributions
# that can't use apt: SteamOS on the Steam Frame, Arch, Manjaro, and similar.
#
# How it works: Anthropic publishes the app as a .deb. This script downloads
# the newest .deb for your CPU (arm64 or amd64) straight from Anthropic's
# repository, checks its SHA-256 against the repository index, unpacks it into
# your home folder (no root, no package manager, nothing touches the read-only
# system partition), then adds a launcher script, an application-menu entry,
# icons, and the claude:// link handler that browser sign-in needs.
#
# Unofficial: Anthropic only supports Debian and Ubuntu for this beta. The
# steps were worked out and verified by hand on a Steam Frame (SteamOS, arm64).
# On that machine every library the app needed was already present.
#
# Usage:   ./install-claude-desktop.sh [install|update|uninstall] [options]
#          ./install-claude-desktop.sh --help
#
set -Eeuo pipefail

SCRIPT_NAME=${0##*/}

# ---------------------------------------------------------------- settings --
REPO_BASE="https://downloads.claude.ai/claude-desktop/apt/stable"

DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}

INSTALL_DIR=${CLAUDE_INSTALL_DIR:-$DATA_HOME/claude-desktop}
BIN_DIR=${CLAUDE_BIN_DIR:-$HOME/.local/bin}

LAUNCHER=$BIN_DIR/claude-desktop-launcher
APPS_DIR=$DATA_HOME/applications
ICONS_DIR=$DATA_HOME/icons
DESKTOP_FILE=$APPS_DIR/claude-desktop.desktop
CONFIG_DIR=$CONFIG_HOME/claude-desktop-linux
CONFIG_FILE=$CONFIG_DIR/config
STATE_DIR=$STATE_HOME/claude-desktop-linux
LOG_FILE=$STATE_DIR/launch.log
CACHE_DIR=$CACHE_HOME/claude-desktop-linux

MARKER=.installed-from           # records which .deb the install came from
MIN_FREE_KB=1200000              # ~1.2 GB for the download plus extraction

# ----------------------------------------------------------------- helpers --
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [command] [options]

Commands:
  install      Download and install the newest Claude Desktop (default)
  update       Same as install: replaces the app only if a newer version exists
  uninstall    Remove everything this script installed
  help         Show this message

Options:
  -f, --force        Reinstall even if the newest version is already installed
      --deb FILE     Install from a .deb you already downloaded (skips the
                     checksum check, since there is nothing to compare against)
      --keep-download  Keep the downloaded .deb in $CACHE_DIR
  -h, --help         Show this message

Environment variables:
  CLAUDE_INSTALL_DIR   Where the app is unpacked
                       (default: $DATA_HOME/claude-desktop)
  CLAUDE_BIN_DIR       Where the launcher script goes
                       (default: $HOME/.local/bin)

Files this script creates:
  App folder      \$CLAUDE_INSTALL_DIR
  Launcher        $LAUNCHER
  Menu entry      $DESKTOP_FILE
  Icons           $ICONS_DIR/hicolor/*/apps/claude-desktop.png
  Settings        $CONFIG_FILE
  Launch log      $LOG_FILE
EOF
}

# --------------------------------------------------------------- arguments --
ACTION=install
FORCE=0
KEEP_DL=0
LOCAL_DEB=""

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      install|update) ACTION=install ;;
      uninstall)      ACTION=uninstall ;;
      help|-h|--help) ACTION=help ;;
      -f|--force)     FORCE=1 ;;
      --keep-download) KEEP_DL=1 ;;
      --deb)
        shift
        [ $# -gt 0 ] || die "--deb needs a file name"
        LOCAL_DEB=$1
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
}

# ------------------------------------------------------------------ checks --
check_not_root() {
  [ "$(id -u)" -ne 0 ] || die "don't run this as root; it installs into your home folder"
}

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64) DEB_ARCH=arm64 ;;
    x86_64|amd64)  DEB_ARCH=amd64 ;;
    *) die "unsupported CPU architecture '$(uname -m)' (Anthropic publishes arm64 and amd64 only)" ;;
  esac
}

check_safe_install_dir() {
  case $INSTALL_DIR in
    ""|/|"$HOME"|"$HOME"/) die "refusing to use '$INSTALL_DIR' as the install folder" ;;
  esac
}

check_extract_tools() {
  if have bsdtar; then
    return 0
  fi
  if have ar && have tar; then
    return 0
  fi
  die "need either bsdtar (libarchive) or both ar and tar to unpack a .deb"
}

check_disk_space() {
  local parent avail
  parent=$(dirname "$INSTALL_DIR")
  avail=$(df -Pk "$parent" 2>/dev/null | awk 'NR==2 {print $4}') || avail=""
  if [ -n "$avail" ] && [ "$avail" -lt "$MIN_FREE_KB" ] 2>/dev/null; then
    die "not enough free space in $parent (need about 1.2 GB, have $((avail / 1024)) MB)"
  fi
}

check_existing_install_dir() {
  # Never replace a folder that isn't ours.
  if [ -e "$INSTALL_DIR" ]; then
    if [ ! -e "$INSTALL_DIR/$MARKER" ] && [ ! -x "$INSTALL_DIR/claude-desktop" ]; then
      die "$INSTALL_DIR exists but doesn't look like a Claude Desktop install; move it or set CLAUDE_INSTALL_DIR"
    fi
  fi
}

# ---------------------------------------------------- finding the package ---
resolve_latest() {
  info "Looking up the newest package in Anthropic's repository index"
  INDEX_FILE=$WORK/Packages
  curl -fsSL --retry 3 --retry-delay 2 \
    "$REPO_BASE/dists/stable/main/binary-$DEB_ARCH/Packages" -o "$INDEX_FILE" \
    || die "couldn't fetch the package index (is downloads.claude.ai reachable?)"

  REMOTE_PATH=$(grep '^Filename: pool/main/c/claude-desktop/claude-desktop_' "$INDEX_FILE" \
    | cut -d' ' -f2 | sort -V | tail -n 1 || true)
  [ -n "$REMOTE_PATH" ] || die "no claude-desktop package for $DEB_ARCH in the repository index"

  REMOTE_FILE=${REMOTE_PATH##*/}

  # The index lists a SHA-256 for every package; pull out the one for ours.
  REMOTE_SHA=$(awk -v RS='' -v want="Filename: $REMOTE_PATH" '
    {
      found = 0; sha = ""
      n = split($0, L, "\n")
      for (i = 1; i <= n; i++) {
        if (L[i] == want) found = 1
        if (L[i] ~ /^SHA256: /) sha = substr(L[i], 9)
      }
      if (found) { print sha; exit }
    }' "$INDEX_FILE" || true)
}

verify_sha() {
  if [ -z "${REMOTE_SHA:-}" ]; then
    warn "the index lists no SHA-256 for this package; skipping the checksum check"
    return 0
  fi
  local got
  got=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$got" = "$REMOTE_SHA" ]
}

download_deb() {
  mkdir -p "$CACHE_DIR"
  DEB_PATH=$CACHE_DIR/$REMOTE_FILE

  if [ -f "$DEB_PATH" ] && verify_sha "$DEB_PATH"; then
    info "Using the already-downloaded $REMOTE_FILE"
    return 0
  fi

  info "Downloading $REMOTE_FILE"
  local progress=(-sS)
  if [ -t 2 ]; then progress=(-#); fi
  curl -fL "${progress[@]}" --retry 3 --retry-delay 2 \
    -o "$DEB_PATH.part" "$REPO_BASE/$REMOTE_PATH" \
    || { rm -f "$DEB_PATH.part"; die "download failed"; }
  mv "$DEB_PATH.part" "$DEB_PATH"

  if ! verify_sha "$DEB_PATH"; then
    rm -f "$DEB_PATH"
    die "checksum mismatch: the download doesn't match what Anthropic's index lists"
  fi
  info "Checksum OK"
}

# ------------------------------------------------------------- unpacking ----
extract_deb() {
  local deb=$1 dest=$2 data="" f
  mkdir -p "$dest/deb" "$dest/root"

  if have bsdtar; then
    bsdtar -xf "$deb" -C "$dest/deb"
  else
    (cd "$dest/deb" && ar x "$deb")
  fi

  for f in "$dest"/deb/data.tar.*; do
    if [ -e "$f" ]; then data=$f; fi
  done
  [ -n "$data" ] || die "no data.tar.* found inside the .deb"

  if have bsdtar; then
    bsdtar -xf "$data" -C "$dest/root"
  else
    tar -xf "$data" -C "$dest/root"
  fi
}

check_libs() {
  local bin=$1 missing
  if ! have ldd; then
    warn "ldd not found; skipping the shared-library check"
    return 0
  fi
  missing=$(ldd "$bin" 2>&1 | grep 'not found' || true)
  if [ -n "$missing" ]; then
    LIBS_MISSING=1
    warn "some shared libraries the app needs are missing on this system:"
    printf '%s\n' "$missing" | sed 's/^/    /' >&2
    cat >&2 <<EOF
    The app won't start until they're available. Options:
      - install the matching native packages if your system allows it, or
      - fetch the packages from Debian (packages.debian.org, same CPU
        architecture), unpack them with bsdtar, copy the .so files into a
        folder such as ~/claude-libs, and set
            CLAUDE_EXTRA_LIBS="\$HOME/claude-libs"
        in $CONFIG_FILE
EOF
  else
    info "Library check passed: nothing missing"
  fi
}

swap_in_app() {
  local src=$1
  mkdir -p "$(dirname "$INSTALL_DIR")"
  if [ -d "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$WORK/old"
  fi
  if ! mv "$src" "$INSTALL_DIR"; then
    if [ -d "$WORK/old" ]; then mv "$WORK/old" "$INSTALL_DIR"; fi
    die "couldn't move the new version into $INSTALL_DIR (previous version restored)"
  fi
}

# -------------------------------------------------- launcher + integration --
write_config() {
  mkdir -p "$CONFIG_DIR"
  if [ -e "$CONFIG_FILE" ]; then
    info "Keeping your existing settings in $CONFIG_FILE"
    return 0
  fi
  cat > "$CONFIG_FILE" <<'EOF'
# Claude Desktop launcher settings (shell syntax, read by claude-desktop-launcher).

# Extra command-line flags for the app.
# --no-sandbox is needed because Chromium's sandbox helper can't be setuid root
# when the app runs from your home folder. It weakens the browser sandbox.
# Other flags you can try if the window is blank or glitchy:
#   --ozone-platform=wayland     --disable-gpu
CLAUDE_FLAGS="--no-sandbox"

# Colon-separated folder(s) of extra shared libraries, only if the installer
# reported missing ones. Example: CLAUDE_EXTRA_LIBS="$HOME/claude-libs"
CLAUDE_EXTRA_LIBS=""
EOF
}

write_launcher() {
  mkdir -p "$BIN_DIR" "$STATE_DIR"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by %s. Re-run the installer to recreate it.\n' "$SCRIPT_NAME"
    printf 'APP_DIR=%q\n' "$INSTALL_DIR"
    printf 'CONFIG=%q\n' "$CONFIG_FILE"
    printf 'LOG=%q\n' "$LOG_FILE"
    cat <<'EOF'
mkdir -p "$(dirname "$LOG")"
# Keep the log from growing forever; each launch (including claude:// link
# handoffs from the browser) appends to it.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 524288 ]; then
  mv -f "$LOG" "$LOG.old"
fi
exec >>"$LOG" 2>&1
echo "=== $(date) ==="

CLAUDE_FLAGS="--no-sandbox"
CLAUDE_EXTRA_LIBS=""
if [ -r "$CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
fi
if [ -n "$CLAUDE_EXTRA_LIBS" ]; then
  export LD_LIBRARY_PATH="$CLAUDE_EXTRA_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

cd "$APP_DIR" || exit 1
set -f
# CLAUDE_FLAGS is split into words on purpose; "$@" carries claude:// links.
# shellcheck disable=SC2086
exec ./claude-desktop $CLAUDE_FLAGS "$@"
EOF
  } > "$LAUNCHER"
  chmod +x "$LAUNCHER"
}

install_icons() {
  local src=$1/usr/share/icons/hicolor
  if [ -d "$src" ]; then
    mkdir -p "$ICONS_DIR/hicolor"
    cp -r "$src/." "$ICONS_DIR/hicolor/"
  else
    warn "the package ships no icons; the menu entry will use a generic one"
  fi
}

install_desktop_entry() {
  local root=$1 pkg_desktop="" f line
  mkdir -p "$APPS_DIR"

  for f in "$root"/usr/share/applications/*.desktop; do
    if [ -e "$f" ]; then pkg_desktop=$f; break; fi
  done

  if [ -n "$pkg_desktop" ]; then
    # Reuse the packaged entry (correct window class, claude:// handler, menu
    # actions) and only point its Exec lines at our launcher.
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in
        Exec=claude-desktop*)
          printf 'Exec="%s"%s\n' "$LAUNCHER" "${line#Exec=claude-desktop}"
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$pkg_desktop" > "$DESKTOP_FILE"
  else
    warn "the package ships no .desktop file; writing a built-in one"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Claude
Comment=Desktop application for Claude.ai
GenericName=AI Assistant
Keywords=AI;Chat;Assistant;Claude;Code;LLM;
Exec="$LAUNCHER" %U
Icon=claude-desktop
Type=Application
StartupNotify=true
StartupWMClass=com.anthropic.Claude
SingleMainWindow=true
Categories=Utility;Development;
MimeType=x-scheme-handler/claude;application/vnd.anthropic.mcpb;application/vnd.anthropic.skill;
Actions=NewChat;NewCode;

[Desktop Action NewChat]
Name=New Chat
Exec="$LAUNCHER" "claude://claude.ai/new?surface=chat&source=desktop_action"

[Desktop Action NewCode]
Name=New Claude Code Session
Exec="$LAUNCHER" "claude://code/new?source=desktop_action"
EOF
  fi
  chmod +x "$DESKTOP_FILE"
}

refresh_desktop_caches() {
  if have update-desktop-database; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  fi
  local k
  for k in kbuildsycoca6 kbuildsycoca5; do
    if have "$k"; then
      "$k" >/dev/null 2>&1 || true
      break
    fi
  done
}

register_link_handler() {
  if ! have xdg-mime; then
    warn "xdg-mime not found; browser sign-in won't hand back to the app until claude:// is registered"
    return 0
  fi
  xdg-mime default claude-desktop.desktop x-scheme-handler/claude \
    || warn "couldn't register the claude:// link handler"
  local got
  got=$(xdg-mime query default x-scheme-handler/claude 2>/dev/null || true)
  if [ "$got" != "claude-desktop.desktop" ]; then
    warn "claude:// is handled by '${got:-nothing}', not claude-desktop.desktop; browser sign-in may not return to the app"
  fi
}

warn_if_running() {
  if have pgrep && pgrep -f "$INSTALL_DIR/claude-desktop" >/dev/null 2>&1; then
    warn "Claude Desktop looks like it's running. Quit it and relaunch to use the new version."
  fi
}

# ------------------------------------------------------------------ install --
WORK=""
cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}

do_install() {
  LIBS_MISSING=0
  REMOTE_SHA=""

  check_not_root
  check_safe_install_dir
  check_extract_tools
  need sha256sum
  need awk
  need sort
  need mktemp
  if [ -z "$LOCAL_DEB" ]; then
    need curl
    detect_arch
  fi
  check_existing_install_dir

  mkdir -p "$(dirname "$INSTALL_DIR")"
  check_disk_space

  # Work next to the install folder (not in /tmp, which can be a small RAM disk
  # on SteamOS) so the final swap is a cheap rename.
  WORK=$(mktemp -d "$(dirname "$INSTALL_DIR")/.claude-desktop-work.XXXXXX")
  trap cleanup EXIT

  if [ -n "$LOCAL_DEB" ]; then
    [ -f "$LOCAL_DEB" ] || die "no such file: $LOCAL_DEB"
    DEB_PATH=$LOCAL_DEB
    REMOTE_FILE=${LOCAL_DEB##*/}
    warn "installing from a local file; its checksum can't be verified"
  else
    resolve_latest
  fi

  if [ "$FORCE" -eq 0 ] && [ -f "$INSTALL_DIR/$MARKER" ] \
     && [ "$(cat "$INSTALL_DIR/$MARKER")" = "$REMOTE_FILE" ]; then
    info "Already up to date ($REMOTE_FILE). Use --force to reinstall."
    return 0
  fi

  if [ -z "$LOCAL_DEB" ]; then
    download_deb
  fi

  info "Unpacking"
  extract_deb "$DEB_PATH" "$WORK/x"
  ROOT=$WORK/x/root
  SRC=$ROOT/usr/lib/claude-desktop
  [ -x "$SRC/claude-desktop" ] \
    || die "unexpected package layout: $SRC/claude-desktop not found"

  check_libs "$SRC/claude-desktop"

  printf '%s\n' "$REMOTE_FILE" > "$SRC/$MARKER"
  warn_if_running

  info "Installing into $INSTALL_DIR"
  swap_in_app "$SRC"

  info "Creating the launcher and menu entry"
  write_config
  write_launcher
  install_icons "$ROOT"
  install_desktop_entry "$ROOT"
  refresh_desktop_caches
  register_link_handler

  if [ -z "$LOCAL_DEB" ] && [ "$KEEP_DL" -eq 0 ]; then
    rm -f "$DEB_PATH"
  fi

  cat <<EOF

Done: $REMOTE_FILE is installed.

  App folder   $INSTALL_DIR
  Launcher     $LAUNCHER
  Settings     $CONFIG_FILE
  Launch log   $LOG_FILE

Start "Claude" from your application menu (log out and back in if it doesn't
appear yet), or run the launcher directly. Sign-in opens your browser and
returns to the app through a claude:// link.

It runs with --no-sandbox by default (see the settings file). Nothing updates
it automatically: re-run this script to update.
EOF

  if [ "$LIBS_MISSING" -eq 1 ]; then
    printf '\nNote: the library check above reported missing libraries, so the app may not start yet.\n'
  fi
}

# ---------------------------------------------------------------- uninstall --
do_uninstall() {
  check_not_root
  check_safe_install_dir

  info "Removing Claude Desktop"
  rm -rf "$INSTALL_DIR"
  rm -f "$LAUNCHER" "$DESKTOP_FILE"
  rm -f "$ICONS_DIR"/hicolor/*/apps/claude-desktop.png
  rm -rf "$CONFIG_DIR" "$STATE_DIR" "$CACHE_DIR"

  # Drop the claude:// default we registered.
  local f
  for f in "$CONFIG_HOME/mimeapps.list" "$APPS_DIR/mimeapps.list"; do
    if [ -f "$f" ]; then
      sed -i '/claude-desktop\.desktop/d' "$f"
    fi
  done

  refresh_desktop_caches

  cat <<EOF

Removed. Not touched: the app's own data in $CONFIG_HOME/Claude and any
sign-in saved in your desktop keyring. Delete those yourself for a completely
clean slate.
EOF
}

# -------------------------------------------------------------------- main --
main() {
  parse_args "$@"
  case $ACTION in
    help)      usage ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"
