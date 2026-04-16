#!/usr/bin/env bash
# =============================================================================
# start_relay.sh — Start the complete live streaming relay stack
# =============================================================================
# Starts:
#   1. Nginx RTMP relay (YouTube direct push + Facebook local sink)
#   2. FFmpeg Facebook RTMPS relay subprocess
#
# Prerequisites:
#   - nginx with rtmp module installed
#   - ffmpeg installed (>= 4.0)
#   - stream_keys.env populated with real keys
#   - configs deployed to /etc/nginx/
#
# Usage:
#   sudo ./start_relay.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/.."
LOG_DIR="${BASE_DIR}/logs"
NGINX_LOG_DIR="${LOG_DIR}/nginx"
FB_LOG_DIR="${LOG_DIR}/ffmpeg"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# -----------------------------------------------------------------------
log_section "Streaming Relay — Startup"
# -----------------------------------------------------------------------

# Ensure we are root (Nginx needs port 1935 binding)
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

# Create log directories
mkdir -p "$NGINX_LOG_DIR" "$FB_LOG_DIR" "${LOG_DIR}/rtmp"
log_info "Log directories ready at $LOG_DIR"

# -----------------------------------------------------------------------
# Step 1: Validate nginx config
# -----------------------------------------------------------------------
log_section "Validating Nginx Config"

if ! nginx -t 2>&1; then
    log_error "Nginx config validation failed. Fix errors before starting."
    exit 1
fi
log_info "Nginx config is valid."

# -----------------------------------------------------------------------
# Step 2: Start or reload Nginx
# -----------------------------------------------------------------------
log_section "Starting Nginx RTMP Relay"

if systemctl is-active --quiet nginx-rtmp 2>/dev/null; then
    log_info "Nginx already running — reloading config..."
    systemctl reload nginx-rtmp
else
    log_info "Starting Nginx service..."
    systemctl start nginx-rtmp
fi

sleep 2

if systemctl is-active --quiet nginx-rtmp 2>/dev/null || pgrep -x nginx > /dev/null; then
    log_info "✓ Nginx is running."
else
    log_error "✗ Nginx failed to start. Check: journalctl -u nginx-rtmp -n 50"
    exit 1
fi

# -----------------------------------------------------------------------
# Step 3: Start FFmpeg Facebook relay
# -----------------------------------------------------------------------
log_section "Starting Facebook RTMPS Relay (FFmpeg)"

# Stop any existing fb_relay instance
if [[ -f /var/run/fb_relay.pid ]]; then
    OLD_PID=$(cat /var/run/fb_relay.pid)
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log_warn "Stopping existing fb_relay (PID $OLD_PID)..."
        kill "$OLD_PID" || true
        sleep 1
    fi
    rm -f /var/run/fb_relay.pid
fi

# Start fb_relay.sh as a background daemon
nohup bash "${SCRIPT_DIR}/fb_relay.sh" > "${FB_LOG_DIR}/fb_relay.log" 2>&1 &
FB_PID=$!
echo $FB_PID > /var/run/fb_relay.pid
log_info "✓ FFmpeg Facebook relay started (PID $FB_PID)"

# -----------------------------------------------------------------------
# Step 4: Verify ports are listening
# -----------------------------------------------------------------------
log_section "Port Verification"

sleep 2

check_port() {
    local port=$1
    local desc=$2
    if ss -tlnp | grep -q ":${port} "; then
        log_info "✓ Port $port ($desc) is open and listening."
    else
        log_warn "✗ Port $port ($desc) is NOT listening yet. Check service logs."
    fi
}

check_port 1935 "RTMP ingress"
check_port 8080 "HTTP stat/health"

# -----------------------------------------------------------------------
# Step 5: Summary
# -----------------------------------------------------------------------
log_section "Startup Complete"

echo ""
log_info "OBS Connection URL : rtmp://$(hostname -I | awk '{print $1}'):1935/live/stream"
log_info "Stream Key in OBS  : stream"
log_info "Nginx RTMP Stats   : http://127.0.0.1:8080/stat"
log_info "Health endpoint    : http://127.0.0.1:8080/health"
log_info "FB Relay log       : ${FB_LOG_DIR}/fb_relay.log"
log_info "Nginx error log    : /var/log/nginx/error.log"
echo ""
log_warn "OBS is NOT yet streaming. Start OBS and push to the URL above."
log_info "Run 'bash ${SCRIPT_DIR}/health_check.sh' after OBS starts to verify relay."
echo ""
