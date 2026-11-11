#!/usr/bin/env bash
# Disable the touchpad while any external mouse is connected (X11 / xinput).
# Works with USB, Bluetooth and dongles. Ignores the touchpad's internal
# "Mouse" companion device and virtual core pointers.
#
# Disable automation:  pkill -f '[/]home/kiri/.local/bin/touchpad-when-mouse.sh'
# Enable touchpad manually:  /usr/sbin/xinput enable "UNIW0001:00 093A:0255 Touchpad"

XINPUT=/usr/sbin/xinput

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/touchpad-when-mouse.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

# Single instance: without this, restarting bspwm could stack daemons.
if command -v flock >/dev/null 2>&1; then
    exec 9>"${XDG_RUNTIME_DIR:-/tmp}/touchpad-when-mouse.lock"
    flock -n 9 || exit 0
fi

echo "start $(date -Is) DISPLAY=${DISPLAY:-unset} XAUTHORITY=${XAUTHORITY:-unset}"

mouse_present() {
    "$XINPUT" list 2>/dev/null \
        | sed -n 's/.*↳ \(.*\)[[:space:]]\+id=[0-9].*\[slave  pointer.*/\1/p' \
        | grep -viE "$INTERNAL_RE" \
        | grep -viE 'Virtual core|XTEST' \
        | grep -q .
}

while :; do
    # Re-read every cycle: on early bspwm startup xinput may not be ready yet,
    # and touchpad names can theoretically change after suspend/resume.
    mapfile -t TP_LIST < <("$XINPUT" list --name-only 2>/dev/null | grep -i 'touchpad' || true)

    if [ "${#TP_LIST[@]}" -eq 0 ]; then
        sleep 2
        continue
    fi

    INTERNAL_RE='Virtual core|XTEST'
    for tp in "${TP_LIST[@]}"; do
        [ -z "$tp" ] && continue
        base=${tp%%[Tt]ouch[Pp]ad}
        base=${base%%[Tt][Oo][Uu][Cc][Hh][Pp][Aa][Dd]}
        esc=$(printf '%s' "$base" | sed 's/[][^$.*+?(){}\\|]/\\&/g')
        INTERNAL_RE="$INTERNAL_RE|${esc}"
    done

    if mouse_present; then
        for tp in "${TP_LIST[@]}"; do "$XINPUT" disable "$tp" 2>/dev/null; done
    else
        for tp in "${TP_LIST[@]}"; do "$XINPUT" enable  "$tp" 2>/dev/null; done
    fi

    sleep 2
done