#!/bin/sh
# Dynamic monitor setup: one or two monitors, no hardcoded output names,
# resolutions or positions.
#
# Called on startup and WM reload. Only initialize a new layout, never
# rewrite user desktops or break an existing mirror on reload.

wm() { timeout -k 1 1 bspc "$@"; }
randr() { timeout -k 1 3 xrandr "$@"; }

desktops=$(wm query -D --names) || exit 1
[ -n "$desktops" ] || exit 1
if printf '%s\n' "$desktops" | grep -qvx Desktop; then
    exit 0
fi
if wm query -N -n .window >/dev/null; then
    exit 0
fi
outputs=$(randr -q) || exit 1
CONNECTED=$(printf '%s\n' "$outputs" | awk '$2 == "connected" { print $1 }')
INTERNAL=$(printf '%s\n' "$CONNECTED" | grep -E '^(eDP|LVDS)' | head -n1)
EXTERNAL=$(printf '%s\n' "$CONNECTED" | grep -vE '^(eDP|LVDS|HDMI)' | head -n1)

# Desktop PC / no laptop panel: treat the only monitor as internal.
if [ -z "$INTERNAL" ]; then
    INTERNAL=$(printf '%s\n' "$CONNECTED" | head -n1)
    EXTERNAL=""
fi
[ -z "$INTERNAL" ] && exit 0

if [ -n "$EXTERNAL" ]; then
    randr --output "$INTERNAL" --auto --primary --pos 0x0 \
        --output "$EXTERNAL" --auto --left-of "$INTERNAL" || exit 1

    # External is physically on the left: it gets desktops 1-5.
    wm monitor "$EXTERNAL" -d 1 2 3 4 5
    wm monitor "$INTERNAL" -d 6 7 8 9
    wm wm -O "$EXTERNAL" "$INTERNAL"
else
    randr --output "$INTERNAL" --auto --primary || true
    wm monitor "$INTERNAL" -d 1 2 3 4 5 6 7 8 9
fi
