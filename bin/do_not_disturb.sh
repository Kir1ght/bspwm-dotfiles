#!/usr/bin/env bash

notify="notify-send"
tmp_disturb="/tmp/bspwm/donotdisturb"
tmp_disturb_colorfile="/tmp/bspwm/donotdisturb/color"
state_file="/tmp/bspwm/donotdisturb/state"
pause_token="${XDG_RUNTIME_DIR:-/tmp}/dunst-pause.token"

mkdir -p "$tmp_disturb"

write_file() {
    local path="$1" value="$2" tmp="$1.$$"
    printf '%s\n' "$value" > "$tmp"
    mv "$tmp" "$path"
}

# Serialise the state check + write. Polybar runs click actions detached, so
# two rapid clicks used to interleave and leave the pause state inverted.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/dnd-toggle.lock"
flock -w 2 9 || exit 1

# Intended state, not dunst's current state: the pause is delayed by 3 s, and
# during that window `dunstctl is-paused` is still false. Using it as the
# source of truth made a quick second press schedule another pause instead of
# cancelling the first one.
if [ -f "$state_file" ]; then
    intended=$(cat "$state_file" 2>/dev/null)
else
    case "$(dunstctl is-paused)" in
        true) intended=on ;;
        *)    intended=off ;;
    esac
fi

# Invalidate any "pause in 3 seconds" job scheduled by a previous toggle.
token="$(date +%s%N)"
write_file "$pause_token" "$token"

if [ "$intended" = "on" ]; then
    write_file "$state_file" off
    dunstctl set-paused false
    $notify "Dunst: Active"
    write_file "$tmp_disturb_colorfile" "#84afdb"
else
    write_file "$state_file" on
    $notify "Dunst: Mute Notify"
    write_file "$tmp_disturb_colorfile" "#c47eb7"
    # Show current notifications for 3 more seconds, then pause. The job acts
    # only if it is still the newest token: toggling DND off within those
    # seconds cancels it instead of letting it pause later.
    (
        exec 9>&-
        sleep 3
        [ "$(cat "$pause_token" 2>/dev/null)" = "$token" ] || exit 0
        dunstctl close
        dunstctl set-paused true
    ) &
fi