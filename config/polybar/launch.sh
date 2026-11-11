#!/usr/bin/env bash

# Serialize launches: bspwmrc, toggle-polybar and theme reloads can overlap.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/polybar-launch.lock"
# Wait instead of dropping the launch: a theme reload must not be skipped just
# because bspwmrc is starting the bar at the same moment.
flock -w 10 9 || exit 0

# Terminate already running bar instances and WAIT until they are really gone.
# killall only sends SIGTERM and returns at once; polybar occasionally stalls in
# its teardown ("Waiting for spawned processes to end"), e.g. while a module
# script still waits for a network call. A normal bar exits in ~0.6 s, so 1.5 s
# is enough; then SIGKILL keeps every theme reload bounded instead of adding a
# 5 s pause to each wallpaper change.
pkill -x polybar 2>/dev/null
for _ in $(seq 1 15); do
	pgrep -x polybar >/dev/null || break
	sleep 0.1
done
if pgrep -x polybar >/dev/null; then
	# Unkillable teardown: SIGKILL, then reap the script children it orphans
	# (long-lived `time`/`backlight` modules), otherwise they stack up.
	pkill -9 -x polybar 2>/dev/null
	pkill -9 -f "$HOME/bin/brightness-watch" 2>/dev/null
	pkill -9 -f "while :; do date" 2>/dev/null
	sleep 0.2
fi

# A SIGKILLed brightness-watch cannot run its trap, and older versions leaked
# one `udevadm monitor` per bar restart (there were 21 of them). Reap orphaned
# backlight monitors by PID; never `pkill -f`, whose pattern can match the
# caller's own command line.
for pid in $(ps -eo pid=,ppid=,args= |
		awk '$2 == 1 && /udevadm monitor/ && /backlight/ {print $1}'); do
	kill "$pid" 2>/dev/null
done

# Launch bar1 and bar2
echo "---" | tee -a /tmp/polybar1.log /tmp/polybar2.log

# Auto-detect the monitor for [bar/top], т.к. идентификатор (eDP-1 и т.п.) зависит от железа пользователя
export MONITOR=$(xrandr --query | awk '/ primary/{print $1; exit}')
[ -z "$MONITOR" ] && export MONITOR=$(xrandr --query | awk '/ connected/{print $1; exit}')

# Auto-detect a second connected monitor for [bar/top_external] instead of hardcoding
# "HDMI-1-1" - имя внешнего монитора зависит от порта/видеокарты пользователя
export MONITOR_EXTERNAL=$(xrandr --query | awk -v skip="$MONITOR" '/ connected/{if ($1 != skip) {print $1; exit}}')

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

# Run on the desired monitor
if [ -n "$MONITOR_EXTERNAL" ]; then
	polybar top_external -r >>/tmp/polybar1.log 2>&1 9>&- & disown
	polybar top -r >>/tmp/polybar1.log 2>&1 9>&- & disown
	echo "Polybar launched for two monitors"
else
	polybar top -r >>/tmp/polybar1.log 2>&1 9>&- & disown
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
	xwininfo -root -tree 2>/dev/null |
		awk -v suffix="_$1\"" '
			/"polybar-/ && index($0, suffix) {
				for (i = 1; i <= NF; i++) {
					if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
						split($i, px, /[x+]/)
						print px[4] + px[2]
						exit
					}
				}
			}'
}

if command -v bspc >/dev/null 2>&1; then
	for _ in $(seq 1 20); do
		missing=
		for monitor in $(bspc query -M --names); do
			[ -n "$(bar_top_inset "$monitor")" ] || missing=1
		done
		[ -z "$missing" ] && break
		sleep 0.05
	done
	for monitor in $(bspc query -M --names); do
		inset=$(bar_top_inset "$monitor")
		[ -n "$inset" ] && bspc config -m "$monitor" top_padding "$inset"
	done
fi
