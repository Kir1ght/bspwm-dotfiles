#!/usr/bin/env bash
# Disable the touchpad while any external mouse is connected (X11 / xinput).
# Works with USB, Bluetooth and dongles. Ignores the touchpad's internal
# "Mouse" companion device and virtual core pointers.
#
# Disable automation:  touchpad-autoswitch off   (Super+Shift+U)
#   or:               pkill -f '[/]home/kiri/.local/bin/touchpad-when-mouse.sh'
# Enable touchpad manually:  /usr/sbin/xinput enable "UNIW0001:00 093A:0255 Touchpad"

XINPUT=/usr/sbin/xinput

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/touchpad-when-mouse.log"
OFF_FLAG="${XDG_STATE_HOME:-$HOME/.local/state}/touchpad-when-mouse.off"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

# Single instance: without this, restarting bspwm could stack daemons.
if command -v flock >/dev/null 2>&1; then
    exec 9>"${XDG_RUNTIME_DIR:-/tmp}/touchpad-when-mouse.lock"
    flock -n 9 || exit 0
fi

echo "start $(date -Is) DISPLAY=${DISPLAY:-unset} XAUTHORITY=${XAUTHORITY:-unset}"

# Output: id<TAB>name<TAB>state for every input device.
# Matches both enabled devices ("↳ Name  id=15 [slave pointer]") and
# disabled ones ("∼ Name  id=15 [floating slave]").
read_devices() {
    "$XINPUT" list --short 2>/dev/null \
        | sed -n 's/^[^A-Za-z0-9]*[[:space:]]*\(.*\)[[:space:]]\+id=\([0-9]\+\).*\[\([^]]*\)\].*/\2\t\1\t\3/p'
}

while :; do
    TP_IDS=()
    TP_NAMES=()
    DEV_IDS=()
    DEV_NAMES=()
    DEV_STATES=()

    while IFS=$'\t' read -r id name state; do
        [ -z "$id" ] && continue
        name=${name#"∼ "}
        # xinput pads names with spaces before "id="; trim them.
        name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        DEV_IDS+=("$id")
        DEV_NAMES+=("$name")
        DEV_STATES+=("$state")
        if printf '%s' "$name" | grep -qi 'touchpad'; then
            TP_IDS+=("$id")
            TP_NAMES+=("$name")
        fi
    done < <(read_devices)

    # XInput may not be ready yet during early bspwm startup.
    if [ "${#TP_IDS[@]}" -eq 0 ]; then
        sleep 2
        continue
    fi

    # Manual override: `touchpad-autoswitch off` creates this flag.
    if [ -f "$OFF_FLAG" ]; then
        for id in "${TP_IDS[@]}"; do "$XINPUT" enable "$id" 2>/dev/null; done
        sleep 2
        continue
    fi

    # Devices that must NOT count as a mouse: virtual devices and the internal
    # "Mouse" interface that shares the touchpad's name prefix.
    INTERNAL_RE='Virtual core|XTEST'
    for name in "${TP_NAMES[@]}"; do
        base=${name%%[Tt]ouch[Pp]ad}
        base=${base%%[Tt][Oo][Uu][Cc][Hh][Pp][Aa][Dd]}
        esc=$(printf '%s' "$base" | sed 's/[][^$.*+?(){}\\|]/\\&/g')
        INTERNAL_RE="$INTERNAL_RE|${esc}"
    done

    mouse_present=0
    for i in "${!DEV_IDS[@]}"; do
        name=${DEV_NAMES[$i]}
        state=${DEV_STATES[$i]}

        # Only real pointer devices. A disabled touchpad is "floating slave".
        case "$state" in
            *pointer*) ;;
            *) continue ;;
        esac

        case "$name" in
            "Virtual core"*|"XTEST"*) continue ;;
        esac

        if printf '%s' "$name" | grep -qiE "$INTERNAL_RE"; then
            continue
        fi

        mouse_present=1
        break
    done

    if [ "$mouse_present" -eq 1 ]; then
        for id in "${TP_IDS[@]}"; do "$XINPUT" disable "$id" 2>/dev/null; done
    else
        for id in "${TP_IDS[@]}"; do "$XINPUT" enable  "$id" 2>/dev/null; done
    fi

    sleep 2
done