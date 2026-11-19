export PATH="$HOME/.local/bin:$PATH"

# Keyboard layout for startx sessions. Display managers such as ly start
# bspwm directly and skip this file, so bspwmrc repeats the same setup there.
setxkbmap -layout us,ru -option grp:alt_shift_toggle

sxhkd &

# No exec: once bspwm exits, X tears the session down while the panel may
# still be DPMS-off, and the text console would stay black.
bspwm
"$HOME/.local/bin/screen-wake"
