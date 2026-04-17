#!/usr/bin/env python3
# =============================================================================
# server.py — StreamOps Management API  (Windows Edition)
# =============================================================================
# Architecture: Pure Python stdlib — no pip dependencies except psutil
#
# Endpoints:
#   GET  /api/status           — Service + stream health
#   GET  /api/keys             — Stream key values (masked)
#   POST /api/keys             — Update stream keys
#   POST /api/control          — Start/stop/restart Windows services
#   GET  /api/clips            — List AI-generated highlight clips
#   POST /api/clips/trigger    — Manually trigger a clip extraction
#   POST /api/clips/delete     — Delete a clip by ID
#   GET  /api/recordings       — List MP4 recordings
#   GET  /api/logs             — Tail a log file (nginx→mediamtx, ffmpeg, clipper)
#   GET  /api/metrics          — Real CPU/RAM/disk via psutil or WMI
#   GET  /api/health           — Quick health ping
#   GET  /                     — Serve dashboard (static files)
#   GET  /watch                — Serve public viewer page
#
# Windows services managed: mediamtx, fb-relay, stream-clipper, watchdog (NSSM)
# =============================================================================

import os, json, logging, subprocess, threading, time, uuid, secrets, ctypes, shutil
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import mimetypes

# ── Configuration ─────────────────────────────────────────────────────────────
BASE_DIR        = Path(os.environ.get("STREAMING_BASE", r"C:\streaming-backend"))
KEYS_FILE       = BASE_DIR / "keys" / "stream_keys.env"
TOKEN_FILE      = BASE_DIR / "keys" / "api_token"
CLIPS_INDEX     = BASE_DIR / "clips" / "index.json"
CLIPS_DIR       = BASE_DIR / "www"   / "clips"
RECORDINGS_DIR  = BASE_DIR / "recordings"
HLS_DIR         = BASE_DIR / "www"   / "hls"
WWW_DIR         = BASE_DIR / "www"
DASHBOARD_DIR   = BASE_DIR / "dashboard"
VIEWER_DIR      = BASE_DIR / "viewer"
LOG_DIR         = BASE_DIR / "logs"
MEDIAMTX_API    = "http://127.0.0.1:9997"
PORT            = 3000
FFMPEG_BIN      = BASE_DIR / "bin" / "ffmpeg.exe"   # falls back to PATH if missing
if not FFMPEG_BIN.exists():
    FFMPEG_BIN  = Path("ffmpeg")                    # use system ffmpeg

LOG_MAP = {
    "mediamtx": BASE_DIR / "logs" / "mediamtx.log",
    "ffmpeg":   BASE_DIR / "logs" / "fb_relay.log",
    "clipper":  BASE_DIR / "logs" / "clipper.log",
    "api":      BASE_DIR / "logs" / "api.log",
}

# Allowlists for service control
ALLOWED_ACTIONS  = {"start", "stop", "restart"}
ALLOWED_SERVICES = {"mediamtx", "fb-relay", "stream-clipper", "watchdog", "all"}

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(str(LOG_DIR / "api.log"), encoding="utf-8"),
        logging.StreamHandler(),
    ]
)
log = logging.getLogger("stream-api")

# ── Token Auth ────────────────────────────────────────────────────────────────
def _load_token() -> str:
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text(encoding="utf-8").strip()
    token = secrets.token_hex(32)
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(token, encoding="utf-8")
    log.info(f"Generated new API token → {TOKEN_FILE}")
    print(f"\n  ⚡ API Token: {token}\n  Save this — Dashboard uses it to authenticate.\n")
    return token

API_TOKEN = _load_token()

def _check_auth(handler) -> bool:
    """Allow local network access without token (same as router admin UI).
    Token auth is only enforced for external/internet requests."""
    raw_ip = handler.client_address[0]
    # Normalize IPv4-mapped IPv6 (Windows dual-stack: ::ffff:192.168.1.x → 192.168.1.x)
    client_ip = raw_ip[7:] if raw_ip.startswith('::ffff:') else raw_ip
    # Always allow from localhost and private RFC-1918 ranges
    if (client_ip.startswith('127.') or
        client_ip.startswith('192.168.') or
        client_ip.startswith('10.') or
        client_ip == '::1' or
        (client_ip.startswith('172.') and
         any(client_ip.startswith(f'172.{i}.') for i in range(16, 32)))):
        return True
    # External access: require valid token
    token = handler.headers.get('X-API-Token', '')
    if not token:
        return False
    return secrets.compare_digest(token.encode(), API_TOKEN.encode())

# ── Helpers ───────────────────────────────────────────────────────────────────
def _run(*args, capture=True, timeout=30):
    try:
        r = subprocess.run(
            list(args), capture_output=capture, text=True,
            timeout=timeout, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except FileNotFoundError as e:
        return -1, "", str(e)

def _win_service_status(svc: str) -> str:
    """Query Windows service status using sc.exe"""
    rc, out, _ = _run("sc", "query", svc)
    if rc == 0 and "RUNNING" in out:
        return "active"
    elif rc == 0 and "STOPPED" in out:
        return "inactive"
    # Try NSSM if sc doesn't know it
    rc2, out2, _ = _run("nssm", "status", svc)
    if rc2 == 0:
        return "active" if "SERVICE_RUNNING" in out2 else "inactive"
    return "unknown"

_POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

def _win_service_control(action: str, svc: str):
    """Start/stop/restart a Windows service via PowerShell (always at absolute path)."""
    if action == "start":
        ps_cmd = f"Start-Service -Name '{svc}' -ErrorAction SilentlyContinue"
    elif action == "stop":
        ps_cmd = f"Stop-Service  -Name '{svc}' -Force -ErrorAction SilentlyContinue"
    elif action == "restart":
        ps_cmd = f"Restart-Service -Name '{svc}' -Force -ErrorAction SilentlyContinue"
    else:
        return -1, "", "Unknown action"

    rc, out, err = _run(_POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", ps_cmd)

    # If exit code says ok OR the service is now in the desired state, treat as success
    if rc != 0 and action == "start":
        # A service already running is not an error
        rc2, st, _ = _run(_POWERSHELL, "-NoProfile", "-NonInteractive", "-Command",
                           f"(Get-Service '{svc}' -ErrorAction SilentlyContinue).Status")
        if st.strip() == "Running":
            rc = 0

    return rc, out, err

def _load_keys() -> dict:
    keys = {"yt": "", "fb": "", "fb_rtmps_url": "rtmps://live-api-s.facebook.com:443/rtmp/"}
    if not KEYS_FILE.exists():
        return keys
    for line in KEYS_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip().strip('"')
        if k == "YT_STREAM_KEY":
            keys["yt"] = v if not v.startswith("YOUR_") else ""
        elif k == "FB_STREAM_KEY":
            keys["fb"] = v if not v.startswith("YOUR_") else ""
        elif k == "FB_RTMPS_URL":
            keys["fb_rtmps_url"] = v
    return keys

def _mask(val: str) -> str:
    if not val or len(val) < 4:
        return "••••" if val else ""
    return "••••" + val[-4:]

def _load_clips() -> list:
    try:
        if CLIPS_INDEX.exists():
            return json.loads(CLIPS_INDEX.read_text(encoding="utf-8"))
    except Exception:
        pass
    return []

def _save_clips(clips: list):
    CLIPS_INDEX.parent.mkdir(parents=True, exist_ok=True)
    CLIPS_INDEX.write_text(json.dumps(clips, indent=2), encoding="utf-8")

# ── MediaMTX API Helpers ──────────────────────────────────────────────────────
def _mediamtx_get(path: str) -> dict | None:
    """Fetch from MediaMTX REST API"""
    from urllib.request import urlopen
    from urllib.error import URLError
    try:
        with urlopen(f"{MEDIAMTX_API}{path}", timeout=3) as r:
            return json.loads(r.read())
    except Exception:
        return None

def _get_stream_info() -> dict:
    """Parse MediaMTX /v3/paths/list for live stream status + bitrate"""
    data = _mediamtx_get("/v3/paths/list")
    if not data:
        return {"live": False, "readers": 0, "bitrate_kbps": 0}
    for item in data.get("items", []):
        if item.get("name") == "live":
            readers = len(item.get("readers", []))
            # MediaMTX reports bytes — compute approx bitrate from recording size growth
            return {
                "live":        item.get("ready", False),
                "readers":     readers,
                "source_type": item.get("sourceType", ""),
            }
    return {"live": False, "readers": 0}

# ── System Metrics ────────────────────────────────────────────────────────────
_psutil_available = False
try:
    import psutil
    _psutil_available = True
except ImportError:
    pass

def _get_metrics() -> dict:
    metrics = {"cpu_pct": 0.0, "ram_free_mb": 0, "ram_total_mb": 0, "disk_free_gb": 0}
    if _psutil_available:
        metrics["cpu_pct"]      = psutil.cpu_percent(interval=0.5)
        vm = psutil.virtual_memory()
        metrics["ram_free_mb"]  = round(vm.available / 1_048_576)
        metrics["ram_total_mb"] = round(vm.total / 1_048_576)
        dk = psutil.disk_usage(str(BASE_DIR))
        metrics["disk_free_gb"] = round(dk.free / 1_073_741_824, 1)
        metrics["disk_total_gb"]= round(dk.total / 1_073_741_824, 1)
    else:
        # PowerShell fallback
        rc, out, _ = _run("powershell", "-Command",
            "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory")
        if rc == 0 and out.strip().isdigit():
            metrics["ram_free_mb"] = round(int(out.strip()) / 1024)
    return metrics

# ── Threading HTTP Server ─────────────────────────────────────────────────────
class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

# ── Static File Serving Helper ────────────────────────────────────────────────
def _serve_static(handler, file_path: Path):
    if not file_path.exists():
        handler._err(404, f"File not found: {file_path.name}")
        return
    mime, _ = mimetypes.guess_type(str(file_path))
    data = file_path.read_bytes()
    handler.send_response(200)
    handler.send_header("Content-Type", mime or "application/octet-stream")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-cache")
    handler.end_headers()
    handler.wfile.write(data)

# ── Request Handler ───────────────────────────────────────────────────────────
class APIHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        log.info(f"HTTP {self.address_string()} {fmt % args}")

    def _send(self, status: int, body: dict):
        data = json.dumps(body, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-API-Token")
        self.end_headers()
        self.wfile.write(data)

    def _ok(self, body: dict = None):
        self._send(200, body or {"success": True})

    def _err(self, status: int, msg: str):
        self._send(status, {"error": msg})

    def _read_body(self) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return None

    def do_OPTIONS(self):
        self._send(204, {})

    def do_GET(self):
        parsed = urlparse(self.path)
        # Redirect /watch (no trailing slash) → /watch/ so relative assets
        # (player.js, player.css) resolve to /watch/player.js correctly
        if parsed.path == '/watch':
            self.send_response(301)
            self.send_header('Location', '/watch/')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return

        path = parsed.path.rstrip("/") or "/"
        qs   = parse_qs(parsed.query)

        # ── Static file serving (NO auth required) ────────────────────────
        if path == "/":
            _serve_static(self, DASHBOARD_DIR / "index.html"); return
        # /watch/ (rstrip → /watch) → serve viewer index
        if path == "/watch":
            _serve_static(self, VIEWER_DIR / "index.html"); return
        # /watch/player.js, /watch/player.css, etc.
        if path.startswith("/watch/"):
            fname = path[7:] or "index.html"
            _serve_static(self, VIEWER_DIR / fname); return
        if path.startswith("/clips/"):
            _serve_static(self, CLIPS_DIR / path[7:]); return
        if path.startswith("/hls/"):
            _serve_static(self, HLS_DIR / path[5:]); return
        # Any non-API path → try to serve from dashboard dir (covers app.js, style.css, favicon.ico, etc.)
        if not path.startswith("/api/"):
            fname = path.lstrip("/")
            candidate = DASHBOARD_DIR / fname
            if candidate.exists():
                _serve_static(self, candidate); return
            # Return empty 204 for favicon to avoid 401 spam
            if "favicon" in fname:
                self.send_response(204); self.end_headers(); return
            return self._err(404, f"Not found: {path}")

        # ── API token self-serve for localhost (allows dashboard to auto-load token) ──
        if path == "/api/token":
            client_ip = self.client_address[0]
            if client_ip in ("127.0.0.1", "::1", "localhost"):
                return self._ok({"token": API_TOKEN})
            return self._err(403, "Token endpoint only available from localhost")

        # ── API endpoints (auth required) ─────────────────────────────────
        if not _check_auth(self):
            return self._err(401, "Unauthorized — include X-API-Token header")

        if path == "/api/status":            return self._handle_status()
        if path == "/api/keys":              return self._handle_get_keys()
        if path == "/api/clips":             return self._handle_get_clips()
        if path == "/api/clips/snapshots":   return self._handle_clip_snapshots(qs)
        if path == "/api/recordings":        return self._handle_get_recordings()
        if path == "/api/metrics":           return self._handle_metrics()
        if path == "/api/logs":              return self._handle_logs(qs)
        if path == "/api/health":            return self._ok({"status": "ok", "uptime": int(time.time() - _START)})
        if path == "/api/streams":           return self._handle_get_streams()

        return self._err(404, f"Not found: {path}")

    def do_POST(self):
        if not _check_auth(self):
            return self._err(401, "Unauthorized — include X-API-Token header")

        path = self.path.split("?")[0].rstrip("/")
        data = self._read_body()
        if data is None:
            return self._err(400, "Invalid JSON body")

        if path == "/api/keys":           return self._handle_update_keys(data)
        if path == "/api/control":        return self._handle_control(data)
        if path == "/api/clips/trigger":  return self._handle_clip_trigger(data)
        if path == "/api/clips/delete":   return self._handle_clip_delete(data)
        if path == "/api/stream/start":   return self._handle_stream_event("start")
        if path == "/api/stream/stop":    return self._handle_stream_event("stop")

        return self._err(404, f"Not found: {path}")

    # ── GET /api/status ───────────────────────────────────────────────────────
    def _handle_status(self):
        services = {svc: _win_service_status(svc) for svc in ALLOWED_SERVICES - {"all"}}
        stream   = _get_stream_info()
        clips_ct = len(_load_clips())
        keys     = _load_keys()

        # HLS live check (file age fallback if MediaMTX API unreachable)
        hls_playlist = HLS_DIR / "live" / "index.m3u8"
        hls_live = False
        if hls_playlist.exists():
            age = time.time() - hls_playlist.stat().st_mtime
            hls_live = age < 15

        self._ok({
            "services":    services,
            "stream_live": stream.get("live", False) or hls_live,
            "hls_live":    hls_live,
            "readers":     stream.get("readers", 0),
            "clips_count": clips_ct,
            "keys_set":    {"yt": bool(keys["yt"]), "fb": bool(keys["fb"])},
            "timestamp":   int(time.time()),
        })

    # ── GET /api/keys ─────────────────────────────────────────────────────────
    def _handle_get_keys(self):
        keys = _load_keys()
        self._ok({
            "yt_masked":    _mask(keys["yt"]),
            "fb_masked":    _mask(keys["fb"]),
            "yt_set":       bool(keys["yt"]),
            "fb_set":       bool(keys["fb"]),
            "fb_rtmps_url": keys["fb_rtmps_url"],
        })

    # ── POST /api/keys ────────────────────────────────────────────────────────
    def _handle_update_keys(self, data: dict):
        yt_key = str(data.get("yt", "")).strip()
        fb_key = str(data.get("fb", "")).strip()
        if not yt_key and not fb_key:
            return self._err(400, "Provide at least one key (yt or fb)")

        try:
            if not KEYS_FILE.exists():
                KEYS_FILE.parent.mkdir(parents=True, exist_ok=True)
                KEYS_FILE.write_text(
                    'YT_STREAM_KEY=""\nFB_STREAM_KEY=""\nFB_RTMPS_URL="rtmps://live-api-s.facebook.com:443/rtmp/"\n',
                    encoding="utf-8"
                )
            lines = KEYS_FILE.read_text(encoding="utf-8").splitlines(keepends=True)
            new_lines = []
            for line in lines:
                s = line.strip()
                if yt_key and s.startswith("YT_STREAM_KEY="):
                    new_lines.append(f'YT_STREAM_KEY="{yt_key}"\n')
                elif fb_key and s.startswith("FB_STREAM_KEY="):
                    new_lines.append(f'FB_STREAM_KEY="{fb_key}"\n')
                else:
                    new_lines.append(line)
            KEYS_FILE.write_text("".join(new_lines), encoding="utf-8")

            # Also update mediamtx.yml YouTube push line if yt key given
            errors = []
            if yt_key:
                _update_mediamtx_yt_push(yt_key)
            if fb_key:
                # Restart fb-relay so it picks up new key
                _win_service_control("restart", "fb-relay")

            log.info(f"Keys updated: YT={'set' if yt_key else 'unchanged'} FB={'set' if fb_key else 'unchanged'}")
            self._ok({"success": True, "errors": errors})
        except PermissionError:
            self._err(500, f"Permission denied writing {KEYS_FILE}")
        except Exception as e:
            log.error(f"Key update error: {e}")
            self._err(500, str(e))

    # ── POST /api/control ─────────────────────────────────────────────────────
    def _handle_control(self, data: dict):
        action  = str(data.get("action",  "")).strip().lower()
        service = str(data.get("service", "")).strip().lower()

        if action not in ALLOWED_ACTIONS:
            return self._err(400, f"Invalid action '{action}'. Allowed: {sorted(ALLOWED_ACTIONS)}")
        if service not in ALLOWED_SERVICES:
            return self._err(400, f"Invalid service '{service}'. Allowed: {sorted(ALLOWED_SERVICES)}")

        # 'all' splits into required (must succeed) and optional (best-effort)
        if service == "all":
            required     = ["mediamtx", "stream-clipper"]
            optional_svcs = []
            if action in ("start", "restart"):
                keys = _load_keys()
                if keys.get("fb"):           # only start fb-relay if FB key configured
                    optional_svcs.append("fb-relay")
            else:                            # stop: include everything
                optional_svcs = ["fb-relay"]
            svcs         = required + optional_svcs
            optional_set = set(optional_svcs)
        else:
            svcs         = [service]
            optional_set = set()

        results  = {}
        failures = []
        for svc in svcs:
            rc, out, err = _win_service_control(action, svc)
            results[svc] = "ok" if rc == 0 else f"error: {err or out}"
            log.info(f"Service {action} {svc} -> rc={rc}")
            if rc != 0 and svc not in optional_set:
                failures.append(svc)

        all_ok = len(failures) == 0
        self._ok({"success": all_ok, "results": results,
                  "failures": failures})

    # ── GET /api/streams ──────────────────────────────────────────────────────
    def _handle_get_streams(self):
        """Return active MediaMTX HLS paths via the MediaMTX v3 REST API."""
        import urllib.request as ureq, json as _json
        host_hdr  = self.headers.get("Host", "")
        server_ip = host_hdr.split(":")[0] if ":" in host_hdr else (host_hdr or "127.0.0.1")
        try:
            with ureq.urlopen("http://127.0.0.1:9997/v3/paths/list", timeout=2) as r:
                payload = _json.loads(r.read())
            streams = []
            for item in payload.get("items", []):
                if item.get("ready", False):
                    name = item["name"]
                    streams.append({
                        "path":    name,
                        "hls_url": f"http://{server_ip}:8888/{name}/index.m3u8",
                    })
            return self._ok({"streams": streams, "count": len(streams)})
        except Exception as exc:
            log.warning(f"/api/streams: MediaMTX API unavailable: {exc}")
            return self._ok({"streams": [], "count": 0})


    # ── GET /api/clips ────────────────────────────────────────────────────────
    def _handle_get_clips(self):
        clips = _load_clips()
        for c in clips:
            if "file" in c and not c.get("url"):
                c["url"] = f"/clips/{Path(c['file']).name}"
            if "thumbnail" in c and not c.get("thumb_url"):
                c["thumb_url"] = f"/clips/{Path(c['thumbnail']).name}"
        self._ok({"clips": clips, "count": len(clips)})

    # ── GET /api/clips/snapshots?id=xxx ──────────────────────────────────────
    def _handle_clip_snapshots(self, qs: dict):
        """Extract evenly-spaced PNG frames from a clip for the Snippets panel."""
        clip_id = (qs.get("id") or [""])[0].strip()
        if not clip_id:
            return self._err(400, "Missing ?id=")

        clips = _load_clips()
        clip  = next((c for c in clips if c.get("id") == clip_id), None)
        if not clip:
            return self._err(404, f"Clip '{clip_id}' not found")

        clip_file = Path(clip.get("file", ""))
        if not clip_file.exists():
            return self._err(404, f"Clip file missing: {clip_file.name}")

        duration = float(clip.get("duration", 60))
        n_frames = max(4, min(9, int(duration // 10)))  # 4–9 frames
        interval = duration / n_frames

        CLIPS_DIR.mkdir(parents=True, exist_ok=True)
        snapshots = []
        for i in range(n_frames):
            ts      = round(i * interval + interval / 2, 1)   # mid-point of each slice
            fname   = f"snap_{clip_id}_{i:02d}.png"
            out_png = CLIPS_DIR / fname

            if not out_png.exists():
                rc, _, err = _run(
                    str(FFMPEG_BIN), "-y",
                    "-ss", str(ts), "-i", str(clip_file),
                    "-vframes", "1", "-vf", "scale=640:-1",
                    "-f", "image2", str(out_png)
                )
                if rc != 0:
                    log.warning(f"Snapshot {fname} failed: {err[-100:]}")
                    continue

            def _fmt(s):
                m, sec = divmod(int(s), 60)
                return f"{m:02d}:{sec:02d}"

            snapshots.append({
                "index":      i,
                "time_s":     ts,
                "time_label": _fmt(ts),
                "url":        f"/clips/{fname}",
            })

        return self._ok({"clip_id": clip_id, "snapshots": snapshots, "count": len(snapshots)})


    # ── POST /api/clips/delete ────────────────────────────────────────────────
    def _handle_clip_delete(self, data: dict):
        clip_id = str(data.get("id", "")).strip()
        if not clip_id:
            return self._err(400, "Missing clip id")
        clips = _load_clips()
        to_delete = next((c for c in clips if c.get("id") == clip_id), None)
        if not to_delete:
            return self._err(404, f"Clip {clip_id} not found")
        # Delete files
        for fkey in ("file", "thumbnail"):
            p = Path(to_delete.get(fkey, ""))
            if p.exists():
                p.unlink(missing_ok=True)
        clips = [c for c in clips if c.get("id") != clip_id]
        _save_clips(clips)
        log.info(f"Deleted clip {clip_id}")
        self._ok({"success": True, "deleted": clip_id})

    # ── POST /api/clips/trigger ───────────────────────────────────────────────
    def _handle_clip_trigger(self, data: dict):
        rec_files = sorted(RECORDINGS_DIR.rglob("*.mp4"),
                           key=lambda f: f.stat().st_mtime, reverse=True) \
                    if RECORDINGS_DIR.exists() else []
        if not rec_files:
            return self._err(404, "No recording found — is MediaMTX recording enabled?")
        src      = str(rec_files[0])
        duration = int(data.get("duration", 90))
        label    = str(data.get("label", "manual")).strip()[:50]
        clip_id  = str(uuid.uuid4())[:8]

        threading.Thread(
            target=_extract_clip,
            args=(src, clip_id, duration, label),
            daemon=True
        ).start()
        log.info(f"Manual clip triggered: id={clip_id} src={src}")
        self._ok({"success": True, "clip_id": clip_id, "message": "Clip extraction started"})

    # ── GET /api/recordings ───────────────────────────────────────────────────
    def _handle_get_recordings(self):
        recs = []
        if RECORDINGS_DIR.exists():
            for f in sorted(RECORDINGS_DIR.rglob("*.mp4"),
                            key=lambda x: x.stat().st_mtime, reverse=True)[:50]:
                recs.append({
                    "name":     f.name,
                    "path":     str(f),
                    "size_mb":  round(f.stat().st_size / 1_048_576, 1),
                    "modified": int(f.stat().st_mtime),
                })
        self._ok({"recordings": recs, "count": len(recs)})

    # ── GET /api/metrics ─────────────────────────────────────────────────────
    def _handle_metrics(self):
        m = _get_metrics()
        stream = _get_stream_info()
        m.update(stream)
        self._ok(m)

    # ── GET /api/logs ─────────────────────────────────────────────────────────
    def _handle_logs(self, qs: dict):
        service = qs.get("service", ["mediamtx"])[0]
        lines   = min(int(qs.get("lines", ["100"])[0]), 500)
        log_file = LOG_MAP.get(service)
        if not log_file:
            return self._err(400, f"Unknown service '{service}'. Options: {list(LOG_MAP.keys())}")
        if not log_file.exists():
            return self._ok({"lines": [], "service": service, "note": "Log file not yet created"})
        try:
            all_lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
            tail = all_lines[-lines:]
            self._ok({"lines": tail, "service": service, "total_lines": len(all_lines)})
        except Exception as e:
            self._err(500, str(e))

    # ── Stream event hooks (called by MediaMTX runOnReady) ───────────────────
    def _handle_stream_event(self, event: str):
        log.info(f"Stream event received: {event}")
        self._ok({"event": event, "timestamp": int(time.time())})


# ── Update MediaMTX YT push ───────────────────────────────────────────────────
def _update_mediamtx_yt_push(yt_key: str):
    yml_path = BASE_DIR / "mediamtx" / "mediamtx.yml"
    if not yml_path.exists():
        return
    content = yml_path.read_text(encoding="utf-8")
    # Replace the commented runOnReady block with actual key
    import re
    new_run = (
        f"    runOnReady: >\n"
        f"      ffmpeg -re -i rtmp://127.0.0.1:1935/$MTX_PATH\n"
        f"      -c copy -f flv\n"
        f"      rtmp://a.rtmp.youtube.com/live2/{yt_key}\n"
        f"    runOnReadyRestart: yes\n"
    )
    # Remove old runOnReady block (commented or uncommented)
    content = re.sub(
        r"    #?runOnReady:.*?\n(?:    #.*?\n)*    #?runOnReadyRestart:.*?\n",
        new_run, content, flags=re.DOTALL
    )
    yml_path.write_text(content, encoding="utf-8")
    log.info(f"Updated mediamtx.yml YouTube key → restarting mediamtx")
    _win_service_control("restart", "mediamtx")


# ── Clip Extraction ───────────────────────────────────────────────────────────
def _extract_clip(src: str, clip_id: str, duration: int, label: str):
    try:
        CLIPS_DIR.mkdir(parents=True, exist_ok=True)
        out_mp4   = CLIPS_DIR / f"clip_{clip_id}.mp4"
        out_thumb = CLIPS_DIR / f"clip_{clip_id}.jpg"

        # Get recording duration
        rc, out, _ = _run("ffprobe", "-v", "error", "-show_entries",
                          "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", src)
        total_dur  = float(out) if rc == 0 and out.strip() else 0
        start_time = max(0, total_dur - duration) if total_dur > duration else 0

        rc, _, err = _run(
            "ffmpeg", "-y",
            "-ss", str(start_time),
            "-i", src,
            "-t", str(duration),
            "-c", "copy",
            "-movflags", "+faststart",
            str(out_mp4)
        )
        if rc != 0:
            log.error(f"FFmpeg clip extraction failed: {err}")
            return

        mid = duration // 2
        _run("ffmpeg", "-y",
             "-ss", str(mid),
             "-i", str(out_mp4),
             "-vframes", "1", "-q:v", "2",
             "-vf", "scale=640:-1",
             str(out_thumb))

        clips = _load_clips()
        clips.insert(0, {
            "id":        clip_id,
            "label":     label,
            "timestamp": int(time.time()),
            "duration":  duration,
            "file":      str(out_mp4),
            "thumbnail": str(out_thumb),
            "trigger":   "manual",
            "source":    src,
        })
        _save_clips(clips[:100])
        log.info(f"Clip saved: {out_mp4}")
    except Exception as e:
        log.error(f"Clip extraction error: {e}")

# ── Server Entry ──────────────────────────────────────────────────────────────
_START = time.time()

def run():
    # Ensure required directories exist
    for d in [CLIPS_DIR, RECORDINGS_DIR, HLS_DIR, LOG_DIR, BASE_DIR / "keys"]:
        d.mkdir(parents=True, exist_ok=True)

    server = ThreadingHTTPServer(("", PORT), APIHandler)
    log.info(f"StreamOps Management API  →  http://localhost:{PORT}")
    log.info(f"Dashboard                 →  http://localhost:{PORT}/")
    log.info(f"Public Viewer             →  http://localhost:{PORT}/watch")
    log.info(f"Token file                →  {TOKEN_FILE}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Server stopped.")

if __name__ == "__main__":
    run()
