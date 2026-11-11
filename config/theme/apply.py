#!/usr/bin/env python3
"""Build a dark UI palette from the current wallpaper.

The wallpaper only supplies the *hue*: backgrounds stay dark and neutral,
the accent is the most vivid color cluster, semantic colors are muted.
Everything is regenerated whenever the wallpaper changes.

Generated files:
  ~/.config/polybar/colors.ini
  ~/.config/alacritty/theme-colors.toml
  ~/.config/rofi/theme.rasi
  ~/.config/bspwm/colors.sh
  ~/.config/zathura/zathurarc       (colors only)
  ~/.config/bspwm/dunstrc           (colors only)
  ~/.config/gtk-3.0/settings.ini    (theme name only)
  ~/.config/gtk-4.0/settings.ini    (theme name only)
  ~/.config/gtk-4.0/gtk.css
  ~/.config/gtk-4.0/gtk-dark.css
  ~/.themes/Dynamic                 (recolored copy of Dracula)
  ~/.cache/theme/palette.json
"""

from __future__ import annotations

import argparse
import colorsys
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()
CFG = HOME / ".config"
CACHE = HOME / ".cache" / "theme"
FEH_BG = HOME / ".fehbg"
CURRENT_LINK = HOME / ".current_wallpaper"
LOCK_FILE = CACHE / "apply.lock"
REQUEST_FILE = CACHE / "apply.request"
DEFAULT_DEBOUNCE = 0.15
MAGICK = shutil.which("magick") or shutil.which("convert")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def hsl_hex(h: float, s: float, l: float) -> str:
    r, g, b = colorsys.hls_to_rgb((h % 360) / 360.0, clamp(l), clamp(s))
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))


def hex_rgb(value: str) -> tuple[float, float, float]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def luminance(value: str) -> float:
    r, g, b = hex_rgb(value)

    def channel(x: float) -> float:
        return x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4

    r, g, b = channel(r), channel(g), channel(b)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    if la < lb:
        la, lb = lb, la
    return (la + 0.05) / (lb + 0.05)


def lighten(value: str, dl: float = 0.08, ds: float = 0.04) -> str:
    r, g, b = hex_rgb(value)
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    return hsl_hex(h * 360, s + ds, l + dl)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def pgrep(name: str) -> bool:
    return run(["pgrep", "-x", name]).returncode == 0


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # A unique temporary name keeps concurrent writers from clobbering each
    # other's file. The lock normally prevents this, but `--show` and other
    # one-off callers can still write at the same time.
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def read_request() -> str | None:
    """Return the token of the newest apply request, ignoring dead waiters."""
    try:
        token = REQUEST_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not token:
        return None
    # Requests from older versions were JSON; they cannot be fulfilled, so
    # drop them instead of wedging the pipeline forever.
    pid_text = token.split(":", 1)[0]
    if not pid_text.isdigit():
        try:
            REQUEST_FILE.unlink()
        except OSError:
            pass
        return None
    # A waiter killed while blocked must not keep every future apply stale.
    if int(pid_text) != os.getpid():
        try:
            os.kill(int(pid_text), 0)
        except ProcessLookupError:
            try:
                REQUEST_FILE.unlink()
            except OSError:
                pass
            return None
        except OSError:
            pass
    return token


def write_request(token: str) -> None:
    write_atomic(REQUEST_FILE, token + "\n")


def log(message: str) -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with (CACHE / "apply.log").open("a", encoding="utf-8") as handle:
        handle.write(f"[{stamp}] {message}\n")


# --------------------------------------------------------------------------
# wallpaper and palette
# --------------------------------------------------------------------------

def current_wallpaper(explicit: str | None) -> Path | None:
    if explicit:
        path = Path(explicit).expanduser()
        return path if path.is_file() else None
    if FEH_BG.is_file():
        text = FEH_BG.read_text(encoding="utf-8", errors="replace")
        match = re.search(r'--bg-\S+\s+"([^"]+)"', text)
        if not match:
            match = re.search(r"--bg-\S+\s+'([^']+)'", text)
        if not match:
            match = re.search(r"--bg-\S+\s+(\S+)", text)
        if match:
            path = Path(match.group(1)).expanduser()
            if path.is_file():
                return path
    try:
        if (CURRENT_LINK.is_symlink() or CURRENT_LINK.exists()):
            path = CURRENT_LINK.resolve()
            if path.is_file():
                return path
    except OSError:
        pass
    cached = CACHE / "palette.json"
    if cached.is_file():
        try:
            data = json.loads(cached.read_text(encoding="utf-8"))
            path = Path(data.get("wallpaper", ""))
            if path.is_file():
                return path
        except Exception:
            pass
    return None


def extract_colors(path: Path) -> list[dict]:
    if not MAGICK:
        raise RuntimeError("ImageMagick (magick/convert) is required")
    result = run([
        MAGICK, str(path),
        "-auto-orient",
        # Downsample while decoding JPEGs instead of loading the full image.
        # This keeps rapid wallpaper changes from spiking RAM/CPU.
        "-define", "jpeg:size=480x480",
        "-thumbnail", "240x240",
        "-colors", "32",
        "-depth", "8",
        "-format", "%c",
        "histogram:info:-",
    ])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "ImageMagick failed")

    colors: list[dict] = []
    for line in result.stdout.splitlines():
        match = re.search(r"(\d+):.*#([0-9A-Fa-f]{6})", line)
        if not match:
            continue
        count = int(match.group(1))
        raw = match.group(2).lower()
        r, g, b = (int(raw[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
        h, l, s = colorsys.rgb_to_hls(r, g, b)
        colors.append({
            "hex": "#" + raw,
            "count": count,
            "h": h * 360,
            "s": s,
            "l": l,
        })
    if not colors:
        raise RuntimeError("no colors extracted")
    return colors


def pick_accent(colors: list[dict]) -> tuple[float, float]:
    total = sum(c["count"] for c in colors) or 1
    bins: dict[int, list[tuple[float, dict]]] = {}

    for color in colors:
        if color["l"] < 0.14 or color["l"] > 0.90 or color["s"] < 0.22:
            continue
        weight = color["count"] / total
        score = (weight ** 0.45) * (color["s"] ** 1.6) * (1 - abs(color["l"] - 0.60))
        # Skin tones are common in anime wallpapers and make poor accents.
        if 8 <= color["h"] <= 45 and color["l"] > 0.45:
            score *= 0.25
        if score <= 0:
            continue
        key = int(color["h"] // 15) % 24
        bins.setdefault(key, []).append((score, color))

    if not bins:
        best = max(colors, key=lambda c: c["s"])
        return best["h"], max(best["s"], 0.45)

    def merged(key: int) -> list[tuple[float, dict]]:
        group: list[tuple[float, dict]] = []
        for neighbor in (key - 1, key, key + 1):
            group.extend(bins.get(neighbor % 24, []))
        return group

    best_key = max(bins, key=lambda k: sum(score for score, _ in merged(k)))
    group = merged(best_key)
    _, representative = max(group, key=lambda item: item[0])
    total_weight = sum(score for score, _ in group) or 1
    saturation = sum(score * color["s"] for score, color in group) / total_weight
    return representative["h"], max(representative["s"], saturation, 0.50)


def build_palette(hue: float, saturation: float) -> dict[str, str]:
    bg = hsl_hex(hue, 0.14, 0.085)
    bg_alt = hsl_hex(hue, 0.15, 0.135)
    bg_light = hsl_hex(hue, 0.14, 0.21)
    fg = hsl_hex(hue, 0.06, 0.93)
    fg_dim = hsl_hex(hue, 0.10, 0.60)
    accent = hsl_hex(hue, max(saturation, 0.55), 0.68)
    accent2 = hsl_hex(hue + 32, 0.50, 0.70)
    accent3 = hsl_hex(hue - 32, 0.50, 0.70)
    red = hsl_hex(355, 0.55, 0.66)
    green = hsl_hex(140, 0.35, 0.62)
    yellow = hsl_hex(50, 0.50, 0.70)
    orange = hsl_hex(28, 0.55, 0.68)
    cyan = hsl_hex(185, 0.35, 0.65)
    magenta = accent2
    color15 = hsl_hex(hue, 0.04, 0.97)

    if contrast(fg, bg) < 7:
        fg = hsl_hex(hue, 0.03, 0.96)
    if contrast(accent, bg) < 4.5:
        accent = hsl_hex(hue, min(saturation, 0.60), 0.76)

    palette = {
        "bg": bg,
        "bg_alt": bg_alt,
        "bg_light": bg_light,
        "fg": fg,
        "fg_dim": fg_dim,
        "accent": accent,
        "accent_bright": lighten(accent, 0.08, 0.05),
        "accent2": accent2,
        "accent2_bright": lighten(accent2, 0.08, 0.05),
        "accent3": accent3,
        "red": red,
        "red_bright": lighten(red, 0.08, 0.05),
        "green": green,
        "green_bright": lighten(green, 0.08, 0.05),
        "yellow": yellow,
        "yellow_bright": lighten(yellow, 0.08, 0.05),
        "orange": orange,
        "cyan": cyan,
        "cyan_bright": lighten(cyan, 0.08, 0.05),
        "magenta": magenta,
        "magenta_bright": lighten(magenta, 0.08, 0.05),
        "color0": bg_alt,
        "color7": fg,
        "color8": fg_dim,
        "color15": color15,
        "background": "#cc" + bg.lstrip("#"),
        "dark_light": bg_light,
        "active_light": fg_dim,
    }
    palette["color1"] = red
    palette["color2"] = green
    palette["color3"] = yellow
    palette["color4"] = accent
    palette["color5"] = magenta
    palette["color6"] = cyan
    palette["color9"] = palette["red_bright"]
    palette["color10"] = palette["green_bright"]
    palette["color11"] = palette["yellow_bright"]
    palette["color12"] = palette["accent_bright"]
    palette["color13"] = palette["magenta_bright"]
    palette["color14"] = palette["cyan_bright"]
    return palette


# --------------------------------------------------------------------------
# writers
# --------------------------------------------------------------------------

def write_polybar(palette: dict[str, str], wallpaper: Path) -> None:
    lines = [
        "; Generated from " + wallpaper.name,
        "; by ~/.config/theme/apply.py — do not edit by hand",
        "[colors]",
        f"background = {palette['background']}",
        f"foreground = {palette['fg']}",
        "",
    ]
    for index in range(16):
        lines.append(f"color{index} = {palette[f'color{index}']}")
    lines += [
        "",
        f"dark-light = {palette['bg_light']}",
        f"active-light = {palette['fg_dim']}",
        f"bg-alt = {palette['bg_alt']}",
        f"bg-light = {palette['bg_light']}",
        f"fg-dim = {palette['fg_dim']}",
        f"accent = {palette['accent']}",
        f"accent2 = {palette['accent2']}",
        f"accent3 = {palette['accent3']}",
        f"red = {palette['red']}",
        f"green = {palette['green']}",
        f"yellow = {palette['yellow']}",
        f"orange = {palette['orange']}",
        f"cyan = {palette['cyan']}",
        f"magenta = {palette['magenta']}",
    ]
    write_atomic(CFG / "polybar" / "colors.ini", "\n".join(lines) + "\n")


def write_alacritty(palette: dict[str, str]) -> None:
    text = f"""# Generated by ~/.config/theme/apply.py — do not edit by hand
[colors.primary]
background = "{palette['bg']}"
foreground = "{palette['fg']}"

[colors.cursor]
text = "{palette['bg']}"
cursor = "{palette['fg']}"

[colors.selection]
text = "{palette['fg']}"
background = "{palette['bg_light']}"

[colors.normal]
black = "{palette['color0']}"
red = "{palette['red']}"
green = "{palette['green']}"
yellow = "{palette['yellow']}"
blue = "{palette['accent']}"
magenta = "{palette['magenta']}"
cyan = "{palette['cyan']}"
white = "{palette['fg']}"

[colors.bright]
black = "{palette['fg_dim']}"
red = "{palette['red_bright']}"
green = "{palette['green_bright']}"
yellow = "{palette['yellow_bright']}"
blue = "{palette['accent_bright']}"
magenta = "{palette['magenta_bright']}"
cyan = "{palette['cyan_bright']}"
white = "{palette['color15']}"
"""
    write_atomic(CFG / "alacritty" / "theme-colors.toml", text)


def write_rofi(palette: dict[str, str]) -> None:
    text = f"""/* Generated by ~/.config/theme/apply.py — do not edit by hand */
* {{
    bg-col:         {palette['bg']};
    bg-col-light:   {palette['bg_light']};
    border-col:     {palette['accent']};
    selected-col:   {palette['bg_light']};
    blue:           {palette['accent']};
    fg-col:         {palette['fg']};
    fg-col2:        {palette['accent2']};
    grey:           {palette['fg_dim']};
    width:          600;
}}
"""
    write_atomic(CFG / "rofi" / "theme.rasi", text)


def write_bspwm(palette: dict[str, str]) -> None:
    text = f"""#!/bin/sh
# Generated by ~/.config/theme/apply.py
FOCUSED_BORDER='{palette['accent']}'
NORMAL_BORDER='{palette['bg_light']}'
ACTIVE_BORDER='{palette['accent2']}'
PRESEL_FEEDBACK='{palette['fg_dim']}'
"""
    write_atomic(CFG / "bspwm" / "colors.sh", text)


def patch_dunst(palette: dict[str, str]) -> None:
    path = CFG / "bspwm" / "dunstrc"
    if not path.is_file():
        return
    section_colors = {
        "global": {"frame_color": palette["accent"], "separator_color": palette["bg_light"]},
        "urgency_low": {"background": palette["bg"], "frame_color": palette["fg_dim"],
                        "foreground": palette["fg"]},
        "urgency_normal": {"background": palette["bg"], "frame_color": palette["accent"],
                           "foreground": palette["fg"]},
        "urgency_critical": {"background": palette["bg"], "frame_color": palette["red"],
                             "foreground": palette["fg"]},
    }
    result: list[str] = []
    section = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        header = re.match(r"\s*\[(.+?)\]", line)
        if header:
            section = header.group(1)
            result.append(line)
            continue
        replaced = False
        for key, value in section_colors.get(section, {}).items():
            if re.match(rf"\s*{key}\s*=", line):
                indent = re.match(r"(\s*)", line).group(1)
                result.append(f'{indent}{key} = "{value}"')
                replaced = True
                break
        if not replaced:
            result.append(line)
    write_atomic(path, "\n".join(result) + "\n")


def patch_zathura(palette: dict[str, str]) -> None:
    path = CFG / "zathura" / "zathurarc"
    if not path.is_file():
        return
    key_map = {
        "notification-error-bg": "red",
        "notification-error-fg": "fg",
        "notification-warning-bg": "orange",
        "notification-warning-fg": "fg",
        "notification-bg": "bg",
        "notification-fg": "fg",
        "completion-bg": "bg",
        "completion-fg": "fg_dim",
        "completion-group-bg": "bg",
        "completion-group-fg": "fg_dim",
        "completion-highlight-bg": "bg_light",
        "completion-highlight-fg": "fg",
        "index-bg": "bg",
        "index-fg": "fg",
        "index-active-bg": "bg_light",
        "index-active-fg": "fg",
        "inputbar-bg": "bg",
        "inputbar-fg": "fg",
        "statusbar-bg": "bg",
        "statusbar-fg": "fg",
        "highlight-color": "orange",
        "highlight-active-color": "accent2",
        "default-bg": "bg",
        "default-fg": "fg",
        "render-loading-fg": "bg",
        "render-loading-bg": "fg",
        "recolor-lightcolor": "bg",
        "recolor-darkcolor": "fg",
    }
    result: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r'(\s*set\s+)(\S+)(\s+)"[^"]*"(.*)$', line)
        if match and match.group(2) in key_map:
            key = key_map[match.group(2)]
            result.append(f'{match.group(1)}{match.group(2)}{match.group(3)}"{palette[key]}"{match.group(4)}')
        else:
            result.append(line)
    write_atomic(path, "\n".join(result) + "\n")


DRACULA_TO_PALETTE = {
    "#282a36": "bg",
    "#1e1f29": "bg_alt",
    "#21222c": "bg_alt",
    "#44475a": "bg_light",
    "#6272a4": "fg_dim",
    "#f8f8f2": "fg",
    "#f8f8f8": "fg",
    "#fefefe": "color15",
    "#f3f3f3": "fg",
    "#dedede": "fg_dim",
    "#bd93f9": "accent",
    "#ff79c6": "magenta",
    "#8be9fd": "cyan",
    "#50fa7b": "green",
    "#50fa7a": "green",
    "#ff5555": "red",
    "#f1fa8c": "yellow",
    "#ffb86c": "orange",
    "#ff6e6e": "red_bright",
    "#69ff94": "green_bright",
    "#ffffa5": "yellow_bright",
    "#d6acff": "accent_bright",
    "#ff92df": "magenta_bright",
    "#a4ffff": "cyan_bright",
    "#33cbbf": "cyan",
    "#00b0ff": "accent",
    "#53a93f": "green",
    "#f57900": "orange",
    "#df253f": "red",
    "#31363d": "bg_light",
    "#2d2d2d": "bg_alt",
}


def apply_gtk(palette: dict[str, str], cancelled=None) -> None:
    """Recolor the installed Dracula GTK theme and activate it as 'Dynamic'."""
    source = HOME / ".themes" / "Dracula"
    target = HOME / ".themes" / "Dynamic"
    if not source.is_dir():
        log("gtk: ~/.themes/Dracula not found, skipped")
        return

    check = cancelled if cancelled is not None else (lambda: False)

    stamp = "|".join(palette[key] for key in ("bg", "fg", "accent", "accent2"))
    marker = target / ".palette"
    settings_ok = True
    for relative in ("gtk-3.0/settings.ini", "gtk-4.0/settings.ini"):
        settings = CFG / relative
        try:
            settings_ok = settings_ok and "gtk-theme-name=Dynamic" in settings.read_text(encoding="utf-8")
        except OSError:
            settings_ok = False
    if (target.is_dir() and marker.is_file()
            and marker.read_text(encoding="utf-8").strip() == stamp
            and settings_ok and (CFG / "gtk-4.0" / "gtk.css").is_file()):
        log("gtk: up to date")
        return

    if check():
        log("gtk: skipped; wallpaper changed")
        return

    # Refresh from the pristine source so a second wallpaper change is clean.
    shutil.copytree(source, target, dirs_exist_ok=True)

    mapping = {key: palette[value] for key, value in DRACULA_TO_PALETTE.items()}
    text_suffixes = {".css", ".scss", ".svg", ".qml", ".rc", ".theme", ".xml"}

    for position, path in enumerate(target.rglob("*")):
        # This is the slow part (thousands of files). Stop as soon as the user
        # moves to another wallpaper: the newer apply will recolor from source.
        if position % 64 == 0 and check():
            log("gtk: aborted mid-recolor; wallpaper changed")
            return
        if not path.is_file() or path.suffix.lower() not in text_suffixes:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        changed = re.sub(
            r"#[0-9a-fA-F]{6}",
            lambda match: mapping.get(match.group(0).lower(), match.group(0)),
            text,
        )
        if changed != text:
            try:
                write_atomic(path, changed)
            except OSError:
                pass

    if check():
        log("gtk: aborted before commit; wallpaper changed")
        return

    index = target / "index.theme"
    if index.is_file():
        try:
            text = index.read_text(encoding="utf-8").replace("Name=Dracula", "Name=Dynamic")
            write_atomic(index, text)
        except OSError:
            pass

    gtk4 = target / "gtk-4.0"
    user_gtk4 = CFG / "gtk-4.0"
    user_gtk4.mkdir(parents=True, exist_ok=True)
    for name in ("gtk.css", "gtk-dark.css"):
        candidate = gtk4 / name
        if candidate.is_file():
            try:
                shutil.copyfile(candidate, user_gtk4 / name)
            except OSError:
                pass

    for settings in (CFG / "gtk-3.0" / "settings.ini", CFG / "gtk-4.0" / "settings.ini"):
        if not settings.is_file():
            continue
        try:
            text = settings.read_text(encoding="utf-8")
            changed = re.sub(r"(?m)^gtk-theme-name=.*$", "gtk-theme-name=Dynamic", text)
            if changed != text:
                write_atomic(settings, changed)
        except OSError:
            pass
    write_atomic(marker, stamp + "\n")
    log("gtk: recolored Dracula -> Dynamic")


# --------------------------------------------------------------------------
# reload
# --------------------------------------------------------------------------

def reload_polybar() -> None:
    if not pgrep("polybar"):
        return
    # Always relaunch through launch.sh. `polybar-msg cmd restart` is ~4 ms when
    # it works, but repeated in-place restarts wedge the bar: under a burst of
    # dozens of restarts it stops answering IPC (and the next `cmd restart`
    # blocks in poll() forever). launch.sh kills/waits/starts the bar in ~1 s
    # now that brightness-watch releases its udevadm child on SIGTERM, and it
    # also re-derives bspwm's top padding.
    launch = CFG / "polybar" / "launch.sh"
    if not launch.is_file():
        return
    try:
        result = run([str(launch)], timeout=20)
    except subprocess.TimeoutExpired:
        log("polybar: launch.sh timed out")
        return
    if result.returncode == 0:
        log("polybar: restarted via launch.sh")
    else:
        log(f"polybar: launch.sh failed: {result.stderr.strip()}")


def reload_dunst() -> None:
    if not pgrep("dunst"):
        return
    # dunstctl reload re-reads the config in place: no window where the old
    # daemon still owns org.freedesktop.Notifications and the new one exits.
    ctl = shutil.which("dunstctl")
    if ctl:
        try:
            result = run([ctl, "reload"], timeout=10)
        except subprocess.TimeoutExpired:
            result = None
        if result is not None and result.returncode == 0:
            log("dunst: reloaded via dunstctl")
            return
    run(["pkill", "-x", "dunst"])
    for _ in range(50):
        if not pgrep("dunst"):
            break
        time.sleep(0.1)
    if (CFG / "bspwm" / "dunstrc").is_file():
        subprocess.Popen(
            ["dunst", "-config", str(CFG / "bspwm" / "dunstrc")],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        log("dunst: restarted")


def apply_bspwm(palette: dict[str, str]) -> None:
    if not pgrep("bspwm"):
        return
    for key, value in (
        ("focused_border_color", palette["accent"]),
        ("normal_border_color", palette["bg_light"]),
        ("active_border_color", palette["accent2"]),
        ("presel_feedback_color", palette["fg_dim"]),
    ):
        run(["bspc", "config", key, value])
    log("bspwm: border colors applied")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a palette from the wallpaper")
    parser.add_argument("--wallpaper", help="wallpaper path (default: ~/.fehbg)")
    parser.add_argument("--no-reload", action="store_true", help="do not restart bars/daemons")
    parser.add_argument("--no-gtk", action="store_true", help="do not recolor the GTK theme")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--show", action="store_true", help="print the palette and exit")
    parser.add_argument("--debounce", type=float, default=DEFAULT_DEBOUNCE,
                        help="seconds to wait for newer wallpaper changes (default: 0.8)")
    return parser.parse_args(argv)


def apply_palette(args: argparse.Namespace, superseded=None) -> int:
    wallpaper = current_wallpaper(args.wallpaper)
    try:
        if wallpaper:
            hue, saturation = pick_accent(extract_colors(wallpaper))
        else:
            raise RuntimeError("no wallpaper found")
    except Exception as error:
        log(f"palette: {error}; using fallback")
        if not args.quiet:
            print(f"theme: {error}; using fallback palette", file=sys.stderr)
        hue, saturation = 250.0, 0.55
        wallpaper = wallpaper or Path("fallback")

    # The worker may switch wallpapers while this palette is being generated.
    # Generation for an image the user already skipped past is wasted work and
    # must never restart the bar with the wrong colors. Compare the live
    # ~/.fehbg against the image this palette describes at every expensive
    # boundary; `--wallpaper` means an explicit request, not a live session.
    key = wallpaper_identity(wallpaper)
    live = (args.wallpaper is None and wallpaper is not None
            and wallpaper.is_file() and key != "")

    def moved() -> bool:
        return live and wallpaper_identity(current_wallpaper(None)) != key

    palette = build_palette(hue, saturation)
    palette["wallpaper"] = str(wallpaper)
    palette["generated"] = datetime.now().isoformat(timespec="seconds")

    if args.show:
        print(json.dumps(palette, indent=2, ensure_ascii=False))
        return 0

    write_polybar(palette, wallpaper)
    write_alacritty(palette)
    write_rofi(palette)
    write_bspwm(palette)
    patch_dunst(palette)
    patch_zathura(palette)

    if moved():
        log("theme: wallpaper changed during generation; deferring")
        return 0

    # This is a complete generation result: persist it before any consumer is
    # touched, so palette.json and the color files can never describe different
    # wallpapers.
    write_atomic(CACHE / "palette.json", json.dumps(palette, indent=2, ensure_ascii=False) + "\n")

    stale = superseded if superseded is not None else (lambda: False)

    # If the user is still cycling wallpapers, skip the expensive work. The
    # newest apply does the heavy work once.
    if stale() or moved():
        log("theme: newer request pending; skipping GTK/reload")
        return 0

    # Bar, notifications and borders first: they are what the user sees
    # immediately after settling. GTK is the slowest step (~6 s), so it runs
    # last and can be aborted as soon as another wallpaper is picked.
    if not args.no_reload:
        reload_polybar()
        reload_dunst()
    # Borders are cheap and must follow the palette even at bspwm startup.
    apply_bspwm(palette)

    # Record completion for full applies. `--no-reload` (bspwmrc startup) and
    # `--no-gtk` leave a consumer stale, so they must not make a later full
    # apply believe this wallpaper was already applied.
    if (not args.no_reload and not args.no_gtk and not moved()):
        write_atomic(CACHE / "apply.last", wallpaper_identity(wallpaper) + "\n")

    if not args.no_gtk:
        if stale() or moved():
            log("theme: newer request pending; skipping GTK")
        else:
            apply_gtk(palette, cancelled=moved)

    log(f"theme: {wallpaper} hue={hue:.0f} sat={saturation:.2f} accent={palette['accent']}")

    if not args.quiet:
        print(f"theme: {wallpaper}")
        print(f"  bg {palette['bg']}  fg {palette['fg']}  accent {palette['accent']}  accent2 {palette['accent2']}")
    return 0


def wallpaper_identity(path: Path | None) -> str:
    """Identity of a wallpaper file: path plus metadata that changes per file."""
    if path is None:
        return ""
    try:
        st = path.stat()
    except OSError:
        return str(path)
    return f"{path}\t{st.st_mtime_ns}\t{st.st_size}"


def last_apply_key() -> str:
    try:
        return (CACHE / "apply.last").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def palette_file_matches(path: Path | None) -> bool:
    """Check that palette.json describes this exact wallpaper.

    `apply.last` alone is not enough: if it is ever stale (for example a run
    that read the old image but finished after the user switched), trusting it
    would skip the rebuild and leave the bar showing the previous palette --
    the exact stale-theme bug this pipeline must never produce.
    """
    if path is None:
        return False
    try:
        data = json.loads((CACHE / "palette.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    stored = data.get("wallpaper")
    if not isinstance(stored, str) or not stored:
        return False
    return wallpaper_identity(Path(stored)) == wallpaper_identity(path)


def main() -> int:
    raw_args = sys.argv[1:]
    args = parse_args(raw_args)
    started = time.time_ns()

    # `--show` only prints and must never wait for a lock.
    if args.show:
        return apply_palette(args)

    CACHE.mkdir(parents=True, exist_ok=True)
    token = f"{os.getpid()}:{started}"

    with LOCK_FILE.open("w") as lock:
        # Publish our token before waiting so the running apply can skip the
        # expensive steps it is about to invalidate. Then BLOCK on the lock:
        # exiting on LOCK_NB lost the wakeup if the holder checked the request
        # file just before we wrote it, leaving the palette stale forever.
        write_request(token)
        fcntl.flock(lock, fcntl.LOCK_EX)

        current = read_request()
        if current is None:
            # A dead/newer waiter's token was pruned while we waited; ours was
            # overwritten by it. Re-publish and continue.
            log("apply: request token pruned; re-publishing")
            write_request(token)
            current = read_request()
        if current != token:
            # A newer live invocation is queued/consumed after us; it owns the
            # final state.
            log("apply: superseded before start")
            return 0

        # A newer apply may have completed for the same wallpaper while we
        # waited. Compare identity (path + mtime + size), not completion time:
        # a slow apply that read the *old* wallpaper but finished late must not
        # suppress the palette for the wallpaper that is current now.
        pending_path = current_wallpaper(args.wallpaper)
        pending_key = wallpaper_identity(pending_path)
        if (pending_key and pending_key == last_apply_key()
                and palette_file_matches(pending_path)):
            log("apply: palette already current")
            if read_request() == token:
                try:
                    REQUEST_FILE.unlink()
                except FileNotFoundError:
                    pass
            return 0

        while True:
            # Wait until the newest request has been quiet for `debounce`
            # seconds. A burst of hotkey presses resets the timer, so only the
            # final wallpaper gets the expensive GTK recolor and bar restart.
            # Do NOT unlink the request file here: a newer waiter may have just
            # written its token, and deleting it would hide the supersede
            # signal (the older apply would then restart the bar for a palette
            # that is already obsolete).
            deadline = time.monotonic() + max(0.0, args.debounce)
            while time.monotonic() < deadline:
                time.sleep(min(0.05, max(0.001, deadline - time.monotonic())))
                if read_request() not in (None, token):
                    break

            if read_request() not in (None, token):
                # Newer waiter: let it acquire the lock and own the final state.
                return 0

            result = apply_palette(
                args,
                superseded=lambda: read_request() not in (None, token),
            )
            if read_request() not in (None, token):
                return 0
            if read_request() == token:
                try:
                    REQUEST_FILE.unlink()
                except FileNotFoundError:
                    pass
            return result


if __name__ == "__main__":
    raise SystemExit(main())