#!/usr/bin/env bash
# =============================================================================
#  One-command bootstrap for a fresh Arch Linux / CachyOS machine.
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/Kir1ght/bspwm-dotfiles/main/bootstrap.sh | bash
#    # or, after cloning:
#    ./bootstrap.sh --with-whisper
#
#  Environment:
#    DOTFILES_REPO   git URL (default: https://github.com/Kir1ght/bspwm-dotfiles.git)
#    DOTFILES_DIR    checkout directory (default: ~/bspwm-dotfiles)
# =============================================================================
set -euo pipefail

REPO_URL="${DOTFILES_REPO:-https://github.com/Kir1ght/bspwm-dotfiles.git}"
DEST="${DOTFILES_DIR:-$HOME/bspwm-dotfiles}"

log() { printf '\033[34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merr\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "Run as a normal user, not as root."

if ! command -v pacman >/dev/null 2>&1; then
    die "pacman not found. Install Arch Linux or CachyOS first."
fi

if ! command -v git >/dev/null 2>&1; then
    log "Installing git..."
    sudo pacman -S --needed --noconfirm git
fi

if [[ -d "$DEST/.git" ]]; then
    log "Updating $DEST"
    git -C "$DEST" pull --ff-only
else
    log "Cloning $REPO_URL -> $DEST"
    git clone "$REPO_URL" "$DEST"
fi

[[ -x "$DEST/install.sh" ]] || chmod +x "$DEST/install.sh"
log "Running install.sh $*"
exec bash "$DEST/install.sh" "$@"