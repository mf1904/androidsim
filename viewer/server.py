"""Dinding emulator: layar semua emulator erp-NN dalam satu halaman, 6 HP dalam 2 baris, dengan menu on/off.

Hanya mendengarkan 127.0.0.1; tanpa dependensi di luar stdlib.
  GET  /                   halaman dinding (index.html, token sesi disisipkan)
  GET  /api/devices?n=6    JSON: emulator online, status sibuk, memori, perkiraan RAM
  GET  /shot/<serial>.png  PNG layar terkini satu emulator (adb screencap)
  POST /api/power          nyalakan/matikan emulator lewat devices.sh (headless)
  POST /api/input          kontrol HP: tap, geser, tekan lama, tombol (Back/Home/...), ketik teks (adb input)
Pengaman POST: Host dan Origin harus 127.0.0.1/localhost:PORT, header X-Token harus cocok dengan token
yang dibuat saat server start. /api/power menjalankan perintah tetap (devices.sh start|stop <nomor>);
/api/input hanya mengizinkan jenis aksi dan kode tombol dalam daftar putih, koordinat dibatasi 0..1, dan teks
dibatasi ASCII yang dikutip aman untuk shell di emulator. Isi teks tidak pernah dicatat di log.
Env: VIEWER_PORT (default 8765), ANDROID_HOME
"""
import atexit
import json
import os
import re
import secrets
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DEVICES_SH = ROOT / "devices.sh"
ANDROID_HOME = os.environ.get("ANDROID_HOME", "/opt/homebrew/share/android-commandlinetools")
ADB = os.path.join(ANDROID_HOME, "platform-tools", "adb")
PORT = int(os.environ.get("VIEWER_PORT", "8765"))
ALLOWED_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}  # tolak Host lain (DNS rebinding)
ALLOWED_ORIGINS = {f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"}
TOKEN = secrets.token_urlsafe(24)
MAX_AVDS = 10
MIN_FRAME_INTERVAL = 0.25  # detik antar screencap per emulator, agar beberapa tab tidak membebani emulator
STATE_TTL = 3.0
MIN_FREE_PCT = 15  # tolak menyalakan emulator baru bila memori bebas di bawah ini

SHOT_RE = re.compile(r"/shot/(emulator-\d+)\.png")
AVD_RE = re.compile(r"erp-(\d{2})")


def adb(*args, timeout=6, binary=False):
    r = subprocess.run([ADB, *args], capture_output=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode("utf-8", "replace").strip() or f"adb exit {r.returncode}")
    return r.stdout if binary else r.stdout.decode("utf-8", "replace")


def account_roles():
    """Role per nomor AVD dari maestro/accounts.env. Hanya ACC_NN_ROLE yang dibaca, tidak pernah USER/PASS."""
    try:
        text = (ROOT / "maestro" / "accounts.env").read_text(encoding="utf-8")
    except OSError:
        return {}
    return {int(n): role for n, role in re.findall(r"ACC_(\d+)_ROLE=([A-Za-z0-9_-]+)", text)}


def memory_info():
    free_pct = swap_mb = None
    try:
        out = subprocess.run(["memory_pressure"], capture_output=True, timeout=5).stdout.decode("utf-8", "replace")
        m = re.search(r"free percentage:\s*(\d+)%", out)
        free_pct = int(m.group(1)) if m else None
    except Exception:
        pass
    try:
        out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, timeout=5).stdout.decode()
        m = re.search(r"used = ([\d.]+)M", out)
        swap_mb = int(float(m.group(1))) if m else None
    except Exception:
        pass
    return {"free_pct": free_pct, "swap_mb": swap_mb}


_est_cache = {}


def estimate_mb(n):
    """Perkiraan RAM host (MB) untuk n emulator headless, dari `devices.sh estimate` (satu sumber rumus)."""
    hit = _est_cache.get(n)
    if hit and time.time() - hit[0] < 60:
        return hit[1]
    val = None
    try:
        env = dict(os.environ, HEADLESS="1", ANDROID_HOME=ANDROID_HOME)
        out = subprocess.run(["bash", str(DEVICES_SH), "estimate", str(n)], env=env,
                             capture_output=True, timeout=10).stdout.decode()
        m = re.search(r"~(\d+) MB", out)
        val = int(m.group(1)) if m else None
    except Exception:
        pass
    _est_cache[n] = (time.time(), val)
    return val


_state = {"ts": 0.0, "devices": [], "mem": {}}
_state_lock = threading.Lock()
_busy = {}  # nama AVD -> "starting" | "stopping"
_busy_lock = threading.Lock()


def refresh_state(force=False):
    with _state_lock:
        if not force and time.time() - _state["ts"] < STATE_TTL:
            return _state
        roles = account_roles()
        out = []
        try:
            lines = adb("devices").splitlines()[1:]
        except Exception:
            lines = []
        for line in lines:
            parts = line.split()
            if len(parts) < 2 or parts[1] != "device" or not re.fullmatch(r"emulator-\d+", parts[0]):
                continue
            serial = parts[0]
            try:
                avd = adb("-s", serial, "emu", "avd", "name", timeout=4).splitlines()[0].strip()
                api = adb("-s", serial, "shell", "getprop", "ro.build.version.sdk", timeout=4).strip()
            except Exception:
                continue
            m = AVD_RE.fullmatch(avd)
            out.append({"serial": serial, "avd": avd, "api": api,
                        "role": roles.get(int(m.group(1)), "") if m else ""})
        out.sort(key=lambda d: int(d["serial"].split("-")[1]))
        _state.update(ts=time.time(), devices=out, mem=memory_info())
        return _state


class Frame:
    def __init__(self):
        self.lock = threading.Lock()
        self.ts = 0.0
        self.png = b""


_frames = {}


# Folder frame HARUS tanpa spasi: konsol emulator memecah argumen di spasi dan, bila path berspasi
# (mis. "Android Sim"), tetap menjawab OK tetapi tidak menulis file. Karena itu dipakai direktori sementara.
FRAME_DIR = Path(tempfile.mkdtemp(prefix="dinding-"))
atexit.register(lambda: shutil.rmtree(FRAME_DIR, ignore_errors=True))
CONSOLE_OK = not re.search(r"\s", str(FRAME_DIR))
PNG_END = b"IEND\xaeB`\x82"
_console_bad_until = {}  # serial -> waktu sampai metode konsol dilewati setelah gagal


def console_shot(serial):
    """Frame dari sisi host lewat konsol emulator (`emu screenrecord screenshot`).

    Terukur ~30x lebih murah di CPU daripada `adb exec-out screencap -p`, yang mengompres PNG di dalam guest
    (6 emulator, 4 gambar/detik: +4% vs +132% CPU) dan ~0,06 dtk vs ~0,4 dtk per gambar.
    """
    if not CONSOLE_OK:
        raise RuntimeError("direktori sementara berspasi")
    d = FRAME_DIR / serial
    d.mkdir(parents=True, exist_ok=True)
    for old in d.glob("*.png"):
        old.unlink(missing_ok=True)
    adb("-s", serial, "emu", "screenrecord", "screenshot", str(d), timeout=6)
    deadline = time.time() + 1.5
    while time.time() < deadline:
        files = sorted(d.glob("*.png"), key=lambda p: p.stat().st_mtime)
        if files:
            data = files[-1].read_bytes()
            if data.startswith(b"\x89PNG") and data.endswith(PNG_END):
                for f in files:
                    f.unlink(missing_ok=True)
                return data
        time.sleep(0.03)
    raise RuntimeError("screenshot konsol tidak lengkap")


def get_frame(serial):
    f = _frames.setdefault(serial, Frame())
    with f.lock:
        if f.png and time.time() - f.ts < MIN_FRAME_INTERVAL:
            return f.png
        png = None
        if time.time() >= _console_bad_until.get(serial, 0.0):
            try:
                png = console_shot(serial)
            except Exception:
                _console_bad_until[serial] = time.time() + 60  # jangan buang 1,5 dtk tiap permintaan
        if png is None:
            # cadangan: screencap di dalam guest (lebih mahal di CPU, tapi tidak bergantung pada konsol emulator)
            png = adb("-s", serial, "exec-out", "screencap", "-p", timeout=8, binary=True)
            if not png.startswith(b"\x89PNG"):
                raise RuntimeError("keluaran screencap bukan PNG")
        f.png, f.ts = png, time.time()
        return f.png


def power(idx, action, delay=0.0):
    """Jalankan `devices.sh start|stop <idx>` di thread latar. False bila AVD itu masih sibuk."""
    avd = f"erp-{idx:02d}"
    with _busy_lock:
        if avd in _busy:
            return False
        _busy[avd] = "starting" if action == "on" else "stopping"

    def job():
        try:
            if delay:
                time.sleep(delay)
            env = dict(os.environ, HEADLESS="1", ANDROID_HOME=ANDROID_HOME)
            subprocess.run(["bash", str(DEVICES_SH), "start" if action == "on" else "stop", str(idx)],
                           env=env, capture_output=True, timeout=420)
        except Exception:
            pass
        finally:
            with _busy_lock:
                _busy.pop(avd, None)
            with _state_lock:
                _state["ts"] = 0.0

    threading.Thread(target=job, daemon=True).start()
    return True


def handle_power(body):
    action = body.get("action")
    if action not in ("on", "off"):
        return 400, {"ok": False, "error": "action harus on/off"}
    online = {d["avd"] for d in refresh_state(force=True)["devices"]}
    if body.get("all"):
        n = body.get("n")
        if not isinstance(n, int) or not 1 <= n <= MAX_AVDS:
            return 400, {"ok": False, "error": f"n harus 1..{MAX_AVDS}"}
        targets = [i for i in range(1, n + 1) if (f"erp-{i:02d}" in online) == (action == "off")]
    else:
        m = AVD_RE.fullmatch(str(body.get("avd", "")))
        if not m or not 1 <= int(m.group(1)) <= MAX_AVDS:
            return 400, {"ok": False, "error": "avd tidak valid"}
        idx = int(m.group(1))
        targets = [idx] if (f"erp-{idx:02d}" in online) == (action == "off") else []
    if action == "on" and targets:
        free = memory_info()["free_pct"]
        if free is not None and free < MIN_FREE_PCT:
            return 409, {"ok": False, "error": f"memori hampir habis (bebas {free}%), tidak menyalakan emulator lagi"}
    started = []
    for k, idx in enumerate(targets):
        if power(idx, action, delay=2.0 * k if action == "on" else 0.0):
            started.append(f"erp-{idx:02d}")
    return 200, {"ok": True, "diproses": started}


INPUT_KEYS = {"back": 4, "home": 3, "recents": 187, "enter": 66, "delete": 67}  # KEYCODE_* Android
MAX_TEXT = 200
_input_locks = {}


def display_size(serial):
    """Ukuran layar (piksel) dari header PNG frame terbaru: dipakai memetakan koordinat 0..1 ke piksel."""
    png = get_frame(serial)
    return struct.unpack(">II", png[16:24])


def _frac(body, key):
    v = body.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0.0 <= v <= 1.0:
        raise ValueError(key)
    return float(v)


def _text_arg(text):
    """Kutip aman untuk shell di emulator + format `input text` (spasi jadi %s). Hanya ASCII tercetak."""
    if not isinstance(text, str) or not 1 <= len(text) <= MAX_TEXT:
        raise ValueError("text")
    if any(not 0x20 <= ord(c) <= 0x7E for c in text):
        raise ValueError("text")
    return "'" + text.replace(" ", "%s").replace("'", "'\\''") + "'"


def handle_input(body):
    serial = body.get("serial")
    if not isinstance(serial, str) or not re.fullmatch(r"emulator-\d+", serial):
        return 400, {"ok": False, "error": "serial tidak valid"}
    if serial not in {d["serial"] for d in refresh_state()["devices"]}:
        return 404, {"ok": False, "error": "emulator tidak online"}
    kind = body.get("type")
    try:
        if kind in ("tap", "longpress"):
            w, h = display_size(serial)
            x, y = round(_frac(body, "x") * (w - 1)), round(_frac(body, "y") * (h - 1))
            args = ["tap", x, y] if kind == "tap" else ["swipe", x, y, x, y, 800]
        elif kind == "swipe":
            w, h = display_size(serial)
            x1, y1 = round(_frac(body, "x") * (w - 1)), round(_frac(body, "y") * (h - 1))
            x2, y2 = round(_frac(body, "x2") * (w - 1)), round(_frac(body, "y2") * (h - 1))
            ms = body.get("ms", 300)
            if isinstance(ms, bool) or not isinstance(ms, (int, float)):
                raise ValueError("ms")
            args = ["swipe", x1, y1, x2, y2, int(min(max(ms, 50), 2000))]
        elif kind == "key":
            code = INPUT_KEYS.get(body.get("key"))
            if code is None:
                raise ValueError("key")
            args = ["keyevent", code]
        elif kind == "text":
            args = ["text", _text_arg(body.get("text"))]
        else:
            raise ValueError("type")
    except ValueError as e:
        return 400, {"ok": False, "error": f"parameter tidak valid: {e}"}
    except Exception as e:
        return 502, {"ok": False, "error": f"gagal membaca layar: {e}"}
    with _input_locks.setdefault(serial, threading.Lock()):
        try:
            adb("-s", serial, "shell", "input", *[str(a) for a in args], timeout=6)
        except Exception:
            return 502, {"ok": False, "error": "adb gagal mengirim input"}
    f = _frames.get(serial)
    if f:
        f.ts = 0.0  # frame berikutnya harus segar agar hasil input langsung terlihat
    return 200, {"ok": True}


class Handler(BaseHTTPRequestHandler):
    server_version = "DindingEmulator/3"

    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype):
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def _host_ok(self):
        return self.headers.get("Host", "") in ALLOWED_HOSTS

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, b"forbidden", "text/plain; charset=utf-8")
        path, _, query = self.path.partition("?")
        if path in ("/", "/index.html"):
            page = (HERE / "index.html").read_text(encoding="utf-8").replace("__TOKEN__", TOKEN)
            return self._send(200, page.encode(), "text/html; charset=utf-8")
        if path == "/api/devices":
            m = re.search(r"(?:^|&)n=(\d+)", query)
            n = min(max(int(m.group(1)), 1), MAX_AVDS) if m else 6
            st = refresh_state()
            with _busy_lock:
                busy = dict(_busy)
            return self._json(200, {"devices": st["devices"], "busy": busy, "mem": st["mem"],
                                    "est_mb": estimate_mb(n), "min_free_pct": MIN_FREE_PCT})
        m = SHOT_RE.fullmatch(path)
        if m:
            try:
                return self._send(200, get_frame(m.group(1)), "image/png")
            except Exception as e:
                return self._send(503, str(e).encode(), "text/plain; charset=utf-8")
        self._send(404, b"not found", "text/plain; charset=utf-8")

    def do_POST(self):
        if not self._host_ok() or self.headers.get("Origin", "") not in ALLOWED_ORIGINS:
            return self._send(403, b"forbidden", "text/plain; charset=utf-8")
        if not secrets.compare_digest(self.headers.get("X-Token", ""), TOKEN):
            return self._send(403, b"forbidden", "text/plain; charset=utf-8")
        handler = {"/api/power": handle_power, "/api/input": handle_input}.get(self.path.split("?", 1)[0])
        if handler is None:
            return self._send(404, b"not found", "text/plain; charset=utf-8")
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= 4096:
                return self._json(413, {"ok": False, "error": "body tidak valid"})
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"ok": False, "error": "JSON tidak valid"})
        code, obj = handler(body)
        self._json(code, obj)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))  # agar atexit membersihkan folder frame saat `view stop`
    srv = Server(("127.0.0.1", PORT), Handler)
    print(f"Dinding emulator di http://127.0.0.1:{PORT}", flush=True)
    srv.serve_forever()
