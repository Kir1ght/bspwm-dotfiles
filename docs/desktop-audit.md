# Проверка десктопа после аудита

Правки сделаны в репозитории, не в работающей X-сессии. В `/etc` ничего
не требуется менять. LDAC остаётся на 330 кбит/с; настройки Reverse PRIME
и управления питанием NVIDIA не менялись на системе.

## Как установить без перелогина

Запусти следующий блок в **Bash**. Он сохраняет только заменяемые файлы
и не трогает API-ключи Anime Wall, текущие обои и сгенерированную палитру.

```bash
(
    set -eu
    cd "$HOME/bspwm-dotfiles"
    backup=$(mktemp -d "$HOME/.desktop-audit-backup.XXXXXX")
    put() {
        local source=$1 destination=$2 mode=$3 saved="$backup/${2#"$HOME"/}"
        if [[ -e $destination || -L $destination ]]; then
            mkdir -p -- "${saved%/*}"
            cp -a -- "$destination" "$saved"
        fi
        install -Dm"$mode" -- "$source" "$destination"
    }
    for script in anime-wall bluetooth-menu brightness-watch bspwmctl caffeine.sh cursor_tracker.sh \
        bspwm-{drag-split,pseudo,split,toggle-state} desktop-no-fds hdmi{,-gpu,-present} \
        hz-toggle polybar-devices random_wallpaper refresh-auto screen-wake \
        toggle-polybar vxe-battery weather{,-show}; do
        put "bin/$script" "$HOME/.local/bin/$script" 755
        put "bin/$script" "$HOME/bin/$script" 755
    done
    for destination in "$HOME/bin" "$HOME/.local/bin"; do
        put bin/anime_wall_ui.py "$destination/anime_wall_ui.py" 644
    done
    for file in bspwm/{bspwmrc,dual_monitors.sh} polybar/launch.sh theme/apply.py; do
        put "config/$file" "$HOME/.config/$file" 755
    done
    for file in bspwm/picom_configurations/1.conf polybar/{config,modules}.ini \
        rofi/config.rasi sxhkd/sxhkdrc; do
        put "config/$file" "$HOME/.config/$file" 644
    done
    put config/anime-wall/anime-wall.desktop \
        "$HOME/.local/share/applications/anime-wall.desktop" 644
    printf 'Резервные копии: %s\n' "$backup"
)
```

## Что проверить

- **Anime Wall**: `Ctrl + Alt + A` → поиск в новом окне GTK4 → сохранение → применить;
  затем выбрать два разных арта подряд. В библиотеке остаётся копия
  сохранённого арта; на рабочем столе и в палитре — последний применённый.
  `~/.config/anime-wall/config.ini` с ключами не перезаписывать.
- **Polybar**: запусти `~/.config/polybar/launch.sh --reload`. Проверь
  `us`/`ru`, батарейку мыши, отключение гарнитуры, а затем смену обоев
  при скрытой панели. Лог: `~/.local/state/polybar/`.
- **Клавиши**: после установки `sxhkdrc` пошли `SIGUSR1` своему `sxhkd`,
  это перечитывает бинды без выхода из сессии. `Super + Shift + O`
  теперь включает зеркало или отключает HDMI. Если кадр стоит,
  попробуй `hdmi mirror --common`; `hdmi off` возвращает режим ноутбука.
- **Rofi** перечитает оформление при следующем открытии.
  **picom** перечитает изменения после своего обычного запуска (активный
  профиль: `~/.config/bspwm/picom_configurations/1.conf`). Для изменений
  автозапуска `bspwmrc` достаточно следующего обычного входа, в том числе
  для фонового KDE Connect. Не прерывай сессию только ради этого.

## Границы проверки

Проверки `python3 -m unittest discover -s tests -v` не подключаются к
реальным провайдерам и не меняют рабочий стол. Rofi и запуск/скрытие
Polybar можно проверять в Xvfb, но это не проверка GPU, VSync, Bluetooth
или HDMI-вывода. Застывший кадр на физическом проекторе и чёрный eDP/TTY
после входа не считаются устранёнными. Pear Desktop и ONLYOFFICE не
перенастраивались: нет подтверждения, что приложение было первопричиной
зависания оконного менеджера.
