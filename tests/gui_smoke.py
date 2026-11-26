"""Run with xvfb-run -a env GTK_A11Y=none GSK_RENDERER=cairo python3 tests/gui_smoke.py."""
import os
from pathlib import Path
import runpy
import sys
import tempfile
import time
from types import SimpleNamespace

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
from anime_wall_ui import Gallery, Gio, GLib, Gtk, install_style


def check_gallery(folder):
    image = folder / "preview.img"
    Image.new("RGB", (320, 200), "#8858b1").save(image, format="PNG")
    api = SimpleNamespace(**runpy.run_path(str(ROOT / "bin" / "anime-wall")))

    def search(query, *_args, **_kwargs):
        if query.tags == "old":
            time.sleep(0.3)
        else:
            time.sleep(0.02)
        return [api.Post(query.provider, 1 if query.tags == "old" else 2,
                         "https://example.invalid/image.png", "https://example.invalid/preview",
                         1920, 1080, 100, "s", "landscape")]

    api.preview_path = lambda _post: image
    api.fetch_posts = search
    api.cached_raw_count = lambda _: 24
    api.fetch_tag_suggestions = lambda *_: [("landscape", 8)]
    actions = []

    def save(post, _, apply, **_kwargs):
        actions.append((post.id, apply))
        return SimpleNamespace(poll=lambda: 0)

    api.start_download = save
    app = Gtk.Application(flags=Gio.ApplicationFlags.NON_UNIQUE)
    errors = []

    def activate(application):
        install_style()
        config = folder / "config.ini"
        window = Gallery(application, api, api.Settings(download_dir=folder / "vault"),
                         api.load_config(config), {}, config)
        window.present()
        window.entry.set_text("old")
        window.search()
        window.entry.set_text("new")
        window.search()
        window.tag_menu.popup()

        def inspect():
            try:
                assert window.post and window.post.id == 2, "stale results replaced the newest search"
                assert window.large.get_paintable(), "preview did not reach the inspector"
                assert window.next.get_sensitive(), "next page is unavailable"
                popup = window.tag_menu.get_popover()
                assert popup and "landscape" in popup.get_child().get_last_child().get_label(), "no tag hint"
                window.download.emit("clicked")
                assert actions == [(2, False)], "download must not apply"
            except Exception as exc:
                errors.append(exc)
                window.close()
                return False

            def applied():
                try:
                    assert window.download.get_sensitive(), "download did not finish"
                    window.apply.emit("clicked")
                    assert actions == [(2, False), (2, True)], "apply didn't use the selected art"
                except Exception as exc:
                    errors.append(exc)
                finally:
                    window.close()
                return False

            GLib.timeout_add(350, applied)
            return False

        GLib.timeout_add(1100, inspect)

    app.connect("activate", activate)
    app.run([])
    if errors:
        raise errors[0]


with tempfile.TemporaryDirectory() as work:
    os.environ["XDG_CACHE_HOME"] = work
    os.environ["XDG_CONFIG_HOME"] = work
    check_gallery(Path(work))
    print("GTK search, paging, async preview, tag hints, save/apply: OK")
