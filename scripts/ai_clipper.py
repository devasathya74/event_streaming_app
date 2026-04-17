#!/usr/bin/env python3
# =============================================================================
# ai_clipper.py — AI-Powered Highlight Clip Detector (Windows Edition)
# =============================================================================
# Zero ML dependencies — pure FFmpeg analysis.
#
# What it does:
#   1. Watches C:\streaming-backend\recordings\ for MP4 files (MediaMTX records)
#   2. Every 30 seconds analyzes the last 3 minutes:
#      a. FFmpeg volumedetect  → audio energy (dBFS)
#      b. FFmpeg scene filter  → scene cuts / minute
#      c. FFmpeg mestimate     → motion vector energy (NEW: great for parades)
#   3. Combined confidence score (0–100) triggers automatic clips
#   4. Accepts manual triggers via C:\streaming-backend\tmp\clip_trigger.flag
# =============================================================================

import os, re, json, time, uuid, logging, subprocess, threading
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────
BASE_DIR       = Path(os.environ.get("STREAMING_BASE",   r"C:\streaming-backend"))
RECORDINGS_DIR = Path(os.environ.get("RECORDINGS_DIR",  r"C:\streaming-backend\recordings"))
CLIPS_DIR      = Path(os.environ.get("CLIPS_DIR",       r"C:\streaming-backend\www\clips"))
CLIPS_INDEX    = BASE_DIR / "clips" / "index.json"
LOG_FILE       = BASE_DIR / "logs"  / "clipper.log"
TRIGGER_FLAG   = BASE_DIR / "tmp"   / "clip_trigger.flag"

POLL_INTERVAL  = 30          # seconds between analysis passes
CLIP_DURATION  = 90          # seconds per auto clip
LOOKBACK_TIME  = 180         # seconds of recording to analyze

AUDIO_THRESHOLD = float(os.environ.get("CLIP_AUDIO_THRESHOLD", "-14.0"))  # dBFS
SCENE_THRESHOLD = float(os.environ.get("CLIP_SCENE_THRESHOLD", "8.0"))    # cuts/min
MOTION_THRESHOLD= float(os.environ.get("CLIP_MOTION_THRESHOLD","2000.0")) # SAD units
CLIP_COOLDOWN   = 120        # seconds between auto clips (prevents flooding)

# FFmpeg null device (NUL on Windows, /dev/null on Linux)
NULL_DEV = "NUL" if os.name == "nt" else "/dev/null"

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [AI-CLIPPER] %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(str(LOG_FILE), encoding="utf-8"),
        logging.StreamHandler(),
    ]
)
log = logging.getLogger("ai-clipper")

# ── FFmpeg Helpers ─────────────────────────────────────────────────────────────
def _run_ff(*args, timeout=60) -> tuple[int, str, str]:
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    try:
        r = subprocess.run(
            list(args),
            capture_output=True, text=True,
            timeout=timeout,
            creationflags=flags
        )
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except FileNotFoundError:
        return -1, "", "ffmpeg not found — install from https://ffmpeg.org/download.html"

# ── Analysis Functions ────────────────────────────────────────────────────────
def analyze_audio_peak(src: str, start_ss: float, duration: float) -> float:
    """
    Run FFmpeg volumedetect. Returns max dBFS (e.g. -10.5). 
    High values = crowd noise, cheering, announcements.
    """
    rc, _, stderr = _run_ff(
        "ffmpeg", "-y",
        "-ss", str(start_ss), "-i", src,
        "-t", str(duration),
        "-af", "volumedetect", "-vn",
        "-f", "null", NULL_DEV
    )
    m = re.search(r"max_volume:\s*([-\d.]+)\s*dBFS", stderr)
    return float(m.group(1)) if m else -60.0


def analyze_scene_cuts(src: str, start_ss: float, duration: float) -> int:
    """
    Count scene cuts using FFmpeg select=gt(scene,0.4).
    High value = camera switching, action montage.
    """
    rc, stdout, stderr = _run_ff(
        "ffmpeg", "-y",
        "-ss", str(start_ss), "-i", src,
        "-t", str(duration),
        "-vf", r"select=gt(scene\,0.4),metadata=print:file=-",
        "-an", "-f", "null", NULL_DEV
    )
    cuts = len(re.findall(r"lavfi\.scene_score", stdout + stderr))
    return cuts


def analyze_motion_energy(src: str, start_ss: float, duration: float) -> float:
    """
    Motion vector energy via FFmpeg mestimate filter.
    Returns average SAD (Sum of Absolute Differences) across frames.
    High value = significant movement — parades, crowd surges, formations.
    
    Filter: mestimate=method=ds,metadata=print:file=-
    """
    rc, stdout, stderr = _run_ff(
        "ffmpeg", "-y",
        "-ss", str(start_ss), "-i", src,
        "-t", str(duration),
        "-vf", r"mestimate=method=ds,metadata=print:file=-",
        "-an", "-f", "null", NULL_DEV,
        timeout=90
    )
    sad_values = re.findall(r"lavfi\.me\.sad=([\d.]+)", stdout + stderr)
    if not sad_values:
        return 0.0
    return sum(float(v) for v in sad_values) / len(sad_values)


def get_recording_duration(src: str) -> float:
    rc, out, _ = _run_ff(
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        src
    )
    try:
        return float(out.strip()) if rc == 0 else 0.0
    except ValueError:
        return 0.0


def compute_confidence(audio_db: float, scene_cuts_pm: float, motion_sad: float) -> float:
    """
    Combined confidence score 0–100 from three signals.
    Each signal: 0 = below threshold, 100 = well above threshold.
    Weights: audio 40%, scene 30%, motion 30%.
    """
    def normalize(val, threshold, max_val):
        if val <= threshold:
            return 0.0
        return min(100.0, (val - threshold) / (max_val - threshold) * 100.0)

    audio_conf  = normalize(audio_db,       AUDIO_THRESHOLD,  0.0)        # dBFS (higher=louder)
    scene_conf  = normalize(scene_cuts_pm,  SCENE_THRESHOLD,  SCENE_THRESHOLD * 3)
    motion_conf = normalize(motion_sad,     MOTION_THRESHOLD, MOTION_THRESHOLD * 5)

    return round(0.40 * audio_conf + 0.30 * scene_conf + 0.30 * motion_conf, 1)


# ── Clip Extraction ───────────────────────────────────────────────────────────
def extract_clip(src: str, clip_id: str, duration: int,
                 trigger: str, label: str = "", confidence: float = 0.0) -> bool:
    try:
        CLIPS_DIR.mkdir(parents=True, exist_ok=True)
        out_mp4   = CLIPS_DIR / f"clip_{clip_id}.mp4"
        out_thumb = CLIPS_DIR / f"clip_{clip_id}.jpg"

        total_dur  = get_recording_duration(src)
        start_time = max(0.0, total_dur - duration)

        log.info(f"Extracting clip {clip_id}: [{start_time:.0f}s → +{duration}s] from {Path(src).name}")

        rc, _, err = _run_ff(
            "ffmpeg", "-y",
            "-ss",  str(start_time), "-i", src,
            "-t",   str(duration),
            # Explicit H.264 + AAC → guaranteed VLC / browser compatible
            "-c:v", "libx264", "-preset", "fast", "-crf", "18",
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",   # enable progressive download
            str(out_mp4),
            timeout=180
        )
        if rc != 0:
            log.error(f"FFmpeg clip failed: {err[-200:]}")
            return False

        # Thumbnail at midpoint
        mid = duration // 2
        _run_ff(
            "ffmpeg", "-y",
            "-ss", str(mid), "-i", str(out_mp4),
            "-vframes", "1", "-q:v", "2", "-vf", "scale=640:-1",
            str(out_thumb), timeout=30
        )

        _append_clip({
            "id":         clip_id,
            "label":      label or trigger,
            "timestamp":  int(time.time()),
            "duration":   duration,
            "file":       str(out_mp4),
            "thumbnail":  str(out_thumb),
            "trigger":    trigger,
            "source":     str(src),
            "confidence": confidence,
        })

        log.info(f"✅  Clip saved: {out_mp4}  (confidence={confidence})")
        return True

    except Exception as e:
        log.error(f"Clip extraction exception: {e}")
        return False


_clips_lock = threading.Lock()

def _append_clip(meta: dict):
    with _clips_lock:
        clips = []
        if CLIPS_INDEX.exists():
            try:
                clips = json.loads(CLIPS_INDEX.read_text(encoding="utf-8"))
            except Exception:
                clips = []
        clips.insert(0, meta)
        clips = clips[:200]
        CLIPS_INDEX.parent.mkdir(parents=True, exist_ok=True)
        CLIPS_INDEX.write_text(json.dumps(clips, indent=2), encoding="utf-8")


# ── Recording Discovery ───────────────────────────────────────────────────────
def get_latest_recording() -> Path | None:
    if not RECORDINGS_DIR.exists():
        return None
    # MediaMTX writes mp4 files
    mp4s = sorted(RECORDINGS_DIR.rglob("*.mp4"),
                  key=lambda f: f.stat().st_mtime, reverse=True)
    return mp4s[0] if mp4s else None


def check_trigger_flag() -> dict | None:
    if not TRIGGER_FLAG.exists():
        return None
    try:
        data = json.loads(TRIGGER_FLAG.read_text(encoding="utf-8"))
        TRIGGER_FLAG.unlink()
        return data
    except Exception:
        TRIGGER_FLAG.unlink(missing_ok=True)
        return None


# ── Main Loop ─────────────────────────────────────────────────────────────────
def main():
    log.info("=" * 60)
    log.info("StreamOps AI Highlight Clipper (Windows Edition)")
    log.info(f"  Recordings : {RECORDINGS_DIR}")
    log.info(f"  Clips out  : {CLIPS_DIR}")
    log.info(f"  Audio thr  : >{AUDIO_THRESHOLD} dBFS")
    log.info(f"  Scene thr  : >{SCENE_THRESHOLD} cuts/min")
    log.info(f"  Motion thr : >{MOTION_THRESHOLD} SAD units")
    log.info("=" * 60)

    (BASE_DIR / "tmp").mkdir(parents=True, exist_ok=True)

    last_clip_time = 0.0
    pass_count = 0

    while True:
        try:
            # ── Manual trigger check ──────────────────────────────────────
            trigger_data = check_trigger_flag()
            if trigger_data:
                src = get_latest_recording()
                if src:
                    clip_id = trigger_data.get("clip_id", str(uuid.uuid4())[:8])
                    dur     = int(trigger_data.get("duration", CLIP_DURATION))
                    lbl     = trigger_data.get("label", "manual")
                    log.info(f"Manual trigger: id={clip_id}")
                    threading.Thread(
                        target=extract_clip,
                        args=(str(src), clip_id, dur, "manual", lbl, 100.0),
                        daemon=True
                    ).start()
                else:
                    log.warning("Manual trigger received but no recording found")

            # ── AI analysis pass ──────────────────────────────────────────
            src = get_latest_recording()
            if src is None:
                if pass_count % 10 == 0:
                    log.info("No recording — waiting for stream to start...")
                time.sleep(POLL_INTERVAL)
                pass_count += 1
                continue

            total_dur = get_recording_duration(str(src))
            if total_dur < 10:
                time.sleep(POLL_INTERVAL)
                pass_count += 1
                continue

            analyze_start = max(0.0, total_dur - LOOKBACK_TIME)
            analyze_dur   = min(LOOKBACK_TIME, total_dur)

            pass_count += 1
            log.info(f"Pass #{pass_count} | {src.name} | {total_dur:.0f}s total | analyzing last {analyze_dur:.0f}s")

            # Run all three analyses
            peak_db      = analyze_audio_peak(str(src), analyze_start, analyze_dur)
            scene_cuts   = analyze_scene_cuts(str(src), analyze_start, analyze_dur)
            motion_sad   = analyze_motion_energy(str(src), analyze_start, analyze_dur)

            cuts_per_min = (scene_cuts / analyze_dur) * 60 if analyze_dur > 0 else 0
            confidence   = compute_confidence(peak_db, cuts_per_min, motion_sad)

            log.info(f"  Audio : {peak_db:.1f} dBFS   (thr {AUDIO_THRESHOLD})")
            log.info(f"  Scene : {cuts_per_min:.1f}/min  (thr {SCENE_THRESHOLD})")
            log.info(f"  Motion: {motion_sad:.0f} SAD   (thr {MOTION_THRESHOLD})")
            log.info(f"  Score : {confidence}/100")

            audio_trig  = peak_db      > AUDIO_THRESHOLD
            scene_trig  = cuts_per_min > SCENE_THRESHOLD
            motion_trig = motion_sad   > MOTION_THRESHOLD
            cooldown_ok = (time.time() - last_clip_time) > CLIP_COOLDOWN

            if (audio_trig or scene_trig or motion_trig) and cooldown_ok:
                reasons = []
                if audio_trig:  reasons.append(f"audio={peak_db:.1f}dBFS")
                if scene_trig:  reasons.append(f"scene={cuts_per_min:.1f}/min")
                if motion_trig: reasons.append(f"motion={motion_sad:.0f}")

                clip_id = str(uuid.uuid4())[:8]
                reason  = "+".join(reasons)
                log.info(f"🎬 HIGHLIGHT DETECTED! {reason} → clip {clip_id}")

                last_clip_time = time.time()
                threading.Thread(
                    target=extract_clip,
                    args=(str(src), clip_id, CLIP_DURATION, "auto", reason, confidence),
                    daemon=True
                ).start()

            elif not cooldown_ok:
                rem = int(CLIP_COOLDOWN - (time.time() - last_clip_time))
                log.info(f"  Cooldown: {rem}s remaining — skipping")
            else:
                log.info("  No highlight detected.")

        except KeyboardInterrupt:
            log.info("AI Clipper stopped.")
            break
        except Exception as e:
            log.error(f"Main loop error: {e}", exc_info=True)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
