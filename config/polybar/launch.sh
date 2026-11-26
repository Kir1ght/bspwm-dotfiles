#!/usr/bin/env bash

action=${1:---start}
case "$action" in
	--start|--reload|--ensure|--hide|--toggle) ;;
	*) echo "usage: $0 [--start|--reload|--ensure|--hide|--toggle]" >&2; exit 2 ;;
esac
: "${DISPLAY:?no X display}"
state="${XDG_STATE_HOME:-$HOME/.local/state}/polybar"
runtime="${XDG_RUNTIME_DIR:-$state}"
key=${DISPLAY//[^a-zA-Z0-9.-]/_}
mkdir -p -- "$runtime" "$state" || exit 1
exec 9>"$runtime/polybar-$key.lock"
flock -w 8 9 || exit 1

bar_pids() {
	local pid
	for pid in $(pgrep -u "$UID" -x polybar); do
		grep -zFxq "DISPLAY=$DISPLAY" "/proc/$pid/environ" 2>/dev/null &&
			printf '%s\n' "$pid"
	done
	return 0
}

wm() { timeout -k 1 1 bspc "$@" 9>&-; }

mapfile -t bars < <(bar_pids)
if [[ $action == --ensure && ${#bars[@]} != 0 ]]; then
	exit 0
fi
if [[ $action == --reload && ${#bars[@]} == 0 ]]; then
	exit 0
fi
if [[ $action == --toggle && ${#bars[@]} != 0 ]]; then
	action=--hide
fi

stop_bars() {
	((${#bars[@]})) || return 0
	# Stop bars on this X display only. Never pattern-kill arbitrary
	# shell commands or process groups: a module click may have opened an app.
	kill -TERM "${bars[@]}" 2>/dev/null || true
	for ((i=0; i<15; i++)); do
		mapfile -t bars < <(bar_pids)
		((${#bars[@]})) || break
		sleep 0.1
	done
	if ((${#bars[@]})); then
		kill -KILL "${bars[@]}" 2>/dev/null || true
		sleep 0.2
		[[ -z $(bar_pids) ]] || { echo "polybar: previous instance did not exit" >&2; return 1; }
	fi
}

if [[ $action == --hide ]]; then
	stop_bars || exit 1
	monitors=$(wm query -M --names 2>/dev/null) || exit 0
	while IFS= read -r monitor; do
		[[ -n $monitor ]] && wm config -m "$monitor" top_padding 0 || true
	done <<<"$monitors"
	exit 0
fi

outputs=$(timeout -k 1 3 xrandr --query 9>&-) || exit 1
# Only active outputs need bars; outputs at the same origin are clones.
read -r MONITOR MONITOR_EXTERNAL < <(awk '
	$2 == "connected" {
		for (i = 3; i <= NF; i++) {
			if ($i !~ /^[0-9]+x[0-9]+[+-][0-9]+[+-][0-9]+$/) continue
			n++; name[n] = $1
			origin[n] = substr($i, match($i, /[+-]/))
			if (!primary || $3 == "primary") primary = n
			break
		}
	}
	END {
		printf "%s", name[primary]
		for (i = 1; i <= n; i++)
			if (origin[i] != origin[primary]) { printf " %s", name[i]; break }
		print ""
	}' <<<"$outputs")
[[ -n $MONITOR ]] || { echo "polybar: no active X output" >&2; exit 1; }
export MONITOR MONITOR_EXTERNAL

# Auto-detect the battery device for [module/battery], т.к. имя отличается между
# производителями (BAT0, BAT1 и т.д.) - тот же фикс, что и в bin/battery-alert
BATTERY_PATH=$(find /sys/class/power_supply -maxdepth 1 -name 'BAT*' 2>/dev/null | head -n1)
[ -n "$BATTERY_PATH" ] && export BATTERY=$(basename "$BATTERY_PATH")

# Auto-detect the backlight device for [module/backlight] вместо захардкоженного
# "amdgpu_bl2" - тот же фикс, что и в bin/brightness
BACKLIGHT_PATH=$(find /sys/class/backlight -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)
[ -n "$BACKLIGHT_PATH" ] && export BACKLIGHT_CARD=$(basename "$BACKLIGHT_PATH")

# Auto-detect the wireless interface for [module/wlan] вместо захардкоженного "wlan0"
export WLAN_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^wl/{print $2; exit}')

# Auto-detect the AC adapter for [module/battery] (AC0, ADP1, ...)
ADAPTER_PATH=$(find /sys/class/power_supply -maxdepth 1 \( -name 'AC*' -o -name 'ADP*' \) 2>/dev/null | head -n1)
[ -n "$ADAPTER_PATH" ] && export ADAPTER=$(basename "$ADAPTER_PATH")

safe_exec="$HOME/.local/bin/desktop-no-fds"
[[ -x $safe_exec ]] || { echo "polybar: missing $safe_exec" >&2; exit 1; }
command -v polybar >/dev/null || exit 1
stop_bars || exit 1
log="$state/$key.log"
[[ ! -f $log || $(stat -c %s "$log") -lt 1048576 ]] || mv -f -- "$log" "$log.1"
start_bar() {
	"$safe_exec" setsid polybar "$1" -r </dev/null >>"$log" 2>&1 9>&- &
	disown
}

if [ -n "$MONITOR_EXTERNAL" ]; then
	start_bar top_external
	start_bar top
	echo "Polybar launched for two monitors"
else
	start_bar top
	echo "Polybar launched for one monitor..."
fi

# bspwm only ever raises monitor padding when a client advertises a strut and
# never lowers it again (src/ewmh.c:ewmh_handle_struts), so a stale or bogus
# value keeps every window pushed down until bspwm is restarted. Derive the
# real top inset from the bar window that landed on each monitor and set it
# explicitly. (The old hardcoded 31 in toggle-polybar was already stale: the
# bar occupies y=8..44 with height 36 at offset-y 0.5%.)
bar_top_inset() {
	# $1 = monitor name; print the bar's bottom edge (y + height) in pixels
	awk -v suffix="_$1\"" '
			/"polybar-/ && index($0, suffix) {
				for (i = 1; i <= NF; i++) {
					if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
						split($i, px, /[x+]/)
						print px[4] + px[2]
						exit
					}
				}
			}' <<<"$tree"
}

# Every bspc call is bounded: when bspwm's IPC is wedged, bspc never returns,
# and an unbounded call here blocks the launcher (and any theme reload that
# waits on its lock) for as long as the bar stays dead.
for ((i=0; i<12; i++)); do
	tree=$(timeout -k 1 1 xwininfo -root -tree 2>/dev/null 9>&-) || exit 0
	if [[ -n $(bar_top_inset "$MONITOR") ]]; then
		[[ -z $MONITOR_EXTERNAL || -n $(bar_top_inset "$MONITOR_EXTERNAL") ]] && break
	fi
	sleep 0.1
done
monitors=$(wm query -M --names 2>/dev/null) || exit 0
while IFS= read -r monitor; do
	[[ -n $monitor ]] || continue
	inset=$(bar_top_inset "$monitor")
	[[ -n $inset ]] && wm config -m "$monitor" top_padding "$inset" || true
done <<<"$monitors"
