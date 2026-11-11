#!/usr/bin/env bash
# =============================================================================
#  Kir1ght bspwm-dotfiles installer
#  Target: Arch Linux / CachyOS (x86_64)
#
#  The script is intentionally boring: install packages, copy configs, set up
#  NVIDIA runtime power management, print post-install steps. Every step can
#  be disabled with a flag, so it is safe to re-run.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="$REPO_DIR/config"
BIN_SRC="$REPO_DIR/bin"
IMAGES_SRC="$REPO_DIR/Images"
FIREFOX_SRC="$REPO_DIR/firefox"
NVIDIA_SRC="$REPO_DIR/system/nvidia"
THRONE_SRC="$REPO_DIR/system/throne"

# -----------------------------------------------------------------------------
# Defaults / CLI
# -----------------------------------------------------------------------------
DO_PACKAGES=1
DO_CONFIG=1
DO_GPU=1
DO_FIREFOX=1
DO_WHISPER=0
DO_APPS=0
DO_EXTRA=0
DO_UPDATE=1
DRY_RUN=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --no-packages      Do not install pacman/AUR packages
  --no-config        Do not copy dotfiles
  --no-gpu           Do not configure NVIDIA runtime power management
  --no-firefox       Do not install firefox/user.js + firefox/chrome
  --no-update        Do not run "pacman -Syu" before installing packages
  --with-whisper     Download whisper.cpp models (small + large-v3-turbo)
  --with-apps        Install the optional desktop applications
  --with-extra       Install optional AUR tools/themes (upscayl, ly, Dracula icons)
  --yes              Assume "yes" (currently only affects informational prompts)
  --dry-run          Print what would be done and exit
  -h, --help         Show this help

Examples:
  ./install.sh
  ./install.sh --with-whisper
  ./install.sh --no-packages --no-gpu          # only refresh dotfiles
  ./install.sh --with-apps --with-extra
EOF
}

while (($#)); do
    case "$1" in
        --no-packages) DO_PACKAGES=0 ;;
        --no-config)   DO_CONFIG=0 ;;
        --no-gpu)      DO_GPU=0 ;;
        --no-firefox)  DO_FIREFOX=0 ;;
        --no-update)   DO_UPDATE=0 ;;
        --with-whisper) DO_WHISPER=1 ;;
        --with-apps)   DO_APPS=1 ;;
        --with-extra)  DO_EXTRA=1 ;;
        --yes|-y)      ASSUME_YES=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%serr %s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] && die "Run this script as a normal user, not as root. It calls sudo itself."

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found. This installer targets Arch Linux / CachyOS."
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    arch|cachyos) ;;
    *) [[ "${ID_LIKE:-}" == *arch* ]] || die "Unsupported distribution: ${PRETTY_NAME:-unknown}. Arch Linux or CachyOS required." ;;
esac

command -v pacman >/dev/null 2>&1 || die "pacman not found."

if ((ASSUME_YES)); then
    log "Non-interactive mode (--yes)."
fi

if ((DRY_RUN)); then
    log "Dry run: no changes will be made."
    log "Repository: $REPO_DIR"
    log "Packages: $DO_PACKAGES, configs: $DO_CONFIG, GPU: $DO_GPU, Firefox: $DO_FIREFOX"
    log "Whisper models: $DO_WHISPER, apps: $DO_APPS, extras: $DO_EXTRA"
    exit 0
fi

# Keep sudo alive while the installer is running.
if ((DO_PACKAGES || DO_GPU)); then
    command -v sudo >/dev/null 2>&1 || die "sudo not found."
    sudo -v || die "sudo authentication failed."
    ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
fi

# -----------------------------------------------------------------------------
# Package lists
# -----------------------------------------------------------------------------
PACMAN_CORE=(
    # X11 / window manager
    bspwm sxhkd polybar picom rofi dunst feh
    xorg-server xorg-xinit xorg-setxkbmap xorg-xrandr xorg-xsetroot xorg-xset xorg-xrdb
    xorg-xinput xorg-xbacklight xorg-xwininfo xorg-xdpyinfo xorg-xprop
    # terminal / shell
    alacritty kitty fish
    # launcher, clipboard, screenshots
    rofi-emoji rofi-calc xdotool xclip maim swappy slop imagemagick gpick ksnip
    # notifications / audio
    libnotify libpulse pavucontrol pamixer playerctl
    pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils
    # brightness / power / night light
    brightnessctl upower power-profiles-daemon redshift geoclue
    # network / bluetooth
    networkmanager network-manager-applet bluez bluez-utils
    # file manager / thumbnails
    thunar thunar-archive-plugin gvfs gvfs-mtp tumbler ffmpegthumbnailer
    # archives
    xarchiver unzip unrar 7zip
    # documents / music / media
    zathura zathura-pdf-mupdf zathura-djvu mpd mpc ncmpcpp cava ranger ueberzug
    # CLI / editors / utilities
    lsd bat micro neovim tree fastfetch btop htop git base-devel
    curl wget rsync pciutils python-pillow
    # fonts
    ttf-jetbrains-mono ttf-jetbrains-mono-nerd ttf-iosevka-nerd ttf-fira-code
    ttf-meslo-nerd ttf-dejavu ttf-liberation ttf-bitstream-vera ttf-opensans
    awesome-terminal-fonts terminus-font noto-fonts noto-fonts-emoji
    noto-fonts-cjk cantarell-fonts
    # GTK / icons
    gtk3 gtk4 papirus-icon-theme lxappearance
    # browser
    firefox
    # whisper.cpp + audio conversion
    whisper-cpp sox ffmpeg
)

PACMAN_APPS=(
    telegram-desktop obs-studio kdenlive audacity pinta sqlitebrowser
    keepassxc mpv gthumb gnome-disk-utility gparted bleachbit veracrypt
    homebank qemu-desktop virt-manager virt-viewer libvirt edk2-ovmf swtpm
    filezilla deluge-gtk vlc-plugins-all
)

PACMAN_GPU_COMMON=(
    mesa mesa-utils vulkan-icd-loader vulkan-intel vulkan-radeon
    xf86-video-amdgpu xf86-video-intel linux-firmware switcheroo-control
)

PACMAN_NVIDIA=(
    nvidia-utils nvidia-prime nvidia-settings opencl-nvidia libva-nvidia-driver
)

MULTILIB_PKGS=(
    lib32-mesa lib32-vulkan-icd-loader lib32-vulkan-radeon
    lib32-nvidia-utils lib32-opencl-nvidia
)

AUR_CORE=(
    greenclip light rofi-bluetooth-git throne-bin ttf-symbola ttf-ms-fonts
)

AUR_APPS=(
    vesktop-bin obsidian onlyoffice-bin
)

AUR_EXTRA=(
    arttime-git hyx ptpython upscayl-bin bluetuith
)

AUR_OPTIONAL=(
    dracula-icons-git dracula-cursors-git ly
)

# -----------------------------------------------------------------------------
# Package installation helpers
# -----------------------------------------------------------------------------
install_pacman() {
    local -a pkgs=("$@")
    ((${#pkgs[@]})) || return 0

    log "Installing pacman packages (${#pkgs[@]})..."
    if ! sudo pacman -S --needed --noconfirm "${pkgs[@]}"; then
        warn "Batch install failed; retrying one by one."
        local p
        for p in "${pkgs[@]}"; do
            sudo pacman -S --needed --noconfirm "$p" || warn "Could not install: $p"
        done
    fi
}

ensure_aur_helper() {
    if command -v yay >/dev/null 2>&1; then
        AUR_HELPER=yay
    elif command -v paru >/dev/null 2>&1; then
        AUR_HELPER=paru
    else
        log "No AUR helper found; building yay..."
        install_pacman base-devel git
        local tmp
        tmp="$(mktemp -d)"
        git clone --depth=1 https://aur.archlinux.org/yay.git "$tmp/yay"
        ( cd "$tmp/yay" && makepkg -si --noconfirm )
        rm -rf "$tmp"
        command -v yay >/dev/null 2>&1 || die "yay installation failed."
        AUR_HELPER=yay
    fi
    ok "AUR helper: $AUR_HELPER"
}

install_aur() {
    local -a pkgs=("$@")
    ((${#pkgs[@]})) || return 0

    ensure_aur_helper
    log "Installing AUR packages (${#pkgs[@]})..."
    if ! "$AUR_HELPER" -S --needed --noconfirm "${pkgs[@]}"; then
        warn "Batch AUR install failed; retrying one by one."
        local p
        for p in "${pkgs[@]}"; do
            "$AUR_HELPER" -S --needed --noconfirm "$p" || warn "Could not install: $p"
        done
    fi
}

install_multilib() {
    if pacman-conf --repo-list 2>/dev/null | grep -qx multilib; then
        install_pacman "${MULTILIB_PKGS[@]}"
    else
        warn "The [multilib] repository is disabled; skipping lib32 packages."
    fi
}

# -----------------------------------------------------------------------------
# GPU / NVIDIA runtime power management
# -----------------------------------------------------------------------------
install_gpu() {
    log "Installing Mesa / Vulkan / Xorg GPU stack..."
    install_pacman "${PACMAN_GPU_COMMON[@]}"
    install_multilib

    if ! command -v lspci >/dev/null 2>&1; then
        warn "lspci not available; cannot detect NVIDIA. Skipping NVIDIA setup."
        return 0
    fi

    if ! lspci | grep -qi '10de:'; then
        ok "No NVIDIA GPU detected; the AMD/Intel stack is ready."
        return 0
    fi

    log "NVIDIA GPU detected; installing proprietary userspace + open kernel module..."
    install_pacman "${PACMAN_NVIDIA[@]}"

    local kernel_pkg
    if [[ "${ID:-}" == "cachyos" ]]; then
        case "$(uname -r)" in
            *lts*) kernel_pkg="linux-cachyos-lts-nvidia-open" ;;
            *)     kernel_pkg="linux-cachyos-nvidia-open" ;;
        esac
    else
        case "$(uname -r)" in
            *-zen*|*-lts*) kernel_pkg="nvidia-open-dkms" ;;
            *)             kernel_pkg="nvidia-open" ;;
        esac
    fi
    install_pacman "$kernel_pkg"

    if [[ "$kernel_pkg" == *dkms* ]]; then
        case "$(uname -r)" in
            *-zen*) install_pacman linux-zen-headers ;;
            *-lts*) install_pacman linux-lts-headers ;;
            *)      install_pacman linux-headers ;;
        esac
    fi

    log "Installing udev rule and modprobe option for runtime PM..."
    sudo install -Dm644 "$NVIDIA_SRC/nvidia-pm.conf" /etc/modprobe.d/nvidia-pm.conf
    sudo install -Dm644 "$NVIDIA_SRC/80-nvidia-pm.rules" /etc/udev/rules.d/80-nvidia-pm.rules
    sudo udevadm control --reload-rules || true
    sudo udevadm trigger --subsystem-match=pci --attr-match=vendor=0x10de || true

    if command -v mkinitcpio >/dev/null 2>&1; then
        log "Rebuilding initramfs (mkinitcpio -P)..."
        sudo mkinitcpio -P || warn "mkinitcpio failed; rebuild it manually after reboot."
    fi

    local svc
    for svc in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service nvidia-powerd.service; do
        if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
            sudo systemctl enable "$svc" >/dev/null 2>&1 || true
        fi
    done

    ok "NVIDIA runtime PM configured. A reboot is recommended."
}

# -----------------------------------------------------------------------------
# Throne (TUN capabilities)
# -----------------------------------------------------------------------------
install_throne_caps() {
    local core=/opt/Throne/ThroneCore

    [[ -f "$core" ]] || return 0

    if ! command -v setcap >/dev/null 2>&1; then
        warn "setcap not found; install libcap to let Throne use TUN without root prompts."
        return 0
    fi

    log "Granting CAP_NET_ADMIN/CAP_NET_RAW to ThroneCore..."
    sudo install -Dm644 "$THRONE_SRC/95-throne-capabilities.hook" \
        /etc/pacman.d/hooks/95-throne-capabilities.hook
    sudo setcap cap_net_admin,cap_net_raw+ep "$core" \
        || warn "setcap failed; Throne may ask for root privileges."

    ok "Throne TUN permissions configured; the pacman hook keeps them after updates."
}

# -----------------------------------------------------------------------------
# Dotfiles
# -----------------------------------------------------------------------------
backup_configs() {
    BACKUP_DIR="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log "Backing up existing configs to $BACKUP_DIR"

    local item name
    for item in "$CONFIG_SRC"/*; do
        name="$(basename "$item")"
        if [[ -e "$HOME/.config/$name" ]]; then
            cp -a "$HOME/.config/$name" "$BACKUP_DIR/" 2>/dev/null || true
        fi
    done
    for item in .gtkrc-2.0 .Xresources .xinitrc .themes; do
        [[ -e "$HOME/$item" ]] && cp -a "$HOME/$item" "$BACKUP_DIR/" 2>/dev/null || true
    done
    if [[ -d "$HOME/bin" ]]; then
        mkdir -p "$BACKUP_DIR/bin"
        cp -a "$HOME/bin/." "$BACKUP_DIR/bin/" 2>/dev/null || true
    fi
}

install_configs() {
    log "Copying dotfiles..."
    backup_configs

    mkdir -p "$HOME/.config" "$HOME/.themes" "$HOME/.local/bin"
    cp -a "$CONFIG_SRC/." "$HOME/.config/"

    # Keep anime-wall API keys across reinstalls; the repo ships a secret-free
    # default file.
    if [[ -f "$BACKUP_DIR/anime-wall/config.ini" ]]; then
        install -Dm600 "$BACKUP_DIR/anime-wall/config.ini" \
            "$HOME/.config/anime-wall/config.ini"
    elif [[ -f "$HOME/.config/anime-wall/config.ini" ]]; then
        chmod 600 "$HOME/.config/anime-wall/config.ini"
    fi
    mkdir -p "$HOME/Pictures/kiri-vault"

    # Make the art browser available from the rofi application launcher too.
    install -Dm644 "$CONFIG_SRC/anime-wall/anime-wall.desktop" \
        "$HOME/.local/share/applications/anime-wall.desktop"
    cp -a "$REPO_DIR/gtkrc-2.0" "$HOME/.gtkrc-2.0"
    cp -a "$REPO_DIR/Xresources" "$HOME/.Xresources"
    cp -a "$REPO_DIR/xinitrc" "$HOME/.xinitrc"
    cp -a "$REPO_DIR/themes/." "$HOME/.themes/"

    # bspwm execs bspwmrc directly. Without the execute bit it silently skips
    # the whole config: no wallpaper, panel, compositor or hotkeys.
    chmod 755 "$HOME/.xinitrc" "$HOME/.config/bspwm/bspwmrc"

    # Wallpapers live in two libraries. Existing files are not overwritten.
    mkdir -p "$HOME/Images/Wallpaper_desktop" "$HOME/Images/Wallpaper_lockscreen"

    # Migrate an older flat installation without encoding its old directory
    # names in the active wallpaper scripts. Root-level images are desktop
    # wallpapers. Images in any other legacy subdirectory are desktop images
    # too, unless that directory contains a lock_screen file.
    migrate_wallpaper_file() {
        local src="$1" dir="$2" base target counter=2
        base="$(basename -- "$src")"
        target="$dir/$base"
        while [[ -e "$target" ]]; do
            if cmp -s -- "$src" "$target"; then
                rm -f -- "$src"
                return 0
            fi
            target="$dir/${base%.*}-${counter}.${base##*.}"
            counter=$((counter + 1))
        done
        mv -- "$src" "$target"
    }

    local legacy_image legacy_dir legacy_target
    while IFS= read -r -d '' legacy_image; do
        migrate_wallpaper_file "$legacy_image" "$HOME/Images/Wallpaper_desktop"
    done < <(find "$HOME/Images" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        -print0 2>/dev/null)
    for legacy_dir in "$HOME/Images"/*; do
        [[ -d "$legacy_dir" ]] || continue
        case "$legacy_dir" in
            "$HOME/Images/Wallpaper_desktop"|"$HOME/Images/Wallpaper_lockscreen")
                continue
                ;;
        esac
        legacy_target="$HOME/Images/Wallpaper_desktop"
        if [[ -n "$(find "$legacy_dir" -maxdepth 1 -type f -iname 'lock_screen.*' -print -quit 2>/dev/null)" ]]; then
            legacy_target="$HOME/Images/Wallpaper_lockscreen"
        fi
        while IFS= read -r -d '' legacy_image; do
            migrate_wallpaper_file "$legacy_image" "$legacy_target"
        done < <(find "$legacy_dir" -maxdepth 1 -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
            -print0 2>/dev/null)
        rmdir "$legacy_dir" 2>/dev/null || true
    done

    cp -an "$IMAGES_SRC/Wallpaper_desktop/." "$HOME/Images/Wallpaper_desktop/" 2>/dev/null || true
    cp -an "$IMAGES_SRC/Wallpaper_lockscreen/." "$HOME/Images/Wallpaper_lockscreen/" 2>/dev/null || true

    # Stable symlinks are what bspwm and screen-lock read; create them only if
    # the user has not already picked a wallpaper.
    if [[ ! -e "$HOME/.current_wallpaper" && ! -L "$HOME/.current_wallpaper" ]]; then
        local desktop_default="$HOME/Images/Wallpaper_desktop/default.png"
        [[ -f "$desktop_default" ]] || desktop_default="$(find "$HOME/Images/Wallpaper_desktop" \
            -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
            -print -quit 2>/dev/null)"
        [[ -n "$desktop_default" ]] && ln -s "$desktop_default" "$HOME/.current_wallpaper"
    fi
    if [[ ! -e "$HOME/.current_lockscreen" && ! -L "$HOME/.current_lockscreen" ]]; then
        local lock_default
        lock_default="$(find "$HOME/Images/Wallpaper_lockscreen" \
            -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
            -print -quit 2>/dev/null)"
        [[ -n "$lock_default" ]] && ln -s "$lock_default" "$HOME/.current_lockscreen"
    fi

    # The wallpaper is picked before the palette is built so the theme is
    # generated from it instead of the Dracula fallback.
    if [[ ! -f "$HOME/.fehbg" && -f "$HOME/Images/Wallpaper_desktop/default.png" ]] && command -v feh >/dev/null 2>&1; then
        if feh --no-fehbg --bg-fill "$HOME/Images/Wallpaper_desktop/default.png" 2>/dev/null; then
            printf '#!/bin/sh\nfeh --no-fehbg --bg-fill "%s"\n' "$HOME/Images/Wallpaper_desktop/default.png" > "$HOME/.fehbg"
            chmod 755 "$HOME/.fehbg"
        fi
    fi

    # Build the initial wallpaper palette. This also creates ~/.themes/Dynamic
    # (a recolored copy of Dracula) and the GTK4 overrides in ~/.config.
    if [[ -x "$HOME/.config/theme/apply.py" ]]; then
        "$HOME/.config/theme/apply.py" --quiet --no-reload --debounce 0 || true
    fi

    # @HOME@ placeholders are used instead of hardcoded /home/<author> paths.
    local f
    for f in \
        "$HOME/.gtkrc-2.0" \
        "$HOME/.config/gtk-3.0/bookmarks" \
        "$HOME/.config/fish/fish_variables" \
        "$HOME/.config/ksnip/ksnip.conf"; do
        [[ -f "$f" ]] && sed -i "s|@HOME@|$HOME|g" "$f"
    done

    # User scripts: canonical location is ~/.local/bin (as requested), and
    # ~/bin is kept as a compatibility link/copy because the configs use ~/bin.
    cp -a "$BIN_SRC/." "$HOME/.local/bin/"
    find "$HOME/.local/bin" -type f -exec chmod +x {} +

    if [[ -e "$HOME/bin" && ! -L "$HOME/bin" ]]; then
        cp -a "$BIN_SRC/." "$HOME/bin/"
        find "$HOME/bin" -type f -exec chmod +x {} +
    else
        ln -sfn "$HOME/.local/bin" "$HOME/bin"
    fi

    # Removed wallpaper maintenance tools must not survive an upgrade because
    # they can still be invoked manually with the old flat-folder assumptions.
    rm -f "$HOME/.local/bin/wallpaper_filter.py" "$HOME/bin/wallpaper_filter.py"

    # Make edited hotkeys active immediately; sxhkd keeps the config it read at
    # startup and would otherwise ignore newly added bindings until next login.
    if pgrep -x sxhkd >/dev/null 2>&1; then
        pkill -USR1 -x sxhkd 2>/dev/null || true
    fi

    ok "Dotfiles installed. Backup: $BACKUP_DIR"
}

# -----------------------------------------------------------------------------
# Firefox (optional)
# -----------------------------------------------------------------------------
install_firefox() {
    log "Looking for a Firefox profile..."
    local profile="" base
    for base in "$HOME/.mozilla/firefox" "$HOME/.config/mozilla/firefox"; do
        [[ -d "$base" ]] || continue
        profile="$(find "$base" -maxdepth 1 -type d -name '*.default-release' 2>/dev/null | head -n1)"
        [[ -n "$profile" ]] && break
    done

    if [[ -z "$profile" ]]; then
        if command -v firefox >/dev/null 2>&1; then
            log "No profile found; asking Firefox to create one..."
            firefox --headless >/dev/null 2>&1 &
            local ff_pid=$!
            sleep 6
            kill "$ff_pid" 2>/dev/null || true
            wait "$ff_pid" 2>/dev/null || true
        fi
        for base in "$HOME/.mozilla/firefox" "$HOME/.config/mozilla/firefox"; do
            [[ -d "$base" ]] || continue
            profile="$(find "$base" -maxdepth 1 -type d -name '*.default-release' 2>/dev/null | head -n1)"
            [[ -n "$profile" ]] && break
        done
    fi

    if [[ -z "$profile" ]]; then
        warn "Firefox profile not found; skipping user.js/chrome."
        return 0
    fi

    if pgrep -x firefox >/dev/null 2>&1; then
        warn "Firefox is running. Close it and restart to apply user.js/chrome."
    fi

    local ff_backup
    ff_backup="$profile/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$ff_backup"
    [[ -f "$profile/user.js" ]] && cp -a "$profile/user.js" "$ff_backup/"
    [[ -d "$profile/chrome" ]] && cp -a "$profile/chrome" "$ff_backup/"

    cp -a "$FIREFOX_SRC/user.js" "$profile/user.js"
    mkdir -p "$profile/chrome"
    cp -a "$FIREFOX_SRC/chrome/." "$profile/chrome/"

    ok "Firefox user.js + chrome installed into: $profile"
}

# -----------------------------------------------------------------------------
# Whisper models (optional)
# -----------------------------------------------------------------------------
install_whisper_models() {
    log "Downloading whisper.cpp models (this is ~1 GB)..."
    local dir="$HOME/.local/share/whisper"
    mkdir -p "$dir"
    local model
    for model in ggml-small.bin ggml-large-v3-turbo-q5_0.bin; do
        if [[ -f "$dir/$model" ]]; then
            ok "Already present: $model"
        else
            curl -L --fail --progress-bar -o "$dir/$model" \
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$model"
        fi
    done
    ok "Whisper models installed in $dir"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
log "Repository: $REPO_DIR"

if ((DO_PACKAGES)); then
    if ((DO_UPDATE)); then
        log "Updating package databases and system (pacman -Syu)..."
        sudo pacman -Syu --noconfirm || warn "System update failed; continuing."
    fi

    install_pacman "${PACMAN_CORE[@]}"
    install_aur "${AUR_CORE[@]}"

    if ((DO_APPS)); then
        install_pacman "${PACMAN_APPS[@]}"
        install_aur "${AUR_APPS[@]}"
    fi
    if ((DO_EXTRA)); then
        install_aur "${AUR_EXTRA[@]}" "${AUR_OPTIONAL[@]}"
    fi

    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f >/dev/null 2>&1 || true
    fi
fi

if ((DO_GPU)); then
    install_gpu
fi

install_throne_caps

if ((DO_CONFIG)); then
    install_configs
fi

if ((DO_FIREFOX)); then
    install_firefox
fi

if ((DO_WHISPER)); then
    install_whisper_models
fi

# -----------------------------------------------------------------------------
# Post-install
# -----------------------------------------------------------------------------
cat <<EOF

${C_GREEN}${C_BOLD}Installation finished.${C_RESET}

Next steps:
  1. Log out and log in again (or restart bspwm with Ctrl+Shift+R).
  2. Check monitors:        xrandr --query
     If your panel is not 2560x1600, edit:
       ~/.config/bspwm/dual_monitors.sh
       ~/bin/hz-toggle
  3. Reload hotkeys:        Super+Shift+R
  4. Test the launcher:     Super+Space
  5. GPU power state:       cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
     Expected:              suspended
     Run on dGPU:           prime-run <command>   (e.g. prime-run glxinfo -B)
  6. Make fish default:     chsh -s /usr/bin/fish
  7. Enable MPD user unit:  systemctl --user enable --now mpd
  8. Display manager:       the author uses ly@tty2; otherwise startx reads ~/.xinitrc
  9. Whisper models:        ./install.sh --with-whisper
 10. Firefox:               close and reopen it; user.js/chrome apply on startup.

Logs and backups are in:   ~/.dotfiles-backup-*
EOF

if ((DO_GPU)); then
    cat <<'EOF'

NVIDIA notes:
  - The AMD iGPU is the primary display adapter; the NVIDIA dGPU is runtime-suspended.
  - Run applications on the dGPU with: prime-run <command>
  - CUDA/whisper scripts set CUDA_VISIBLE_DEVICES="" on purpose so they do not wake the dGPU.
  - A reboot is recommended after the first run (udev/modprobe/initramfs changes).
EOF
fi
