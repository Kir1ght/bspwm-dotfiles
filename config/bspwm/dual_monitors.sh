#!/bin/sh
# Dynamic monitor setup: one or two monitors, no hardcoded output names,
# resolutions or positions.
#
# Called from bspwmrc at startup. It (re)creates the 9 desktops, so avoid
# running it while windows are open -- use bspc manually for live hotplug.

CONNECTED=$(xrandr -q | awk '/ connected/ {print $1}')
INTERNAL=$(printf '%s\n' "$CONNECTED" | grep -E '^(eDP|LVDS)' | head -n1)
EXTERNAL=$(printf '%s\n' "$CONNECTED" | grep -vE '^(eDP|LVDS)' | head -n1)

# Desktop PC / no laptop panel: treat the only monitor as internal.
if [ -z "$INTERNAL" ]; then
    INTERNAL="$EXTERNAL"
    EXTERNAL=""
fi
[ -z "$INTERNAL" ] && exit 0

if [ -n "$EXTERNAL" ]; then
    xrandr --output "$INTERNAL" --auto --primary --pos 0x0 || exit 1
    xrandr --output "$EXTERNAL" --auto --left-of "$INTERNAL" || true

    # External is physically on the left: it gets desktops 1-5.
    bspc monitor "$EXTERNAL" -d 1 2 3 4 5
    bspc monitor "$INTERNAL" -d 6 7 8 9
    bspc wm -O "$EXTERNAL" "$INTERNAL"
else
    xrandr --output "$INTERNAL" --auto --primary --pos 0x0 || true
    bspc monitor "$INTERNAL" -d 1 2 3 4 5 6 7 8 9
fi
