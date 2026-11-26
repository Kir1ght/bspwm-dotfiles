"""Offline tests: no real wallpaper, audio service or X session is changed."""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    loader.exec_module(module)
    return module


wall = load("anime_wall", "bin/anime-wall")
hid = load("vxe_battery", "bin/vxe-battery")
theme = load("wallpaper_theme", "config/theme/apply.py")


class HTTPFixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        endpoint = self.path.partition("?")[0]
        if endpoint == "/slow":
            self.send_response(200)
            self.end_headers()
            try:
                for _ in range(12):
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(0.15)
            except OSError:
                pass
            return
        status, data = {
            "/json": (200, b'[{"id": 1}]'),
            "/image.png": (200, self.server.image),
            "/bad.png": (200, b"\x89PNG\r\n\x1a\nbroken"),
            "/big": (200, b"x" * 4096),
        }.get(endpoint, (429, b""))
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class WallpaperNetwork(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name)
        cache = patch.dict(os.environ, XDG_CACHE_HOME=str(self.path / "cache"),
                           XDG_CONFIG_HOME=str(self.path / "config"),
                           NO_PROXY="localhost,127.0.0.1")
        cache.start()
        self.addCleanup(cache.stop)
        server = ThreadingHTTPServer(("127.0.0.1", 0), HTTPFixture)
        image = self.path / "image.png"
        Image.new("RGB", (8, 8), "#763b9e").save(image)
        server.image = image.read_bytes()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.url = f"http://127.0.0.1:{server.server_port}"

    def post(self, path):
        return wall.normalize({"id": 1, "file_url": path, "width": "unknown",
                               "rating": "g", "tags": []}, "danbooru", self.url)

    def test_api_and_bounded_transfer(self):
        self.assertEqual(wall.http_json(self.url + "/json", {"tags": "space here"}),
                         [{"id": 1}])
        with self.assertRaisesRegex(wall.BooruError, "Rate limited"):
            wall.http_json(self.url + "/no", {})
        with self.assertRaisesRegex(wall.BooruError, "size limit"):
            wall.transfer(self.url + "/big", {}, self.path / "big", 1, 1024)
        start = time.monotonic()
        with self.assertRaisesRegex(wall.BooruError, "timed out"):
            wall.http_json(self.url + "/slow", {}, timeout=1)
        self.assertLess(time.monotonic() - start, 1.8)

    def test_download_validation_and_reuse(self):
        store = self.path / "vault"
        with self.assertRaisesRegex(wall.BooruError, "invalid image"):
            wall.download(self.post("/bad.png"), store)
        self.assertEqual(list(store.iterdir()), [])
        post = self.post("/image.png")
        target = wall.download(post, store)
        with patch.object(wall, "transfer", side_effect=AssertionError("cache missed")):
            self.assertEqual(wall.download(post, store), target)
        self.assertEqual(post.width, 0)
        self.assertEqual(post.tags, "")

    def test_unsafe_rating_and_bad_state(self):
        sensitive = wall.normalize({"id": 2, "file_url": "/image.png",
                                    "rating": "s"}, "danbooru", self.url)
        self.assertEqual(sensitive.normalized_rating(), "unknown")
        wall.state_file().write_text('{"last_tags": []}')
        self.assertEqual(wall.load_state()["last_tags"], {})

    def test_apply_failure_is_visible(self):
        with patch.object(wall, "wallpaper_apply_command",
                          return_value=[sys.executable, "-c", "raise SystemExit(1)"]):
            with self.assertRaisesRegex(wall.BooruError, "random_wallpaper failed"):
                wall.apply_wallpaper(self.path / "image.png")

    def test_stale_cache_is_available_when_provider_times_out(self):
        settings = wall.Settings(provider="yandere", min_width=0, min_height=0)
        wall.write_api_cache(wall.api_cache_key(settings), [
            {"id": 1, "file_url": self.url + "/image.png", "rating": "s",
             "width": 2048, "height": 1536, "score": 100},
        ])
        with patch.object(wall, "http_json", side_effect=wall.BooruError("timeout")):
            posts = wall.fetch_posts(settings, wall.load_config(), use_cache=False, quiet=True)
        self.assertEqual([post.id for post in posts], [1])

    def test_older_download_does_not_replace_newer_selection(self):
        post = self.post("/image.png")
        (wall.cache_dir() / "apply.latest").write_text("new")
        payload = wall.json.dumps({"post": wall.asdict(post),
                                   "download_dir": str(self.path), "apply": "old"})
        with patch.object(wall, "apply_wallpaper", side_effect=AssertionError("obsolete apply")):
            self.assertEqual(wall.download_one(payload), 0)
        self.assertTrue(list(self.path.rglob("danbooru_1.png")))


class Scripts(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), DISPLAY=":90",
                        XDG_RUNTIME_DIR=str(self.home), PATH=f"{self.bin}:{os.environ['PATH']}")

    def stub(self, name, script):
        stub = self.bin / name
        stub.write_text("#!/bin/sh\n" + script)
        stub.chmod(0o755)

    def run_script(self, name, *args):
        return subprocess.run([str(ROOT / "bin" / name), *args], env=self.env,
                              capture_output=True, text=True, timeout=8)

    def test_fd_sanitizer(self):
        read, write = os.pipe()
        try:
            result = subprocess.run(
                [str(ROOT / "bin/desktop-no-fds"), sys.executable, "-c",
                 f"import os; assert not os.path.exists('/proc/self/fd/{write}')"],
                pass_fds=(write,), capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            os.close(read)
            os.close(write)

    def test_caffeine_saves_enforces_and_restores_display_policy(self):
        self.stub("setsid", "exit 0\n")
        (self.home / "x-state").write_text("300 20 Enabled 600 900 1200\n")
        self.stub("xset", """read -r saver cycle dpms standby suspend off <"$HOME/x-state"
case "$*" in
q) echo "  timeout: $saver    cycle: $cycle"
   echo "  Standby: $standby    Suspend: $suspend    Off: $off"
   echo "  DPMS is $dpms"; exit 0 ;;
's off') saver=0 ;;
s\\ *) saver=$2; cycle=$3 ;;
dpms\\ *) standby=$2; suspend=$3; off=$4; dpms=Enabled ;;
-dpms) dpms=Disabled ;;
+dpms) dpms=Enabled ;;
*) exit 1 ;;
esac
echo "$saver $cycle $dpms $standby $suspend $off" >"$HOME/x-state"
""")
        state = self.home / "x-state"
        self.assertEqual(self.run_script("caffeine.sh", "--on").returncode, 0)
        self.assertEqual(state.read_text(), "0 20 Disabled 0 0 0\n")
        self.assertEqual(self.run_script("caffeine.sh", "--active").returncode, 0)
        state.write_text("300 20 Enabled 600 900 1200\n")
        self.assertEqual(self.run_script("caffeine.sh", "--restore").returncode, 0)
        self.assertEqual(state.read_text(), "0 20 Disabled 0 0 0\n")
        self.assertEqual(self.run_script("caffeine.sh", "--off").returncode, 0)
        self.assertEqual(state.read_text(), "300 20 Enabled 600 900 1200\n")
        self.assertNotEqual(self.run_script("caffeine.sh", "--active").returncode, 0)

    def test_quit_not_sent_to_unresponsive_wm(self):
        self.stub("bspc", '''printf '%s\\n' "$*" >>"$HOME/bspc-log"
[ "$1" != query ] || exec sleep 10
''')
        result = self.run_script("bspwmctl", "wm", "-r")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / "bspc-log").read_text(), "query -M\n")

    def test_wallpaper_reports_feh_failure_and_escapes_filenames(self):
        images = self.home / "Images/Wallpaper_desktop"
        images.mkdir(parents=True)
        image = images / """a'$(false)".png"""
        image.touch()
        self.stub("xdpyinfo", "echo 'dimensions: 2560x1600 pixels'\n")
        self.stub("vipsthumbnail", "exit 1\n")
        self.stub("feh", "exit 1\n")
        self.assertNotEqual(self.run_script("random_wallpaper", "--set", str(image)).returncode, 0)
        self.assertFalse((self.home / ".current_wallpaper").is_symlink())
        self.stub("feh", 'printf "%s" "$3" >"$HOME/feh-applied"\n')
        result = self.run_script("random_wallpaper", "--set", str(image))
        self.assertEqual(result.returncode, 0, result.stderr)
        subprocess.run(["sh", str(self.home / ".fehbg")], env=self.env, check=True)
        self.assertEqual((self.home / "feh-applied").read_text(), str(image))

    def test_hdmi_mirror_modes(self):
        self.stub("xrandr", """case "$1" in
--query) cat <<'EOF'
eDP-1 connected primary 2560x1600+0+0
   2560x1600     180.00*+ 60.00
   1920x1080      60.00
HDMI-1-0 connected
   1920x1080      60.00+
EOF
;;
*) printf '%s\\n' "$*" >"$HOME/randr-args";;
esac
""")
        result = self.run_script("hdmi", "mirror")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--scale-from 2560x1600 --pos 0x0", (self.home / "randr-args").read_text())
        result = self.run_script("hdmi", "mirror", "--common")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--scale-from", (self.home / "randr-args").read_text())
        self.assertIn("--output eDP-1 --mode 1920x1080", (self.home / "randr-args").read_text())
        result = self.run_script("hdmi", "off")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--output eDP-1 --mode 2560x1600 --rate 180.00",
                      (self.home / "randr-args").read_text())

    def test_hid_fallback_bounds(self):
        reply = bytearray(17)
        self.assertEqual(hid.parse(reply, 0x17), (0, None, None))
        reply[5] = 51
        self.assertIsNone(hid.parse(reply, 0x17))
        with patch.object(hid, "candidates", return_value=iter(())):
            with self.assertRaises(FileNotFoundError):
                hid.read_battery()

    def test_cancelled_gtk_generation_does_not_replace_installed_theme(self):
        themes = self.home / ".themes"
        source = themes / "Dracula"
        target = themes / "Dynamic"
        source.mkdir(parents=True)
        target.mkdir()
        (source / "gtk.css").write_text("#bd93f9")
        (target / "gtk.css").write_text("existing")
        palette = theme.build_palette(250, 0.55)
        with patch.object(theme, "HOME", self.home), \
             patch.object(theme, "CFG", self.home / ".config"), \
             patch.object(theme, "log"), \
             patch.object(theme, "stage_gtk", return_value=False):
            self.assertFalse(theme.apply_gtk(palette))
        self.assertEqual((target / "gtk.css").read_text(), "existing")


if __name__ == "__main__":
    unittest.main()
