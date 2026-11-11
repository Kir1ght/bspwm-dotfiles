#!/bin/bash

# Single instance: bspwmrc re-runs kill-and-start, and two trackers would
# duplicate idle notifications and race each other into screen-lock.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/cursor-tracker.lock"
flock -n 9 || exit 0

# CONFIGURATION
program_name="Cursor Tracker"
wait_time=300
countdown=0

# MOUSE LOCATION VARS
X=0
Y=0

# PREV MOUSE LOCATION VARS
PML_X=0
PML_Y=0

# STATUS
counter=0
protection=0

# FUNCTIONS
installed() {
    command -v xdotool >/dev/null 2>&1 || {
        echo >&2 "$1 required. Please install it first.";
        exit 1;
    }
}
installed "xdotool"

get_cursor_location() {
    eval $(xdotool getmouselocation -s);
}

toggle_protection() {
    protection=$1
    if [ $1 -eq 1 ]; then
        notify "Protection mode was activated." 20000 "security-high"
        printf "\t Protection mode was activated.\n"
    else
        notify "Protection mode was deactivated." 20000 "security-low"
        printf "\t Protection mode was deactivated.\n"
    fi
}
notify() {
    notify-send "$program_name" "$1" -t ${2:-2000} --icon="${3:-security-high}"
}

# START
while :; do
    sleep 1

    if [ -f "/tmp/caffeine.lock" ]; then
        counter=0
        continue
    fi

    get_cursor_location

    if (( $X != $PML_X || $Y != $PML_Y )); then
        PML_X=$X
        PML_Y=$Y

        counter=0
        if [ $protection -eq 1 ]; then
            printf "\t\t The device was locked.\n"
            toggle_protection 0
            $HOME/bin/screen-lock
        fi
        printf "\t The location of the cursor was changed.\n"
    else
        ((counter++))
        printf "(%s/%s)\t The cursor is inactive. X: $X Y: $Y\n" \
             "$counter" "$wait_time"

        if [ $counter -ge $wait_time ] && [ $protection -eq 0 ]; then
            toggle_protection 1
        fi
    fi
done
