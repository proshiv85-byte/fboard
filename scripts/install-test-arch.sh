#!/usr/bin/env bash
# Installs an fboard test build on Arch Linux and Arch-based distros
# (CachyOS, EndeavourOS, Manjaro, ...).
#
#   bash <(curl -fsSL https://github.com/proshiv85-byte/fboard/releases/download/test-1/install-test-arch.sh)
#
# Uninstall: sudo pacman -R fboard
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

TAG="${FBOARD_TAG:-test-1}"
PKG="fboard-1.0.0-1-x86_64.pkg.tar.zst"
URL="https://github.com/proshiv85-byte/fboard/releases/download/$TAG/$PKG"
DRY="${FBOARD_DRY_RUN:-}"   # set to 1 to download and check without installing

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ -n $DRY ]]; then echo "   (dry run) $*"; else "$@"; fi; }

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (it uses sudo when needed)"
command -v pacman >/dev/null || die "this script is for Arch-based distros (pacman not found)"
[[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported by this test build"
command -v curl >/dev/null || die "curl is needed"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading fboard test build ($TAG)"
curl -fL --progress-bar -o "$tmp/$PKG" "$URL" || die "download failed: $URL"

say "Installing (pacman will pull in gtk3, libpulse, ffmpeg if missing)"
run sudo pacman -U --needed "$tmp/$PKG"

# Sound server: fboard needs PipeWire (pipewire-pulse) or PulseAudio.
if ! pactl info >/dev/null 2>&1; then
  warn "no PulseAudio-compatible sound server found."
  warn "install PipeWire's PulseAudio layer: sudo pacman -S pipewire-pulse   (then log out and in)"
fi

# Global hotkeys read the keyboard directly, which needs the input group.
if id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
  say "You are already in the input group: global hotkeys will work."
else
  echo
  echo "Global hotkeys (and mouse-button hotkeys) need your user in the 'input' group."
  echo "Without it fboard falls back to your desktop's shortcut portal, if it has one."
  read -r -p "Add $USER to the input group now? [Y/n] " ans
  if [[ ! $ans =~ ^[Nn] ]]; then
    run sudo usermod -aG input "$USER"
    warn "log out and back in (or reboot) for the group change to take effect."
  fi
fi

echo
say "Done. Start fboard from your app menu or run: fboard"
echo "    In Discord/games pick 'fboard Microphone' as input (or keep 'Default')."
echo "    Turn off noise suppression in your voice app, it can cut off sounds."
echo "    Uninstall: sudo pacman -R fboard   (settings: ~/.config/fboard, data: ~/.local/share/fboard)"
