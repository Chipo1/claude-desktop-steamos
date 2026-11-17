#!/usr/bin/env bash
#
# claude-desktop-steamos — run the official Claude Desktop (Linux beta) on SteamOS.
#
# SteamOS has a read-only root filesystem, and Anthropic only ships Claude Desktop
# as a .deb for Ubuntu/Debian. This script installs it inside an Ubuntu Distrobox
# container and adds it to the SteamOS app menu.
#
# It also prevents a nasty side effect: by default, the container shares
# ~/.cache/fontconfig with SteamOS, and launching Claude writes a font cache there
# that makes every SteamOS app show squares instead of text. This script gives the
# container its own font cache directory before Claude is ever launched.
#
# Usage: bash setup.sh [--update | --enable-auto-update | --disable-auto-update |
#                        --fix-host-fonts | --uninstall] [--no-export]
#
# Unofficial. Not affiliated with Anthropic or Valve.

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-claude}"
IMAGE="${IMAGE:-ubuntu:26.04}"
# Where Claude keeps your sign-in. Pinning KDE Wallet makes Claude always use it,
# instead of guessing from the environment it was started in. ("basic" is NOT an
# option: Claude refuses to save the sign-in at all without a real keyring.)
# See README "Staying signed in".
PASSWORD_STORE="${PASSWORD_STORE:-kwallet6}"

KEY_URL="https://downloads.claude.ai/claude-desktop/key.asc"
KEY_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
APT_REPO_URL="https://downloads.claude.ai/claude-desktop/apt/stable"
CONTAINER_FONT_CACHE="fontconfig-ubuntu"   # lives at ~/.cache/fontconfig-ubuntu

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
AUTO_UPDATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-desktop-steamos"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_NAME="claude-desktop-update"
LAUNCHER="$HOME/.local/bin/claude-desktop-steamos-launch"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Install the official Claude Desktop Linux beta on SteamOS, inside a Distrobox container.

Usage: bash setup.sh [option]

  (no option)        Install (or repair) Claude Desktop in the '${CONTAINER_NAME}' container
  --update           Update Claude Desktop now (quits Claude first)
  --enable-auto-update   Check for updates every 6 hours in the background
                         (skipped while Claude is open, so it's never updated mid-use)
  --disable-auto-update  Turn the background updates off
  --fix-host-fonts   Quit Claude and rebuild SteamOS's font cache (fixes "squares instead of text")
  --uninstall        Remove the menu entry and the container (keeps ~/.config/Claude)
  --no-export        Install without adding Claude to the SteamOS app menu
  -h, --help         Show this help

Environment variables:
  CONTAINER_NAME     Container name (default: claude)
  IMAGE              Container image (default: ubuntu:26.04)
  PASSWORD_STORE     Where Claude stores your sign-in: kwallet6 (default), kwallet5,
                     gnome-libsecret, or detect (Claude's own choice)
EOF
}

require_distrobox() {
  command -v distrobox >/dev/null 2>&1 || die "distrobox was not found.
Recent SteamOS versions include it. If yours doesn't, install it into your home folder:
  curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local
  curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/extras/install-podman | sh -s -- --prefix ~/.local
then make sure ~/.local/bin is on your PATH and run this script again."
}

container_exists() {
  if command -v podman >/dev/null 2>&1; then
    podman container exists "$CONTAINER_NAME"
  elif command -v docker >/dev/null 2>&1; then
    docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
  else
    return 1
  fi
}

# PIDs of running Claude Desktop processes, excluding this script itself (its own
# path contains "claude-desktop-steamos") and commands that merely mention the
# update timer (e.g. journalctl -u claude-desktop-update).
claude_pids() {
  local pid cmd
  for pid in $(pgrep -f claude-desktop 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    cmd="$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline")" || continue
    case "$cmd" in
      *claude-desktop-steamos*|*setup.sh*|*claude-desktop-update*) continue ;;
    esac
    echo "$pid"
  done
}

quit_claude() {
  local pids
  pids="$(claude_pids)"
  if [ -n "$pids" ]; then
    info "Quitting Claude Desktop"
    echo "$pids" | xargs -r kill 2>/dev/null || true
    sleep 2
  fi
}

# Runs inside the container. Arguments: key URL, key fingerprint, apt repo URL,
# font cache dir name, export flag (1/0).
read -r -d '' CONTAINER_SCRIPT <<'INNER' || true
set -euo pipefail
KEY_URL="$1"; KEY_FINGERPRINT="$2"; APT_REPO_URL="$3"; FONT_CACHE="$4"; EXPORT="$5"
PASSWORD_STORE="$6"
KEYRING=/usr/share/keyrings/claude-desktop-archive-keyring.asc

echo "==> Installing base packages and fonts in the container"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gpg fontconfig \
  fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core

# Must happen before Claude ever launches: give the container its own font cache,
# so it never writes into the ~/.cache/fontconfig that SteamOS reads.
echo "==> Giving the container its own font cache (~/.cache/${FONT_CACHE})"
sudo tee /etc/fonts/conf.d/00-separate-cache.conf >/dev/null <<XML
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Added by claude-desktop-steamos: keep this container's font cache
     separate from the host's ~/.cache/fontconfig (shared home directory). -->
<fontconfig>
  <cachedir prefix="xdg">${FONT_CACHE}</cachedir>
</fontconfig>
XML

echo "==> Downloading and verifying Anthropic's signing key"
sudo curl -fsSLo "$KEYRING" "$KEY_URL"
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME   # don't touch the host's ~/.gnupg
FPR="$(gpg --show-keys --with-colons "$KEYRING" | awk -F: '$1=="fpr"{print $10; exit}')"
rm -rf "$GNUPGHOME"
if [ "$FPR" != "$KEY_FINGERPRINT" ]; then
  sudo rm -f "$KEYRING"
  echo "error: signing key fingerprint is '$FPR', expected '$KEY_FINGERPRINT'. Aborting." >&2
  exit 1
fi
echo "    fingerprint OK: $FPR"

echo "==> Adding Anthropic's apt repository and installing claude-desktop"
echo "deb [arch=amd64,arm64 signed-by=$KEYRING] $APT_REPO_URL stable main" \
  | sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y claude-desktop

echo "==> Building the container's font cache"
fc-cache -f
if [ ! -d "$HOME/.cache/$FONT_CACHE" ]; then
  echo "warning: ~/.cache/$FONT_CACHE was not created; the font cache fix may not be active." >&2
fi

if [ "$EXPORT" = "1" ]; then
  echo "==> Adding Claude to the SteamOS app menu"
  if [ "$PASSWORD_STORE" = "detect" ]; then
    distrobox-export --app claude-desktop
  else
    distrobox-export --app claude-desktop --extra-flags "--password-store=$PASSWORD_STORE"
  fi
fi
INNER

# D-Bus name of the keyring service for the chosen password store.
keyring_service() {
  case "$PASSWORD_STORE" in
    kwallet5)        echo org.kde.kwalletd5 ;;
    gnome-libsecret) echo org.freedesktop.secrets ;;
    *)               echo org.kde.kwalletd6 ;;
  esac
}

# A small host-side launcher that wakes up the keyring service before starting
# Claude. KDE Wallet only starts when something asks for it; Claude merely checks
# whether it's already running, and if not, it can't read your saved sign-in.
install_launcher() {
  local enter service
  enter="$(command -v distrobox-enter || echo /usr/bin/distrobox-enter)"
  service="$(keyring_service)"
  mkdir -p "$(dirname "$LAUNCHER")"
  cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Installed by claude-desktop-steamos. Starts the keyring service (${service})
# before Claude, so Claude can read your saved sign-in. Args go to distrobox-enter.
busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \\
  org.freedesktop.DBus StartServiceByName su ${service} 0 >/dev/null 2>&1 || true
exec ${enter} "\$@"
EOF
  chmod 755 "$LAUNCHER"

  if ! busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
       org.freedesktop.DBus StartServiceByName su "$service" 0 >/dev/null 2>&1; then
    warn "Couldn't start $service; Claude may not stay signed in. See README 'Staying signed in'."
  fi
}

# Point the exported menu entries at the launcher, and pin the password store on
# the extra actions (New chat / New code session) too.
patch_desktop_files() {
  local f found=0
  for f in "$HOME/.local/share/applications/${CONTAINER_NAME}-"*claude*.desktop; do
    [ -f "$f" ] || continue
    found=1
    sed -i -E "s#^Exec=[^ ]*distrobox-enter #Exec=${LAUNCHER} #" "$f"
    if [ "$PASSWORD_STORE" != "detect" ]; then
      sed -i -E "/password-store=/! s#(-- +claude-desktop) \"claude://#\1 --password-store=${PASSWORD_STORE} \"claude://#" "$f"
    fi
  done
  [ "$found" = 1 ] || warn "Couldn't find Claude's menu entry in ~/.local/share/applications to update."
}

do_install() {
  local export_flag="$1"
  case "$PASSWORD_STORE" in
    kwallet6|kwallet5|gnome-libsecret|detect) ;;
    basic) die "PASSWORD_STORE=basic doesn't work: Claude refuses to save your sign-in without a real keyring." ;;
    *) die "PASSWORD_STORE must be kwallet6, kwallet5, gnome-libsecret or detect (got '$PASSWORD_STORE')." ;;
  esac
  require_distrobox
  quit_claude

  if container_exists; then
    info "Using existing container '$CONTAINER_NAME'"
  else
    info "Creating container '$CONTAINER_NAME' from $IMAGE (the first start can take a few minutes)"
    distrobox create --yes --name "$CONTAINER_NAME" --image "$IMAGE"
  fi

  # The container shares $HOME, so a temp file there is visible inside it.
  INNER_TMP="$(mktemp "$HOME/.claude-desktop-steamos.XXXXXX")"
  trap 'rm -f "$INNER_TMP"' EXIT
  printf '%s\n' "$CONTAINER_SCRIPT" > "$INNER_TMP"

  distrobox enter "$CONTAINER_NAME" -- bash "$INNER_TMP" \
    "$KEY_URL" "$KEY_FINGERPRINT" "$APT_REPO_URL" "$CONTAINER_FONT_CACHE" "$export_flag" \
    "$PASSWORD_STORE"

  if [ "$export_flag" = "1" ]; then
    install_launcher
    patch_desktop_files
  fi

  info "Done."
  if [ "$export_flag" = "1" ]; then
    echo "Launch 'Claude' from the app menu and sign in."
  elif [ "$PASSWORD_STORE" = "detect" ]; then
    echo "Launch with: distrobox enter $CONTAINER_NAME -- claude-desktop"
  else
    echo "Launch with: distrobox enter $CONTAINER_NAME -- claude-desktop --password-store=$PASSWORD_STORE"
  fi
  echo "If SteamOS ever shows squares instead of text: bash setup.sh --fix-host-fonts"
  echo "To keep Claude updated automatically: bash setup.sh --enable-auto-update"
}

# Usage: do_update manual|auto
#   manual: quit Claude if it's open, then update.
#   auto:   used by the background timer; does nothing if Claude is open.
do_update() {
  local mode="$1"
  require_distrobox
  container_exists || die "Container '$CONTAINER_NAME' not found. Run 'bash setup.sh' first."
  if [ "$mode" = "auto" ]; then
    if [ -n "$(claude_pids)" ]; then
      info "Claude is open; skipping this update check (will try again later)."
      return 0
    fi
  else
    quit_claude
  fi
  info "Updating Claude Desktop in '$CONTAINER_NAME'"
  distrobox enter "$CONTAINER_NAME" -- bash -c \
    "sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
       -o Dpkg::Options::=--force-confold --only-upgrade claude-desktop"
  info "Done."
  if [ "$mode" = "manual" ]; then
    echo "Start Claude again from the app menu."
  fi
}

do_enable_auto_update() {
  require_distrobox
  container_exists || die "Container '$CONTAINER_NAME' not found. Run 'bash setup.sh' first."
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found; can't set up the update timer."

  # Keep a private copy of this script, so the timer keeps working even if the
  # cloned repo is moved or deleted.
  mkdir -p "$AUTO_UPDATE_DIR" "$SYSTEMD_USER_DIR"
  install -m 755 "$SCRIPT_PATH" "$AUTO_UPDATE_DIR/setup.sh"

  local distrobox_dir
  distrobox_dir="$(dirname "$(command -v distrobox)")"

  cat > "$SYSTEMD_USER_DIR/$UNIT_NAME.service" <<EOF
[Unit]
Description=Update Claude Desktop in the '${CONTAINER_NAME}' Distrobox container

[Service]
Type=oneshot
Environment=CONTAINER_NAME=${CONTAINER_NAME}
Environment=PATH=${distrobox_dir}:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/env bash ${AUTO_UPDATE_DIR}/setup.sh --auto-update-run
EOF

  cat > "$SYSTEMD_USER_DIR/$UNIT_NAME.timer" <<EOF
[Unit]
Description=Check for Claude Desktop updates every 6 hours

[Timer]
OnCalendar=*-*-* 00/6:00:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME.timer"
  info "Automatic updates are on. Claude is checked every 6 hours, but never while it's open."
  echo "Next check:  systemctl --user list-timers $UNIT_NAME.timer"
  echo "Update log:  journalctl --user -u $UNIT_NAME"
  echo "Turn off:    bash setup.sh --disable-auto-update"
}

do_disable_auto_update() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$UNIT_NAME.timer" 2>/dev/null || true
  fi
  rm -f "$SYSTEMD_USER_DIR/$UNIT_NAME.service" "$SYSTEMD_USER_DIR/$UNIT_NAME.timer"
  rm -rf "$AUTO_UPDATE_DIR"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  info "Automatic updates are off."
}

do_fix_host_fonts() {
  quit_claude
  info "Rebuilding SteamOS's font cache"
  rm -rf "$HOME/.cache/fontconfig"
  fc-cache -f
  info "Done. Log out and back in (or reboot) so every app reloads its fonts."
  echo "If the squares come back as soon as Claude starts, run 'bash setup.sh' again:"
  echo "it adds the font cache fix to an existing container."
}

do_uninstall() {
  require_distrobox
  quit_claude
  if [ -f "$SYSTEMD_USER_DIR/$UNIT_NAME.timer" ]; then
    do_disable_auto_update
  fi
  if container_exists; then
    info "Removing the app menu entry"
    distrobox enter "$CONTAINER_NAME" -- distrobox-export --app claude-desktop --delete || true
    info "Removing container '$CONTAINER_NAME'"
    distrobox rm --force "$CONTAINER_NAME"
  else
    warn "Container '$CONTAINER_NAME' not found; nothing to remove."
  fi
  rm -rf "$HOME/.cache/$CONTAINER_FONT_CACHE"
  rm -f "$LAUNCHER"
  info "Done. Your Claude settings are still in ~/.config/Claude; delete that folder to remove them too."
}

main() {
  local action="install" export_flag="1"
  while [ $# -gt 0 ]; do
    case "$1" in
      --update)          action="update" ;;
      --enable-auto-update)  action="enable-auto" ;;
      --disable-auto-update) action="disable-auto" ;;
      --auto-update-run) action="auto-run" ;;   # used by the systemd timer
      --fix-host-fonts)  action="fix-fonts" ;;
      --uninstall)       action="uninstall" ;;
      --no-export)       export_flag="0" ;;
      -h|--help)         usage; exit 0 ;;
      *)                 usage; die "unknown option: $1" ;;
    esac
    shift
  done

  [ "$(id -u)" -ne 0 ] || die "Run this as your normal user (deck), not with sudo."

  case "$action" in
    install)   do_install "$export_flag" ;;
    update)       do_update manual ;;
    auto-run)     do_update auto ;;
    enable-auto)  do_enable_auto_update ;;
    disable-auto) do_disable_auto_update ;;
    fix-fonts) do_fix_host_fonts ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"
