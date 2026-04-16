# Live Streaming Backend — Architecture Overview

## System Pipeline

```
OBS Studio (Encoder)
        │
        │  RTMP Push (rtmp://[SERVER_IP]:1935/live/stream)
        ▼
┌─────────────────────────────────────────────┐
│         Nginx RTMP Relay Server             │
│                                             │
│  ┌──────────────────────────────────────┐   │
│  │  nginx-rtmp-module                   │   │
│  │  Application: "live"                 │   │
│  │  Stream Key: "stream"                │   │
│  └────────────────┬─────────────────────┘   │
│                   │                         │
│        ┌──────────┴──────────┐              │
│        │  push directive     │              │
│        ▼                     ▼              │
│  Push to YouTube      Push to Facebook      │
└─────────────────────────────────────────────┘
        │                       │
        ▼                       ▼
  YouTube Live            Facebook Live
  (rtmp://a.rtmp.         (rtmps://live-api-s.
   youtube.com/live2/     facebook.com:443/
   [YT_STREAM_KEY])       rtmp/[FB_STREAM_KEY])
```

## Component Roles

| Component | Role |
|---|---|
| OBS Studio | Captures, encodes, and pushes RTMP to relay |
| Nginx + nginx-rtmp-module | Receives stream, pushes to multiple destinations |
| FFmpeg (fallback) | Re-encodes/re-pushes if Nginx push fails |
| Watchdog script | Monitors Nginx and FFmpeg, auto-restarts on failure |
| systemd services | Process supervision, auto-start on boot |
| Health check script | Verifies input stream is alive, ports are open |

## Why This Design

- **No transcoding on relay**: Nginx RTMP passes the stream through without re-encoding (copy mode), keeping CPU usage minimal
- **FFmpeg fallback**: Used only when Nginx push to a destination fails (e.g., Facebook requires RTMPS which some Nginx builds do not support natively)
- **Single ingress point**: OBS connects only once, reducing upstream bandwidth waste
- **No paid services**: Everything runs on open-source software on hardware you control

## Data Flow Detail

1. OBS encodes at 720p/30fps/2500–3000 kbps using x264
2. OBS pushes RTMP to your server on port 1935
3. Nginx receives the stream in the `live` application
4. Nginx simultaneously pushes to YouTube (RTMP) and Facebook (RTMPS via FFmpeg)
5. Watchdog monitors all processes every 30 seconds
6. If a push fails, the watchdog restarts only the failed component

## RTMPS Note (Facebook)

Facebook Live has required RTMPS (RTMP over TLS) since 2019. Standard Nginx RTMP builds **do not support RTMPS push natively**. Two solutions exist:

- **Option 1 (Recommended)**: Use FFmpeg as the Facebook relay subprocess (supports RTMPS natively)
- **Option 2**: Use stunnel to wrap Nginx's RTMP push in TLS before sending to Facebook

This guide uses **Option 1** (FFmpeg for Facebook) because it is simpler, more reliable, and requires no additional TLS tunnel setup.

## Port Map

| Port | Protocol | Purpose |
|---|---|---|
| 1935 | TCP | RTMP ingress from OBS |
| 8080 | TCP | Nginx RTMP stat HTTP page |
| 22 | TCP | SSH management (restrict by IP) |
