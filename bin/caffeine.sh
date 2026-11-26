#!/bin/sh
# Per-display X11 idle inhibitor. The icon reflects a successfully enabled
# policy, not a flag created before xset has accepted the request.
export LC_ALL=C
umask 077
runtime="${XDG_RUNTIME_DIR:-$HOME/.cache}"
key=$(printf '%s' "${DISPLAY:-none}" | sed 's/[^a-zA-Z0-9.-]/_/g')
state="$runtime/caffeine-$key.state"
self=$0

x() { timeout -k 1 2 xset "$@"; }

read_x() {
    # The DPMS extension is optional (e.g. Xvfb).
    report=$(x q) || return 1
    set -- $(printf '%s\n' "$report" | awk '
        /timeout:.*cycle:/ { saver=$2; cycle=$4 }
        /Standby:.*Suspend:.*Off:/ { standby=$2; suspend=$4; off=$6 }
        /DPMS is (Enabled|Disabled)/ { status=$3 }
        END { if (saver != "") print saver, cycle, status ? status : "none",
                    standby + 0, suspend + 0, off + 0 }')
    [ "$#" = 6 ] || return 1
    saver=$1 cycle=$2 dpms=$3 standby=$4 suspend=$5 off=$6
}

inhibit() {
    [ "$saver" = 0 ] || x s off || return 1
    case "$dpms" in
        Enabled|Disabled)
            if [ "$standby:$suspend:$off" != 0:0:0 ]; then
                x dpms 0 0 0 || return 1
            fi
            # xset dpms <timeouts> can enable DPMS even if it was disabled.
            if [ "$dpms" = Enabled ] || [ "$standby:$suspend:$off" != 0:0:0 ]; then
                x -dpms || return 1
            fi
            ;;
    esac
}

enforced() {
    read_x &&
        [ "$saver" = 0 ] &&
        { [ "$dpms" = none ] ||
          { [ "$dpms" = Disabled ] && [ "$standby:$suspend:$off" = 0:0:0 ]; }; }
}

restore_x() {
    read -r saved_saver saved_cycle saved_dpms saved_standby saved_suspend saved_off <"$1" ||
        return 1
    x s "$saved_saver" "$saved_cycle" || return 1
    case "$saved_dpms" in
        Enabled) x dpms "$saved_standby" "$saved_suspend" "$saved_off" && x +dpms ;;
        Disabled) x dpms "$saved_standby" "$saved_suspend" "$saved_off" && x -dpms ;;
    esac
}

start_watcher() {
    # A Polybar click may inherit the bar's bspwm subscription. Never let a
    # detached process keep that socket alive after Polybar exits.
    "$(dirname -- "$self")/desktop-no-fds" setsid -f "$self" --watch \
        </dev/null >/dev/null 2>&1 9>&-
}

enable() {
    read_x || return 1
    if [ -f "$state" ]; then
        inhibit && enforced && start_watcher
        return
    fi
    tmp=$(mktemp "$state.XXXXXX") || return 1
    printf '%s %s %s %s %s %s\n' "$saver" "$cycle" "$dpms" "$standby" "$suspend" "$off" >"$tmp"
    if inhibit && enforced && mv -f -- "$tmp" "$state"; then
        start_watcher
    else
        restore_x "$tmp" || true
        rm -f -- "$tmp"
        return 1
    fi
}

disable() {
    [ -f "$state" ] || return 0
    restore_x "$state" && rm -f -- "$state"
}

case "${1:-}" in
    --active) [ -f "$state" ] ;;
    --watch)
        exec 8>"$state.watch"
        flock -n 8 || exit 0
        failures=0
        while [ -f "$state" ]; do
            if (
                exec 9>"$state.lock"
                flock -w 2 9 || exit 0
                [ -f "$state" ] || exit 0
                read_x && inhibit
            ); then
                failures=0
            else
                failures=$((failures + 1))
                [ "$failures" -lt 3 ] || exit 1
            fi
            [ -f "$state" ] || exit 0
            sleep 15 8>&-
        done
        ;;
    --on|--off|--toggle|--restore)
        mkdir -p -- "$runtime" || exit 1
        exec 9>"$state.lock"
        flock -w 2 9 || exit 1
        case "$1" in
            --on) enable ;;
            --off) disable ;;
            --restore) [ ! -f "$state" ] || enable ;;
            --toggle) if [ -f "$state" ]; then disable; else enable; fi ;;
        esac
        ;;
    '')
        colors="$HOME/.config/polybar/colors.ini"
        if [ -f "$state" ]; then
            key=accent icon=󰅶 fallback='#9080da'
        else
            key=fg-dim icon=󰾪 fallback='#928fa3'
        fi
        color=$(awk -F' = ' -v key="$key" '$1 == key {print $2; exit}' "$colors" 2>/dev/null)
        printf '%%{F%s}%s%%{F-}' "${color:-$fallback}" "$icon"
        ;;
    *) echo "usage: caffeine.sh [--on|--off|--toggle|--active]" >&2; exit 2 ;;
esac
