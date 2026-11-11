"""Package groups used by this dotfiles build.

install.sh is the source of truth. This module mirrors the lists so that the
Python Builder can show/validate them without parsing Bash.
"""

PACMAN_CORE = [
    # X11 / window manager
    "bspwm", "sxhkd", "polybar", "picom", "rofi", "dunst", "feh",
    "xorg-server", "xorg-xinit", "xorg-setxkbmap", "xorg-xrandr",
    "xorg-xsetroot", "xorg-xset", "xorg-xrdb", "xorg-xinput",
    "xorg-xbacklight", "xorg-xwininfo", "xorg-xdpyinfo", "xorg-xprop",
    # terminal / shell
    "alacritty", "kitty", "fish",
    # launcher, clipboard, screenshots
    "rofi-emoji", "rofi-calc", "xdotool", "xclip", "maim", "swappy", "slop",
    "imagemagick", "gpick", "ksnip",
    # notifications / audio
    "libnotify", "libpulse", "pavucontrol", "pamixer", "playerctl",
    "pipewire", "pipewire-pulse", "pipewire-alsa", "wireplumber", "alsa-utils",
    # brightness / power / night light
    "brightnessctl", "upower", "power-profiles-daemon", "redshift", "geoclue",
    # network / bluetooth
    "networkmanager", "network-manager-applet", "bluez", "bluez-utils",
    # file manager / thumbnails
    "thunar", "thunar-archive-plugin", "gvfs", "gvfs-mtp", "tumbler",
    "ffmpegthumbnailer",
    # archives
    "xarchiver", "unzip", "unrar", "7zip",
    # documents / music / media
    "zathura", "zathura-pdf-mupdf", "zathura-djvu", "mpd", "mpc", "ncmpcpp",
    "cava", "ranger", "ueberzug",
    # CLI / editors / utilities
    "lsd", "bat", "micro", "neovim", "tree", "fastfetch", "btop", "htop",
    "git", "base-devel", "curl", "wget", "rsync", "pciutils",
    # fonts
    "ttf-jetbrains-mono", "ttf-jetbrains-mono-nerd", "ttf-iosevka-nerd",
    "ttf-fira-code", "ttf-meslo-nerd", "ttf-dejavu", "ttf-liberation",
    "ttf-bitstream-vera", "ttf-opensans", "awesome-terminal-fonts",
    "terminus-font", "noto-fonts", "noto-fonts-emoji", "noto-fonts-cjk",
    "cantarell-fonts",
    # GTK / icons
    "gtk3", "gtk4", "papirus-icon-theme", "lxappearance",
    # browser
    "firefox",
    # whisper.cpp + audio conversion
    "whisper-cpp", "sox", "ffmpeg",
]

PACMAN_APPS = [
    "telegram-desktop", "obs-studio", "kdenlive", "audacity", "pinta",
    "sqlitebrowser", "keepassxc", "mpv", "gthumb", "gnome-disk-utility",
    "gparted", "bleachbit", "veracrypt", "homebank", "qemu-desktop",
    "virt-manager", "virt-viewer", "libvirt", "edk2-ovmf", "swtpm",
    "filezilla", "deluge-gtk", "vlc-plugins-all",
]

PACMAN_GPU_COMMON = [
    "mesa", "mesa-utils", "vulkan-icd-loader", "vulkan-intel",
    "vulkan-radeon", "xf86-video-amdgpu", "xf86-video-intel",
    "linux-firmware", "switcheroo-control",
]

PACMAN_NVIDIA = [
    "nvidia-utils", "nvidia-prime", "nvidia-settings", "opencl-nvidia",
    "libva-nvidia-driver",
]

MULTILIB_PKGS = [
    "lib32-mesa", "lib32-vulkan-icd-loader", "lib32-vulkan-radeon",
    "lib32-nvidia-utils", "lib32-opencl-nvidia",
]

AUR_CORE = [
    "greenclip", "light", "rofi-bluetooth-git", "throne-bin",
    "ttf-symbola", "ttf-ms-fonts",
]

AUR_APPS = ["vesktop-bin", "obsidian", "onlyoffice-bin"]

AUR_EXTRA = ["arttime-git", "hyx", "ptpython", "upscayl-bin", "bluetuith"]

AUR_OPTIONAL = ["dracula-icons-git", "dracula-cursors-git", "ly"]
