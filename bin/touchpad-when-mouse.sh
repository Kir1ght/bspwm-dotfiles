#!/usr/bin/env bash
# Disable the touchpad while any external mouse is connected (X11 / xinput).
# Works with USB, Bluetooth and dongles.
#
# The touchpad exposes two XInput pointers that share a hardware name prefix
# (see touchpad-lib.sh); both are disabled and re-enabled together, otherwise
# the companion "Mouse" interface keeps the pad usable.
#
# Gestures are handled too: Touchégg reads the pad through libinput, so
# `xinput disable` alone does not stop them. The per-session Touchégg client
# is stopped while a mouse is connected and started again when it goes away.
# Only the client is touched; the `touchegg --daemon` system service keeps
# running.
#
# Absence is debounced: a wireless dongle can vanish from X for a moment, so
# the touchpad returns only after several polls without a mouse.
#
# Disable automation:  touchpad-autoswitch off   (Super+Shift+U)
#   or:               pkill -f '[/]touchpad-when-mouse\.sh'
# Enable touchpad manually:  touchpad-autoswitch off
#
# Test knobs (all optional): TP_XINPUT, TP_DEVICES_FILE, TP_PROC_ROOT,
# TP_TOUCHEGG, TP_STATE_DIR, TP_POLL, TP_DEBOUNCE, TP_LOCK.

set -u

self=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
. "$(dirname -- "$self")/touchpad-lib.sh"

STATE_DIR="${TP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}"
LOG="$STATE_DIR/touchpad-when-mouse.log"
OFF_FLAG="$STATE_DIR/touchpad-when-mouse.off"
POLL=${TP_POLL:-2}
DEBOUNCE=${TP_DEBOUNCE:-3}
LOCK=${TP_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/touchpad-when-mouse.lock}

mkdir -p "$STATE_DIR"
exec >>"$LOG" 2>&1

# Single instance: without this, restarting bspwm could stack daemons.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock -n 9 || exit 0
fi

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

log "start DISPLAY=${DISPLAY:-unset} XAUTHORITY=${XAUTHORITY:-unset} poll=${POLL}s debounce=${DEBOUNCE}"

# Last applied mode: mouse | touchpad | paused. Empty until the first poll.
applied=""
absent=$DEBOUNCE          # apply "no mouse" on the first poll without delay
bad_polls=0

apply() {   # $1 = mode, $2 = message
    local mode=$1 msg=$2 i id state
    for i in "${!TP_DEV_IDS[@]}"; do
        tp_is_group "${TP_DEV_NAMES[$i]}" || continue
        id=${TP_DEV_IDS[$i]}
        state=${TP_DEV_STATES[$i]}
        case $mode in
            mouse)
                # Only touch devices that are still enabled; calling disable
                # on an already disabled device just produces X errors.
                case $state in *pointer*) "$TP_XINPUT" disable "$id" 2>/dev/null ;; esac
                ;;
            touchpad|paused)
                case $state in
                    *pointer*) ;;
                    *) "$TP_XINPUT" enable "$id" 2>/dev/null ;;
                esac
                ;;
        esac
    done
    case $mode in
        mouse)            tp_gestures off ;;
        touchpad|paused)  tp_gestures on ;;
    esac
    if [ "$applied" != "$mode" ]; then
        log "$msg"
        applied=$mode
    fi
}

while :; do
    tp_read_devices
    tp_compute_bases

    if [ "${#TP_DEV_IDS[@]}" -eq 0 ]; then
        # XInput is not ready yet (early bspwm startup, post-resume, ...).
        bad_polls=$((bad_polls + 1))
        if [ "$bad_polls" -eq 1 ] || [ $((bad_polls % 30)) -eq 0 ]; then
            log "xinput returned no devices (attempt $bad_polls), retrying"
        fi
        sleep "$POLL" 9>&-
        continue
    fi
    bad_polls=0

    if [ -f "$OFF_FLAG" ]; then
        absent=$DEBOUNCE
        apply paused "automation paused: touchpad on, gestures on"
        sleep "$POLL" 9>&-
        continue
    fi

    present=0
    tp_kernel_mouse_present && present=1
    if [ "$present" -eq 0 ] && tp_xinput_mouse_present; then
        present=1
    fi

    if [ "$present" -eq 1 ]; then
        absent=0
        apply mouse "mouse connected: touchpad off, gestures off"
    else
        [ "$absent" -lt "$DEBOUNCE" ] && absent=$((absent + 1))
        if [ "$absent" -ge "$DEBOUNCE" ]; then
            apply touchpad "mouse disconnected: touchpad on, gestures on"
        fi
        # Otherwise: brief absence (dongle flap) — keep the touchpad off.
    fi

    sleep "$POLL" 9>&-
done
