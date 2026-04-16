#!/usr/bin/env bash
# =============================================================================
# stop_relay.sh — Gracefully stop all relay processes
# =============================================================================
# Usage: sudo ./stop_relay.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo -e "\n${BLUE}══ Stopping Streaming Relay ══${NC}\n"

# Stop FFmpeg Facebook relay
if [[ -f /var/run/fb_relay.pid ]]; then
    FB_PID=$(cat /var/run/fb_relay.pid)
    if kill -0 "$FB_PID" 2>/dev/null; then
        log_info "Stopping FFmpeg Facebook relay (PID $FB_PID)..."
        kill -SIGTERM "$FB_PID" || true
        sleep 2
        # Force kill if still running
        if kill -0 "$FB_PID" 2>/dev/null; then
            log_warn "Force-killing FFmpeg relay..."
            kill -SIGKILL "$FB_PID" || true
        fi
        log_info "✓ FFmpeg relay stopped."
    else
        log_warn "fb_relay PID $FB_PID not found (already stopped)."
    fi
    rm -f /var/run/fb_relay.pid
else
    log_warn "No fb_relay.pid found. Killing all ffmpeg processes matching relay pattern..."
    pkill -f "fb_relay" || true
fi

# Kill any stray ffmpeg processes pulling from fbsink
pkill -f "fbsink/stream" 2>/dev/null || true

# Stop Nginx
if systemctl is-active --quiet nginx-rtmp 2>/dev/null; then
    log_info "Stopping Nginx RTMP service..."
    systemctl stop nginx-rtmp
    log_info "✓ Nginx stopped."
elif pgrep -x nginx > /dev/null; then
    log_warn "nginx-rtmp systemd unit not found. Sending QUIT to nginx..."
    nginx -s quit
    log_info "✓ Nginx graceful quit sent."
else
    log_warn "Nginx is not running."
fi

# Stop watchdog if it's running as a service
if systemctl is-active --quiet watchdog 2>/dev/null; then
    log_info "Stopping watchdog service..."
    systemctl stop watchdog
fi

echo ""
log_info "All relay processes stopped."
log_info "Stream to OBS has been terminated."
echo ""
