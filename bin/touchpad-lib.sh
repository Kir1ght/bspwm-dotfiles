# shellcheck shell=bash
# Shared helpers for touchpad-when-mouse.sh and touchpad-autoswitch.
#
# The touchpad exposes TWO XInput pointer devices with the same hardware name
# prefix, e.g.
#
#   UNIW0001:00 093A:0255 Mouse      <-- the touchpad's companion pointer
#   UNIW0001:00 093A:0255 Touchpad   <-- the touchpad itself
#
# Both belong to the same physical device and both have to be disabled,
# otherwise the companion keeps the pad alive and gestures keep working.
# Devices are therefore grouped by the name prefix before "Mouse"/"Touchpad",
# not by the word "touchpad" alone.
#
# This file is sourced, never executed.

TP_XINPUT=${TP_XINPUT:-/usr/sbin/xinput}
if [ ! -x "$TP_XINPUT" ]; then
    TP_XINPUT=$(command -v xinput 2>/dev/null || printf '%s' "$TP_XINPUT")
fi

TP_PROC_ROOT=${TP_PROC_ROOT:-/proc}
TP_DEVICES_FILE=${TP_DEVICES_FILE:-/proc/bus/input/devices}

# Parse `xinput list --short` into parallel arrays.
# Sets: TP_DEV_IDS, TP_DEV_NAMES, TP_DEV_STATES
tp_read_devices() {
    TP_DEV_IDS=()
    TP_DEV_NAMES=()
    TP_DEV_STATES=()
    local id name state
    while IFS=$'\t' read -r id name state; do
        [ -n "$id" ] || continue
        name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        TP_DEV_IDS+=("$id")
        TP_DEV_NAMES+=("$name")
        TP_DEV_STATES+=("$state")
    done < <("$TP_XINPUT" list --short 2>/dev/null \
        | sed -n 's/^[^A-Za-z0-9]*[[:space:]]*\(.*\)[[:space:]]\+id=\([0-9]\+\).*\[\([^]]*\)\].*/\2\t\1\t\3/p')
}

# Derive the hardware name prefixes of every touchpad.
# Sets: TP_BASES
tp_compute_bases() {
    TP_BASES=()
    local name base
    for name in "${TP_DEV_NAMES[@]}"; do
        printf '%s' "$name" | grep -qi 'touchpad' || continue
        base=$(printf '%s' "$name" \
            | sed -E 's/[[:space:]]*[Tt][Oo][Uu][Cc][Hh][Pp][Aa][Dd][[:space:]]*$//')
        [ -n "$base" ] && TP_BASES+=("$base")
    done
}

# $1 = XInput device name. True when the device belongs to a touchpad group.
tp_is_group() {
    local base
    for base in "${TP_BASES[@]}"; do
        case $1 in
            "$base"|"$base "*) return 0 ;;
        esac
    done
    return 1
}

# Print the XInput id of every device in a touchpad group.
tp_ids() {
    local i
    for i in "${!TP_DEV_IDS[@]}"; do
        tp_is_group "${TP_DEV_NAMES[$i]}" && printf '%s\n' "${TP_DEV_IDS[$i]}"
    done
}

# True when an external pointing device is visible to X.
tp_xinput_mouse_present() {
    local i name state
    for i in "${!TP_DEV_IDS[@]}"; do
        name=${TP_DEV_NAMES[$i]}
        state=${TP_DEV_STATES[$i]}
        # An enabled pointer is a "slave pointer"; a disabled one is a
        # "floating slave" and must not count.
        case $state in *pointer*) ;; *) continue ;; esac
        case $name in "Virtual core"*|"XTEST"*) continue ;; esac
        tp_is_group "$name" && continue
        return 0
    done
    return 1
}

# True when an external pointing device is visible to the kernel. This is more
# stable than XInput for wireless dongles, which drop out of X for a moment
# while the kernel still lists them.
tp_kernel_mouse_present() {
    [ -r "$TP_DEVICES_FILE" ] || return 1
    local joined=""
    [ "${#TP_BASES[@]}" -gt 0 ] && joined=$(printf '%s\n' "${TP_BASES[@]}")
    TP_BASES_ENV="$joined" awk '
        function flush() {
            if (name != "") {
                names[++n] = name
                physs[n] = phys
                hands[n] = handlers
            }
            name = ""; phys = ""; handlers = ""
        }
        /^N: Name=/ {
            name = $0
            sub(/^N: Name="/, "", name)
            sub(/".*$/, "", name)
        }
        /^P: Phys=/ {
            phys = $0
            sub(/^P: Phys=/, "", phys)
            sub(/[[:space:]]+$/, "", phys)
        }
        /^H: Handlers=/ {
            handlers = $0
            sub(/^H: Handlers=/, "", handlers)
        }
        /^$/ { flush() }
        END {
            flush()
            nb = split(ENVIRON["TP_BASES_ENV"], bases, "\n")
            for (i = 1; i <= n; i++) {
                if (tolower(names[i]) ~ /touchpad/ && physs[i] != "")
                    internal[physs[i]] = 1
            }
            for (i = 1; i <= n; i++) {
                # Same physical device as the touchpad: its companion pointer.
                if (physs[i] in internal) continue
                # Same hardware name as the touchpad: companion pointer.
                skip = 0
                for (j = 1; j <= nb; j++) {
                    if (bases[j] != "" && index(names[i], bases[j]) == 1) {
                        skip = 1
                        break
                    }
                }
                if (skip) continue
                if (names[i] ~ /^(Virtual core|XTEST)/) continue
                if (hands[i] ~ /(^|[[:space:]])mouse[0-9]+([[:space:]]|$)/) {
                    found = 1
                    break
                }
            }
            exit(found ? 0 : 1)
        }
    ' "$TP_DEVICES_FILE" 2>/dev/null
}

# PIDs of the per-session Touchégg client. The system daemon runs as
# `touchegg --daemon` (two argv entries) and must be left alone; the client is
# the process whose argv is exactly one element ending in "touchegg".
tp_touchegg_client_pids() {
    local path pid cmd
    for path in "$TP_PROC_ROOT"/[0-9]*; do
        [ -O "$path" ] || continue
        [ -r "$path/cmdline" ] || continue
        cmd=$(tr '\0' '\n' < "$path/cmdline" 2>/dev/null) || continue
        # More than one argument: daemon or something else.
        case $cmd in *$'\n'*) continue ;; esac
        [ -n "$cmd" ] || continue
        [ "${cmd##*/}" = touchegg ] || continue
        pid=${path##*/}
        [ "$pid" = "$$" ] && continue
        printf '%s\n' "$pid"
    done
}

# Start or stop the Touchégg client. Touchégg reads the pad through libinput,
# so disabling the device in X is not enough to silence gestures.
tp_gestures() {   # on|off
    local pids pid
    if [ "$1" = off ]; then
        pids=$(tp_touchegg_client_pids)
        [ -n "$pids" ] || return 0
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null
        sleep 0.2
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        done
        return 0
    fi

    [ -n "$(tp_touchegg_client_pids)" ] && return 0
    if [ -z "${TP_TOUCHEGG:-}" ] || [ ! -x "${TP_TOUCHEGG:-}" ]; then
        TP_TOUCHEGG=$(command -v touchegg 2>/dev/null) || return 0
    fi
    [ -n "${TP_TOUCHEGG:-}" ] || return 0
    # Close the daemon's lock fd in the long-lived client, otherwise it keeps
    # the single-instance lock after the daemon exits.
    setsid -f "$TP_TOUCHEGG" 9>&- >/dev/null 2>&1 || return 0
}
