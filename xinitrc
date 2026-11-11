export PATH="$HOME/.local/bin:$PATH"

# Keyboard layout for startx sessions. Display managers such as ly start
# bspwm directly and skip this file, so bspwmrc repeats the same setup there.
setxkbmap -layout us,ru -option grp:alt_shift_toggle

sxhkd &
exec bspwm
