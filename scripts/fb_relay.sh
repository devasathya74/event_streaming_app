#!/usr/bin/env bash
# =============================================================================
# fb_relay.sh — FFmpeg Facebook RTMPS Relay
# =============================================================================
# Purpose:
#   Pulls the live stream from the local Nginx fbsink application and
#   re-pushes it to Facebook Live over RTMPS (TLS).
#
# Why FFmpeg?
#   Facebook Live has required RTMPS since 2019. The nginx-rtmp-module's
#   push directive does not support RTMPS. FFmpeg handles TLS natively.
#
# How it works:
#   1. Nginx relays OBS stream to rtmp://127.0.0.1:1935/fbsink/stream
#   2. This script pulls from that local RTMP sink
#   3. FFmpeg re-muxes (NO re-encoding — stream copy) and pushes to Facebook
#
# Usage:
#   chmod +x fb_relay.sh
#   ./fb_relay.sh
#   (Normally started by systemd or watchdog, not directly)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${SCRIPT_DIR}/../keys/stream_keys.env"
LOG_DIR="${SCRIPT_DIR}/../logs/ffmpeg"
LOG_FILE="${LOG_DIR}/fb_relay.log"
PID_FILE="/var/run/fb_relay.pid"

# Load stream keys from secure env file
if [[ ! -f "$KEYS_FILE" ]]; then
    echo "[ERROR] Keys file not found: $KEYS_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$KEYS_FILE"

mkdir -p "$LOG_DIR"

# Validate required variables
if [[ "${FB_STREAM_KEY}" == *"YOUR_FACEBOOK"* ]] || [[ -z "${FB_STREAM_KEY}" ]]; then
    echo "[NOTICE] FB_STREAM_KEY is not set. Relay to Facebook is disabled until key is provided."
    echo "[NOTICE] Update keys via Dashboard or in keys/stream_keys.env"
    # Sleep to prevent systemd rapid-restart log spam
    sleep 3600
    exit 0
fi

FACEBOOK_RTMPS_INGEST="${FB_RTMPS_URL}${FB_STREAM_KEY}"
SOURCE_URL="rtmp://127.0.0.1:1985/live/stream"

echo "[INFO] Starting Facebook RTMPS relay at $(date '+%Y-%m-%d %H:%M:%S')"
echo "[INFO] Source : $SOURCE_URL"
echo "[INFO] Destination: ${FB_RTMPS_URL}/[FB_STREAM_KEY_REDACTED]"
echo "[INFO] Log: $LOG_FILE"

# Save PID for watchdog
echo $$ > "$PID_FILE"

# =============================================================================
# FFmpeg relay command explanation:
#
#   -re               Read input at native frame rate (prevents buffering buildup)
#   -i $SOURCE_URL    Pull from local Nginx RTMP fbsink
#   -c copy           Stream copy — no re-encoding, zero CPU transcoding cost
#   -f flv            Output format for RTMP/RTMPS
#   -flvflags no_duration_filesize
#                     Prevents FLV metadata fields that cause issues on live streams
#   -reconnect 1      Reconnect to input if connection drops
#   -reconnect_at_eof 1   Reconnect at end of stream
#   -reconnect_streamed 1  Reconnect on streamed inputs
#   -reconnect_delay_max 30  Max wait before reconnect (seconds)
#   -timeout 10000000 Input timeout in microseconds (10 seconds)
# =============================================================================

exec ffmpeg \
    -loglevel warning \
    -reconnect 1 \
    -reconnect_at_eof 1 \
    -reconnect_streamed 1 \
    -reconnect_delay_max 30 \
    -timeout 10000000 \
    -i "$SOURCE_URL" \
    -c copy \
    -f flv \
    -flvflags no_duration_filesize \
    "${FACEBOOK_RTMPS_INGEST}" \
    2>&1 | tee -a "$LOG_FILE"
