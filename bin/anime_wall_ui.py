"""GTK4 front end; the provider, cache and wallpaper code lives in anime-wall."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from dataclasses import replace
import json
from pathlib import Path
import re
import subprocess

import gi
from PIL import Image

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk


RATINGS = ("Безопасные", "Сомнительные", "18+", "Все")
ORIENTATIONS = ("Любая", "Горизонтальная", "Вертикальная", "Квадратная")
ORDERS = ("По оценке", "Сначала новые", "Случайно")


def box(vertical=False, gap=8):
    return Gtk.Box(orientation=Gtk.Orientation.VERTICAL if vertical
                   else Gtk.Orientation.HORIZONTAL, spacing=gap)


def label(text="", *, wrap=False):
    return Gtk.Label(label=text, xalign=0, wrap=wrap)


def dropdown(values, index=0):
    control = Gtk.DropDown.new_from_strings(values)
    control.set_selected(index)
    return control


def spin(value, maximum, step=1):
    control = Gtk.SpinButton.new_with_range(0, maximum, step)
    control.set_value(value)
    return control


class Gallery(Gtk.ApplicationWindow):
    def __init__(self, app, api, settings, parser, state, config_path):
        super().__init__(application=app, title="Аниме-обои")
        self.api, self.settings, self.parser = api, settings, parser
        self.state, self.config_path = state, config_path
        self.request = 0
        self.active_query = None
        self.closed = False
        self.post = None
        self.jobs = {}
        self.preview_jobs = []
        self.search_job = None
        self.network = ThreadPoolExecutor(max_workers=2, thread_name_prefix="booru")
        self.previews = ThreadPoolExecutor(max_workers=settings.preview_workers,
                                           thread_name_prefix="preview")
        self.providers = list(api.PROVIDERS)
        self.set_default_size(1140, 756)
        self.set_size_request(760, 500)
        self.add_css_class("anime-wall")
        self.connect("close-request", self.on_close)

        toolbar = Gtk.HeaderBar()
        title = label("Аниме-обои")
        title.add_css_class("title")
        toolbar.set_title_widget(title)
        self.set_titlebar(toolbar)
        toolbar.pack_end(self.button("Папка", self.open_folder))
        toolbar.pack_end(self.filters())

        root = box(vertical=True, gap=12)
        for side in ("top", "bottom", "start", "end"):
            getattr(root, f"set_margin_{side}")(14)
        self.set_child(root)
        search = box()
        root.append(search)
        self.provider = dropdown([api.PROVIDERS[key]["label"] for key in self.providers],
                                 self.providers.index(settings.provider))
        search.append(self.provider)
        self.entry = Gtk.Entry(hexpand=True, placeholder_text="Теги через пробел, например: landscape night")
        self.entry.set_text(settings.tags or state.get("last_tags", {}).get(settings.provider, ""))
        self.entry.connect("activate", lambda *_: self.search())
        self.provider.connect("notify::selected", self.change_provider)
        search.append(self.entry)
        self.tag_menu = Gtk.MenuButton(label="Подсказки")
        self.tag_menu.set_create_popup_func(self.populate_tag_menu)
        search.append(self.tag_menu)
        go = self.button("Найти", self.search)
        go.add_css_class("suggested-action")
        search.append(go)

        content = box(gap=14)
        content.set_vexpand(True)
        root.append(content)
        left = box(vertical=True)
        left.set_hexpand(True)
        content.append(left)
        row = box()
        left.append(row)
        self.spinner = Gtk.Spinner()
        row.append(self.spinner)
        self.summary = label("Введите теги или нажмите «Найти», чтобы посмотреть всё.", wrap=True)
        row.append(self.summary)
        scroller = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scroll = scroller
        left.append(scroller)
        self.grid = Gtk.FlowBox(homogeneous=True, column_spacing=9, row_spacing=9,
                                activate_on_single_click=False, max_children_per_line=5,
                                selection_mode=Gtk.SelectionMode.SINGLE)
        self.grid.connect("selected-children-changed", self.select_post)
        self.grid.connect("child-activated", lambda _, child: self.grid.select_child(child))
        scroller.set_child(self.grid)

        inspector = box(vertical=True, gap=12)
        inspector.set_size_request(272, -1)
        inspector.add_css_class("inspector")
        content.append(inspector)
        self.large = Gtk.Picture(can_shrink=True, content_fit=Gtk.ContentFit.CONTAIN)
        self.large.set_size_request(240, 180)
        inspector.append(self.large)
        self.metadata = label("Выберите изображение", wrap=True)
        self.metadata.add_css_class("title-4")
        inspector.append(self.metadata)
        self.tags = label("", wrap=True)
        self.tags.set_selectable(True)
        self.tags.set_max_width_chars(32)
        inspector.append(self.tags)
        self.apply = self.button("Поставить обои", lambda: self.save(True))
        self.apply.add_css_class("suggested-action")
        self.download = self.button("Скачать", lambda: self.save(False))
        self.link = self.button("Открыть пост", self.open_post)
        for button in (self.apply, self.download, self.link):
            inspector.append(button)
            button.set_sensitive(False)
        self.activity = label("", wrap=True)
        self.activity.set_max_width_chars(34)
        inspector.append(self.activity)

        paging = box()
        root.append(paging)
        self.previous = self.button("← Назад", lambda: self.turn(-1))
        self.next = self.button("Дальше →", lambda: self.turn(1))
        self.page = Gtk.SpinButton.new_with_range(1, 10000, 1)
        self.page.set_width_chars(4)
        self.page.set_value(settings.page)
        self.jump = self.button("Перейти", self.jump_to_page)
        self.refresh = self.button("Обновить", self.refresh_results)
        for widget in (self.previous, label("Страница"), self.page, self.jump,
                       self.next, self.refresh):
            paging.append(widget)
        self.pagination(False, False)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        self.add_controller(keys)
        self.entry.grab_focus()
        if self.entry.get_text():
            GLib.idle_add(self.search)

    @staticmethod
    def button(text, callback):
        control = Gtk.Button(label=text)
        control.connect("clicked", lambda *_: callback())
        return control

    def filters(self):
        menu = Gtk.MenuButton(label="Фильтры и доступ")
        popover = Gtk.Popover()
        panel = box(vertical=True, gap=10)
        for side in ("top", "bottom", "start", "end"):
            getattr(panel, f"set_margin_{side}")(10)
        popover.set_child(panel)
        menu.set_popover(popover)
        data = self.settings
        self.rating = dropdown(RATINGS, self.api.RATING_CHOICES.index(data.rating))
        self.orientation = dropdown(ORIENTATIONS, self.api.ORIENTATION_CHOICES.index(data.orientation))
        self.order = dropdown(ORDERS, self.api.SORT_CHOICES.index(data.sort))
        self.width = spin(data.min_width, 16384, 16)
        self.height = spin(data.min_height, 16384, 16)
        self.score = spin(data.min_score, 10000)
        self.count = spin(data.per_page, 100, 4)
        self.count.set_range(1, 100)
        for text, control in (
            ("Рейтинг", self.rating), ("Ориентация", self.orientation),
            ("Сортировка", self.order), ("Мин. ширина", self.width),
            ("Мин. высота", self.height), ("Мин. оценка", self.score),
            ("Артов на странице", self.count),
        ):
            row = box()
            caption = label(text)
            caption.set_hexpand(True)
            row.append(caption)
            row.append(control)
            panel.append(row)
        search = self.button("Показать результаты", lambda: (popover.popdown(), self.search()))
        search.add_css_class("suggested-action")
        panel.append(search)
        access = Gtk.Expander(label="Доступ к Gelbooru")
        account = box(vertical=True)
        access.set_child(account)
        panel.append(access)
        key = Gtk.PasswordEntry(placeholder_text="Ключ API", show_peek_icon=True)
        key.set_text(self.parser.get("gelbooru", "api_key", fallback=""))
        user = Gtk.Entry(placeholder_text="User ID")
        user.set_text(self.parser.get("gelbooru", "user_id", fallback=""))
        account.append(key)
        account.append(user)

        def save_credentials():
            if not self.parser.has_section("gelbooru"):
                self.parser.add_section("gelbooru")
            self.parser["gelbooru"]["api_key"] = key.get_text().strip()
            self.parser["gelbooru"]["user_id"] = user.get_text().strip()
            try:
                self.api.save_config(self.parser, self.config_path)
                self.activity.set_text("Данные Gelbooru сохранены.")
            except OSError as exc:
                self.activity.set_text(f"Не удалось сохранить настройки: {exc}")
            popover.popdown()

        account.append(self.button("Сохранить доступ", save_credentials))
        return menu

    def change_provider(self, *_):
        self.entry.grab_focus()

    def request_settings(self):
        return replace(
            self.settings, provider=self.providers[self.provider.get_selected()],
            tags=" ".join(self.entry.get_text().split()),
            rating=self.api.RATING_CHOICES[self.rating.get_selected()],
            orientation=self.api.ORIENTATION_CHOICES[self.orientation.get_selected()],
            sort=self.api.SORT_CHOICES[self.order.get_selected()],
            min_width=self.width.get_value_as_int(), min_height=self.height.get_value_as_int(),
            min_score=self.score.get_value_as_int(), per_page=self.count.get_value_as_int(),
            page=1,
        )

    def search(self):
        query = self.request_settings()
        self.state.setdefault("last_tags", {})[query.provider] = query.tags
        self.api.save_state(self.state)
        try:
            self.api.persist_settings(query, self.parser, self.config_path)
        except OSError as exc:
            self.activity.set_text(f"Не удалось сохранить параметры: {exc}")
        self.submit_search(query)
        return GLib.SOURCE_REMOVE

    def turn(self, offset):
        if self.active_query is not None:
            self.submit_search(replace(self.active_query, page=max(1, self.active_query.page + offset)))

    def jump_to_page(self):
        query = self.active_query or self.request_settings()
        self.submit_search(replace(query, page=self.page.get_value_as_int()))

    def refresh_results(self):
        self.submit_search(replace(self.active_query) if self.active_query else self.request_settings(),
                           cached=False)

    def pagination(self, has_previous, has_next, *, busy=False):
        self.previous.set_sensitive(has_previous)
        self.next.set_sensitive(has_next)
        for widget in (self.page, self.jump, self.refresh):
            widget.set_sensitive(not busy)

    def clear_grid(self):
        while child := self.grid.get_first_child():
            self.grid.remove(child)

    def submit_search(self, query, *, cached=True):
        query.clamp()
        self.active_query = query
        self.request += 1
        serial = self.request
        if self.search_job:
            self.search_job.cancel()
        for job in self.preview_jobs:
            job.cancel()
        self.preview_jobs.clear()
        self.clear_grid()
        self.pagination(False, False, busy=True)
        self.page.set_value(query.page)
        self.summary.set_text("Ищем изображения…")
        self.spinner.start()
        parser = deepcopy(self.parser)

        def fetch():
            posts = self.api.fetch_posts(query, parser, use_cache=cached, quiet=True)
            return posts, self.api.cached_raw_count(query) >= query.per_page

        self.search_job = self.network.submit(fetch)
        self.search_job.add_done_callback(
            lambda future: GLib.idle_add(self.show_results, serial, query, future))

    def show_results(self, serial, query, future):
        if self.closed or serial != self.request:
            return
        self.spinner.stop()
        try:
            posts, has_next = future.result()
        except Exception as exc:
            if query.provider == "gelbooru" and "API key" in str(exc):
                text = "Gelbooru: добавьте ключ и User ID в «Фильтры и доступ»."
            else:
                text = f"Не удалось загрузить результаты: {exc}"
            self.summary.set_text(text)
            self.pagination(query.page > 1, False)
            return

        self.pagination(query.page > 1, has_next)
        self.summary.set_text(f"Найдено: {len(posts)} · {self.api.PROVIDERS[query.provider]['label']}"
                              if posts else "Ничего не найдено. Уберите часть тегов или уменьшите мин. размер.")
        for post in posts:
            tile = Gtk.FlowBoxChild()
            tile.post = post
            tile.preview = None
            card = box(vertical=True, gap=5)
            tile.set_child(card)
            self.grid.append(tile)
            thumb = Gtk.Picture(content_fit=Gtk.ContentFit.COVER, can_shrink=True)
            thumb.set_size_request(130, 106)
            thumb.add_css_class("thumbnail")
            card.append(thumb)
            shot = label(post.label())
            shot.set_xalign(0.5)
            card.append(shot)
            target = self.api.provider_folder(self.settings.download_dir, post.provider) / self.api.safe_name(post)
            tile.caption = shot
            if self.api.valid_image_file(target):
                shot.set_text("✓ " + post.label())
            future = self.previews.submit(self.preview_texture, post)
            self.preview_jobs.append(future)
            future.add_done_callback(
                lambda result, item=tile, picture=thumb:
                GLib.idle_add(self.finish_preview, serial, item, picture, result))
        self.scroll.get_vadjustment().set_value(0)
        first = self.grid.get_first_child()
        if first:
            self.grid.select_child(first)

    def preview_texture(self, post):
        cached = self.api.preview_path(post)
        path = cached if self.api.valid_image_file(cached) else self.api.download_preview(post)
        if path is None:
            return None
        with Image.open(path) as image:
            image.draft("RGB", (480, 320))
            image.thumbnail((480, 320))
            rgba = image.convert("RGBA")
            return Gdk.MemoryTexture.new(rgba.width, rgba.height, Gdk.MemoryFormat.R8G8B8A8,
                                         GLib.Bytes.new(rgba.tobytes()), rgba.width * 4)

    def finish_preview(self, serial, tile, picture, future):
        if self.closed or serial != self.request:
            return
        try:
            texture = future.result()
        except (OSError, ValueError, Image.DecompressionBombError, self.api.BooruError):
            return
        if texture:
            tile.preview = texture
            picture.set_paintable(texture)
            if self.post == tile.post:
                self.large.set_paintable(texture)

    def select_post(self, grid):
        selection = grid.get_selected_children()
        self.post = selection[0].post if selection else None
        self.large.set_paintable(selection[0].preview if selection else None)
        self.metadata.set_text(self.post.label() if self.post else "Выберите изображение")
        self.tags.set_text(" · ".join(self.post.tags.split()[:14]) if self.post else "")
        self.update_actions()

    def update_actions(self):
        key = (self.post.provider, self.post.id) if self.post else None
        for button in (self.apply, self.download):
            button.set_sensitive(key is not None and key not in self.jobs)
        self.link.set_sensitive(self.post is not None)

    def save(self, apply):
        post = self.post
        if post is None:
            return
        key = (post.provider, post.id)
        if key in self.jobs:
            return
        try:
            worker = self.api.start_download(post, self.settings, apply, report_status=True)
        except OSError as exc:
            self.activity.set_text(f"Не удалось начать загрузку: {exc}")
            return
        self.jobs[key] = worker
        self.update_actions()
        self.activity.set_text(f"{'Готовим обои' if apply else 'Скачиваем'} #{post.id}…")

        def check_job():
            if self.closed:
                return GLib.SOURCE_REMOVE
            code = worker.poll()
            if code is None:
                return GLib.SOURCE_CONTINUE
            self.jobs.pop(key, None)
            self.update_actions()
            if code in (0, 3):
                message = "Обои установлены" if apply and code == 0 else "Сохранено в папку загрузок"
                self.activity.set_text(f"{message} · #{post.id}")
                tile = self.grid.get_first_child()
                while tile:
                    if tile.post == post:
                        tile.caption.set_text("✓ " + post.label())
                        break
                    tile = tile.get_next_sibling()
            else:
                self.activity.set_text(f"Действие с #{post.id} не выполнено. Подробности — в уведомлении.")
            return GLib.SOURCE_REMOVE

        GLib.timeout_add(200, check_job)

    def populate_tag_menu(self, button):
        text = self.entry.get_text()
        snapshot = self.request_settings()
        snippet = self.api.tag_prefix(text)
        popover = Gtk.Popover()
        panel = box(vertical=True, gap=4)
        popover.set_child(panel)
        hint = label("Загружаем теги…")
        panel.append(hint)
        button.set_popover(popover)
        job = self.network.submit(self.api.fetch_tag_suggestions, snapshot,
                                  deepcopy(self.parser), snippet)

        def fill():
            if self.closed or button.get_popover() != popover:
                return
            try:
                suggestions = job.result()
            except (OSError, self.api.BooruError) as exc:
                hint.set_text(f"Нет подсказок: {exc}")
                return
            hint.set_text("Подсказки тегов" if suggestions else "Нет подходящих тегов")
            for value, count in suggestions:
                def choose(tag=value):
                    parts = text.split()
                    if snippet and parts:
                        parts.pop()
                    parts.append(tag)
                    self.entry.set_text(" ".join(parts) + " ")
                    popover.popdown()
                    self.entry.grab_focus()
                    self.entry.set_position(-1)
                panel.append(self.button(f"{value}  ·  {count:,}", choose))

        job.add_done_callback(lambda _: GLib.idle_add(fill))
        popover.connect("closed", lambda *_: button.set_popover(None))

    def open_item(self, target):
        try:
            subprocess.Popen(["xdg-open", str(target)], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as exc:
            self.activity.set_text(f"Не удалось открыть: {exc}")

    def open_folder(self):
        try:
            self.settings.download_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            self.activity.set_text(f"Папка недоступна: {exc}")
            return
        self.open_item(self.settings.download_dir)

    def open_post(self):
        if self.post:
            self.open_item(self.post.page_url)

    def on_key(self, _controller, key, _code, modifiers):
        if modifiers & Gdk.ModifierType.CONTROL_MASK:
            if key == Gdk.KEY_l:
                self.entry.grab_focus()
                self.entry.select_region(0, -1)
                return True
            if key == Gdk.KEY_w:
                self.close()
                return True
        return False

    def on_close(self, *_):
        self.closed = True
        self.network.shutdown(wait=False, cancel_futures=True)
        self.previews.shutdown(wait=False, cancel_futures=True)
        return False


def install_style():
    palette_file = Path.home() / ".cache/theme/palette.json"
    try:
        palette = json.loads(palette_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        palette = {}

    def color(key, fallback):
        value = palette.get(key) if isinstance(palette, dict) else None
        return value if isinstance(value, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", value) else fallback

    accent = color("accent", "#aa94df")
    ink = color("bg", "#1f1b2b")
    panel = color("bg_light", "#323042")
    provider = Gtk.CssProvider()
    provider.load_from_string(f"""
        .anime-wall .inspector {{ padding: 12px; border-radius: 10px; background-color: {panel}; }}
        .anime-wall .thumbnail {{ border-radius: 8px; background-color: {panel}; }}
        .anime-wall flowboxchild {{ padding: 5px; border-radius: 8px; }}
        .anime-wall flowboxchild:selected {{ outline: 2px solid {accent}; outline-offset: -2px; }}
        .anime-wall button.suggested-action {{ background: {accent}; color: {ink}; }}
        .anime-wall button.suggested-action:disabled {{ opacity: 0.45; }}
    """)
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                             Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def run(api, settings, parser, state, config_path):
    Gtk.init()
    if not Gdk.Display.get_default():
        raise api.BooruError("no graphical session")
    app = Gtk.Application(application_id="io.github.kir1ght.AnimeWall")

    def activate(application):
        window = application.get_active_window()
        if window is None:
            install_style()
            window = Gallery(application, api, settings, parser, state, config_path)
        window.present()

    app.connect("activate", activate)
    return app.run([])
