#!/bin/sh

LOCKFILE="/tmp/caffeine.lock"
TOGGLE_LOCK="${XDG_RUNTIME_DIR:-/tmp}/caffeine-toggle.lock"
COLORS="$HOME/.config/polybar/colors.ini"

read_color() {
    awk -F' = ' -v key="$1" '$1 == key {print $2; exit}' "$COLORS" 2>/dev/null
}

case "$1" in
    --toggle)
        # Polybar runs click actions detached, so two rapid clicks can both
        # read the old state and fight over the flag file.
        exec 9>"$TOGGLE_LOCK"
        flock -w 1 9 || exit 1
        if [ -f "$LOCKFILE" ]; then
            rm -f "$LOCKFILE"
            xset s on
            xset +dpms
        else
            touch "$LOCKFILE"
            xset s off
            xset -dpms
        fi
        ;;
    *)
        accent=$(read_color accent)
        dim=$(read_color fg-dim)
        [ -n "$accent" ] || accent="#9080da"
        [ -n "$dim" ] || dim="#928fa3"
        if [ -f "$LOCKFILE" ]; then
            printf '%%{F%s}󰅶%%{F-}' "$accent"
        else
            printf '%%{F%s}󰾪%%{F-}' "$dim"
        fi
        ;;
esac