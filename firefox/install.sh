#!/usr/bin/env bash
# Install the optional Firefox user.js + chrome/ customization.
# Profile data (cookies, logins, history) is never copied.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE=""

for base in "$HOME/.mozilla/firefox" "$HOME/.config/mozilla/firefox"; do
    [[ -d "$base" ]] || continue
    PROFILE="$(find "$base" -maxdepth 1 -type d -name '*.default-release' 2>/dev/null | head -n1)"
    [[ -n "$PROFILE" ]] && break
done

if [[ -z "$PROFILE" ]]; then
    echo "Firefox profile not found. Start Firefox once, then re-run this script." >&2
    exit 1
fi

if pgrep -x firefox >/dev/null 2>&1; then
    echo "Firefox is running; close it before applying user.js/chrome." >&2
fi

BACKUP="$PROFILE/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
[[ -f "$PROFILE/user.js" ]] && cp -a "$PROFILE/user.js" "$BACKUP/"
[[ -d "$PROFILE/chrome" ]] && cp -a "$PROFILE/chrome" "$BACKUP/"

cp -a "$ROOT/user.js" "$PROFILE/user.js"
mkdir -p "$PROFILE/chrome"
cp -a "$ROOT/chrome/." "$PROFILE/chrome/"

echo "Installed user.js + chrome into: $PROFILE"
echo "Backup: $BACKUP"
