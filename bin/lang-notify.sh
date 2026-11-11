#!/bin/bash
# Notify on keyboard layout change (optional, not autostarted).
# Polls the XKB group via `xset -q`.
#
# Started from bspwmrc only if you uncomment the line there:
#   pgrep -f lang-notify.sh > /dev/null || ~/bin/lang-notify.sh &
#
# Polling is used instead of `xkb-switch -W` because the event-based variant
# could miss transitions in one direction. This script never switches the
# layout -- bspwmrc configures `us,ru` with grp:alt_shift_toggle.

command -v xset >/dev/null 2>&1 || exit 1

# Delay between xset polls, seconds.
POLL_INTERVAL="${LANG_NOTIFY_POLL:-0.2}"

notify() {
    case "$1" in
        us) notify-send "Язык: EN 🇺🇸" -t 800 -u low -h string:x-dunst-stack-tag:lang ;;
        ru) notify-send "Язык: RU 🇷🇺" -t 800 -u low -h string:x-dunst-stack-tag:lang ;;
        *)  notify-send "Язык: $1" -t 800 -u low -h string:x-dunst-stack-tag:lang ;;
    esac
}

# Print index of the first set bit in the XKB LED mask.
# 0x00000000 -> 0: us, 0x00000200 -> 1: ru.
current_group_index() {
    local led
    led=$(xset -q 2>/dev/null | awk '/LED mask/ { print $4; exit }')
    [ -n "$led" ] || return 1

    awk -v mask="$led" 'BEGIN {
        mask = strtonum("0x" mask)
        for (i = 0; i < 8; i++) {
            if (and(mask, 2 ^ i)) { print i; exit }
        }
    }'
}

layout_code() {
    case "$1" in
        0) printf 'us' ;;
        *) printf 'ru' ;;
    esac
}

last=$(current_group_index 2>/dev/null) || last=''

while :; do
    current=$(current_group_index 2>/dev/null) || {
        sleep "$POLL_INTERVAL"
        continue
    }

    if [ -n "$last" ] && [ "$current" != "$last" ]; then
        notify "$(layout_code "$current")"
    fi
    last=$current
    sleep "$POLL_INTERVAL"
done
