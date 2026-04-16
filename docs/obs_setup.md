# OBS Studio Setup Guide

## OBS Version Requirement

Use **OBS Studio 28.0 or later**. Older versions have known issues with RTMP reconnection handling.

---

## Connection Settings

In OBS, go to **Settings → Stream**:

| Setting | Value |
|---|---|
| Service | **Custom...** |
| Server | `rtmp://[SERVER_IP]:1935/live` |
| Stream Key | `stream` |
| Use authentication | Leave unchecked |

Replace `[SERVER_IP]` with:
- **Local laptop setup**: `127.0.0.1` (if OBS runs on the same machine as Nginx)
- **Local laptop setup (different machines on LAN)**: The LAN IP of the relay machine, e.g. `192.168.1.50`
- **VPS setup**: The public IP of your VPS, e.g. `142.93.XX.XX`

**Full example (VPS):**
```
Server:     rtmp://142.93.45.67:1935/live
Stream Key: stream
```

---

## Recommended OBS Output Settings

Go to **Settings → Output → Output Mode: Advanced**

### Streaming Tab

| Setting | Recommended Value | Notes |
|---|---|---|
| Encoder | `x264` | Software encoder — consistent quality |
| Rate Control | `CBR` | Constant Bitrate — more stable for RTMP |
| Bitrate | `2800 kbps` | In the 2500–3000 range; middle is safest |
| Keyframe Interval | `2` | 2 seconds — required by YouTube & Facebook |
| CPU Usage Preset | `veryfast` | Best balance of quality vs CPU use |
| Profile | `high` | Better compression than `main` |
| Tune | `zerolatency` | Reduces encoder latency by ~1s |
| B-frames | `0` | Leave at 0 for RTMP compatibility |

> **Why CBR?** YouTube and Facebook ingest servers expect a constant bitrate stream. VBR can cause buffering on their end, especially during motion-heavy scenes.

> **Why `veryfast`?** On a mid-range laptop, `veryfast` keeps CPU below ~40%. Slower presets improve quality but can cause frame drops if CPU is maxed.

### Video Settings

Go to **Settings → Video**:

| Setting | Value |
|---|---|
| Base (Canvas) Resolution | `1280x720` |
| Output (Scaled) Resolution | `1280x720` |
| Common FPS Values | `30` |
| Downscale Filter | `Lanczos` |

### Audio Settings

Go to **Settings → Audio** (and **Settings → Output → Audio**):

| Setting | Value |
|---|---|
| Sample Rate | `44100 Hz` |
| Channels | `Stereo` |
| Audio Bitrate | `128 kbps` |
| Encoder | `AAC` |

> Higher audio bitrates (192/320) waste bandwidth without meaningful quality gain for event streaming.

---

## Advanced Reconnect Settings

Go to **Settings → Stream → Advanced Settings (Show More)**:

| Setting | Value |
|---|---|
| Automatically reconnect | ✅ Enabled |
| Retry Delay | `10` seconds |
| Maximum Retries | `20` |
| Disconnect when done | ✅ Enabled |

This ensures OBS automatically re-connects to your relay server if the connection drops briefly during the event.

---

## Multi-Output Add-On (Optional but Useful)

If you want to monitor OBS output quality directly and add fallback encoders, install **OBS Multiple Output** plugin. However, **do not** use it to push directly to YouTube and Facebook — that defeats the purpose of having a relay server that you control.

---

## Pre-Event Stream Test Procedure

### 1. Start the relay server
```bash
sudo bash /opt/streaming-backend/scripts/start_relay.sh
```

### 2. Create test stream events on YouTube and Facebook

- **YouTube**: Go to YouTube Studio → Go Live → Schedule a stream (set as Unlisted)
- **Facebook**: Go to Facebook → Professional Dashboard → Live Video → Use Stream Key → do not broadcast publicly

### 3. Start streaming from OBS

Click **Start Streaming** in OBS.

Wait 10 seconds, then verify:

```bash
# On the relay server:
bash /opt/streaming-backend/scripts/health_check.sh
```

### 4. Check the Nginx stat page

```bash
# From the relay server (or via SSH tunnel)
curl http://127.0.0.1:8080/stat
```

Look for:
```xml
<application>
  <name>live</name>
  <live>
    <nclients>3</nclients>   ← 1 OBS input + 2 pushes (YouTube + FB sink)
    <stream>
      <name>stream</name>
      <bw_video>2800000</bw_video>   ← bytes per sec, ~2800 kbps
    </stream>
  </live>
</application>
```

### 5. Verify video on YouTube and Facebook

- Open your YouTube Live stream page and confirm video appears
- Open your Facebook Live preview and confirm video appears
- Check for audio sync — clap once loudly in frame and verify the clap matches lip movement

### 6. Test reconnect behavior

Stop OBS streaming and wait 30 seconds. Restart OBS streaming. Verify:
- YouTube and Facebook streams resume
- Watchdog log shows no errors
- Health check still passes

### 7. Stop test streams

- Stop OBS
- End the test streams on YouTube and Facebook dashboards

---

## Verifying Relay is Receiving and Forwarding Correctly

### Method 1: Nginx Stat Page (Simplest)

```bash
curl -s http://127.0.0.1:8080/stat | grep -A5 "<name>live</name>"
```

If `nclients > 0` and `bw_video > 0`, OBS is connected and sending video.

### Method 2: Watch Error Logs in Real Time

```bash
# Terminal 1 — Nginx errors
sudo tail -f /var/log/nginx/error.log

# Terminal 2 — FFmpeg Facebook relay
tail -f /opt/streaming-backend/logs/ffmpeg/fb_relay.log

# Terminal 3 — Watchdog
tail -f /opt/streaming-backend/logs/watchdog.log
```

### Method 3: FFmpeg Probe (Advanced)

```bash
# Pull one frame from the local RTMP stream to confirm video is flowing
ffprobe -v quiet -print_format json -show_streams \
    rtmp://127.0.0.1:1935/live/stream 2>&1 | head -40
```

Expected output: Shows `codec_type: video`, `width: 1280`, `height: 720`, `r_frame_rate: 30/1`

---

## Common OBS Problems and Fixes

| Problem | Cause | Fix |
|---|---|---|
| "Failed to connect to server" | Wrong IP or port blocked | Run `check_ports.sh`, verify firewall |
| Stream connects but drops every few seconds | Nginx not running | Run `health_check.sh`, check nginx status |
| Facebook stream is black | FFmpeg relay not running | Check `fb-relay` systemd status |
| High dropped frames in OBS | CPU too high or network congestion | Lower preset to `ultrafast`, reduce bitrate to 2000 kbps temporarily |
| Audio desync on platforms | Wrong sample rate | Use 44100 Hz, not 48000 in OBS audio settings |
| Stream key rejected by YouTube | Wrong keyframe interval | Set keyframe interval to exactly `2` seconds |
