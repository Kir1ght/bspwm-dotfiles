# Prompt for a stronger model: review and harden these dotfiles

Copy everything below the line into the other model's first message. It is
written for a fresh session with no access to my previous conversation.

---

## Role

You are a senior Linux desktop engineer doing a code review of a personal
Arch Linux dotfiles repository. Your job is to find real defects, remove
fragile patterns, and simplify where it is safe — then apply the fixes
yourself. I will test what you change.

## Environment

- Arch Linux, X11 only (no Wayland session).
- Window manager: **bspwm**, started by `ly` (a TTY greeter) through
  `~/.xinitrc`; `bspwm` execs `~/.config/bspwm/bspwmrc` directly.
- Hotkeys: **sxhkd**. Launcher/menus: **rofi**. Bar: **polybar**.
  Compositor: **picom**. Audio: **PipeWire + WirePlumber**. Bluetooth:
  **BlueZ** driven by `bluetoothctl` from shell scripts.
- Hardware: AMD Ryzen 7 7840U (Radeon 780M iGPU), NVIDIA dGPU that stays
  runtime-suspended unless `hdmi-gpu on` is used, MediaTek MT7922
  Wi-Fi/Bluetooth combo, 2560x1600 eDP panel.
- The repository is at `~/bspwm-dotfiles` and is the source of truth;
  `install.sh` copies it into `~/.config`, `~/.local/bin` and `~/bin`.
- `~/bin` is a real directory, not a symlink: scripts are installed to both
  `~/.local/bin` and `~/bin`.

## Paths to review

Primary targets (read all of these first):

| Path | What it is |
| --- | --- |
| `~/bspwm-dotfiles/config/bspwm/bspwmrc` | session startup: keyboard layout, wallpaper, bar, picom, services |
| `~/bspwm-dotfiles/config/polybar/launch.sh` | starts the bar, derives `top_padding` from bar geometry |
| `~/bspwm-dotfiles/config/polybar/config.ini` | bar definitions, module order |
| `~/bspwm-dotfiles/config/polybar/modules.ini` | every polybar module (many `custom/script`) |
| `~/bspwm-dotfiles/config/sxhkd/sxhkdrc` | all keybindings |
| `~/bspwm-dotfiles/bin/*` | 60 helper scripts (see the shortlist below) |
| `~/bspwm-dotfiles/install.sh` | installer: package lists, file copies, udev, services |
| `~/bspwm-dotfiles/bootstrap.sh` | first-run bootstrap |
| `~/bspwm-dotfiles/Builder/` | package list generator used by `install.sh` |
| `~/bspwm-dotfiles/system/udev/*.rules` | udev rules installed to `/etc/udev/rules.d` |
| `~/bspwm-dotfiles/config/wireplumber/wireplumber.conf.d/*.conf` | Bluetooth codec policy (LDAC bitrate cap) |
| `~/bspwm-dotfiles/xinitrc`, `~/bspwm-dotfiles/Xresources`, `~/bspwm-dotfiles/gtkrc-2.0` | session and toolkit defaults |

Scripts worth the most attention:

```
~/bspwm-dotfiles/bin/polybar-devices     # tail=true module: mouse + BT batteries
~/bspwm-dotfiles/bin/polybar-player      # tail=true module, wraps playerctl
~/bspwm-dotfiles/bin/polybar-gpu         # avoids waking the dGPU
~/bspwm-dotfiles/bin/brightness-watch    # tail=true, udevadm monitor loop
~/bspwm-dotfiles/bin/vxe-battery         # python, vendor HID over hidraw
~/bspwm-dotfiles/bin/bluetooth-menu      # rofi menu, pactl/bluetoothctl parsing
~/bspwm-dotfiles/bin/toggle-polybar      # show/hide bar, rewrites top_padding
~/bspwm-dotfiles/bin/screen-wake         # DPMS/backlight recovery
~/bspwm-dotfiles/bin/hdmi-present        # Reverse PRIME projector setup
~/bspwm-dotfiles/bin/hdmi-gpu            # load/unload the NVIDIA driver in X
~/bspwm-dotfiles/bin/touchpad-autoswitch # daemon: pad off while a mouse exists
~/bspwm-dotfiles/bin/xkb-layout-guard    # keeps us,ru across hotplug
~/bspwm-dotfiles/bin/powermenu           # rofi power menu
```

## Known incident — use it as the yardstick

On 2026-11-25 the desktop froze twice. Root cause: `bspwmrc` starts polybar,
so the bar **and every module script inherit bspwm's IPC sockets (fds 3..7)**.
A long-lived module script (`polybar-devices`, `tail = true`) kept one of those
sockets open without reading it; the peer buffer filled with ~213 KB; bspwm
blocked in `sock_alloc_send_pskb`; every `bspc` call then hung, which in turn
hung `launch.sh` (it waited on `bspc query`) and the keybinding that called it.

A first fix is already committed (`2bdee12`): `launch.sh` now starts the bar in
a subshell with fds 3..63 closed, `polybar-devices` does the same defensively,
and `bspc`/`xwininfo` calls are wrapped in `timeout 2`.

Assume there are **more instances of the same class of bug**. Hunt for:

1. Any long-lived process started from `bspwmrc` / `launch.sh` / a polybar
   module that inherits and never drains a file descriptor (sockets, pipes,
   `udevadm monitor`, `inotifywait`, `xev`, `bspc subscribe`, `pactl subscribe`).
2. Unbounded external calls in anything on a hot path (keybinding, bar tick,
   session start): `bspc`, `xrandr`, `bluetoothctl`, `pactl`, `playerctl`,
   `nvidia-smi`, `lsusb`, network tools. Every one of them needs a timeout or a
   non-blocking equivalent.
3. Daemons or loops that can spawn duplicates when a session, bar or theme is
   reloaded (grep for `pgrep` guards and check they actually work).
4. `awk`/`sed` parsing of `pactl`/`bluetoothctl`/`pw-dump` output that breaks on
   locale, multiple cards, or a device disappearing mid-parse.
5. Shell quoting and word-splitting bugs (`for x in $(...)`, unquoted
   variables, `set -e` interactions, traps that do not fire on SIGKILL).
6. Python in `bin/vxe-battery`: file descriptor leaks, `select` on a blocking
   fd, missing timeouts, exceptions that escape as tracebacks.

## What I want from you

1. **Review, then fix.** Do not just list problems: apply minimal, surgical
   patches to the files in `~/bspwm-dotfiles`. Keep the existing style —
   comments explain *why*, not *what*; the repo is documented in English with a
   Russian twin.
2. **Prioritise**: correctness and "cannot hang the desktop" first, resource
   use second, cosmetics last. Skip pure style churn.
3. **Do not break the running session.** Never restart X, bspwm or
   OnlyOffice, and never kill a process that is not one you started. Testing a
   change to `launch.sh` means running it — it restarts only the bar.
4. **Verify what you touch**: `bash -n` / `shellcheck` for shell,
   `python3 -m py_compile` for Python, then run the script once and show its
   output. If a change needs a real device (mouse, headset, projector) and the
   device is absent, say so instead of claiming success.
5. **Keep docs in sync**: `README.md` and `README.ru.md` describe the same
   feature set; if you change behaviour, update both.
6. **Commit in small logical units** with messages in the existing style
   (`area: what changed and why`). No force-push, no rewriting history, no
   squashing my commits. Do not push unless I ask.
7. **Report back in Russian** with: what you found (severity, file, line), what
   you changed, how you verified it, and what you deliberately left alone.

## Constraints

- X11 only. Do not introduce Wayland-only tooling.
- The NVIDIA dGPU must stay runtime-suspended by default; any change that wakes
  it on a timer is a regression (it costs ~2 W idle).
- LDAC is deliberately capped at 330 kbps (`monitor.bluez.rules` on
  `bluez_card.*`): the link is unstable at higher bitrates on this hardware.
  Do not "optimise" it back to auto/990.
- Battery life matters: no polling loop faster than it needs to be, and no
  subprocess spawn per second on the bar unless it is already there.
- The user is not a beginner, but the configs must stay readable: prefer a
  clear comment over a clever one-liner.

## Deliverable format

For each finding:

```
### <severity: critical|high|medium|low> — <file>:<line>
Symptom: what the user sees when it goes wrong.
Cause: the mechanism.
Fix: the patch you applied (diff).
Verified: the command you ran and its output.
```

End with a short list of things you suspect but could not confirm, and what
hardware or state would be needed to confirm them.
