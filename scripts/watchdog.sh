#!/usr/bin/env bash
# =============================================================================
# watchdog.sh — Process Watchdog for Nginx + FFmpeg Relay
# =============================================================================
# Monitors Nginx and the FFmpeg Facebook relay continuously.
# Restarts whichever process has died without affecting the other.
#
# Design principles:
#   - Checks every 30 seconds
#   - Restarts process immediately on failure
#   - Logs every restart event with a timestamp
#   - Maximum 5 consecutive restart attempts per process to avoid restart loops
#   - After max retries, waits 5 minutes before trying again (backoff)
#
# Usage:
#   Run via systemd (recommended): systemctl start watchdog
#   Or manually: nohup ./watchdog.sh &
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/.."
LOG_FILE="${BASE_DIR}/logs/watchdog.log"
KEYS_FILE="${BASE_DIR}/keys/stream_keys.env"

mkdir -p "${BASE_DIR}/logs"

# Poll interval in seconds
CHECK_INTERVAL=30

# Max consecutive restarts before entering backoff
MAX_RESTARTS=5

# Backoff wait in seconds (5 minutes)
BACKOFF_WAIT=300

nginx_restarts=0
fb_restarts=0
nginx_last_restart=0
fb_last_restart=0

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

log "INFO" "=== Watchdog started (PID $$) ==="
log "INFO" "Check interval: ${CHECK_INTERVAL}s | Max restarts: $MAX_RESTARTS | Backoff: ${BACKOFF_WAIT}s"

# -----------------------------------------------------------------------
nginx_is_running() {
    pgrep -x nginx > /dev/null 2>&1
}

fb_relay_is_running() {
    pgrep -f "fbsink/stream" > /dev/null 2>&1
}

restart_nginx() {
    log "WARN" "Nginx is DOWN. Attempting restart..."
    if systemctl is-enabled --quiet nginx-rtmp 2>/dev/null; then
        systemctl restart nginx-rtmp
    else
        nginx -c /etc/nginx/nginx.conf
    fi
    sleep 3
    if nginx_is_running; then
        log "INFO" "✓ Nginx restarted successfully."
        nginx_restarts=0
        return 0
    else
        log "ERROR" "✗ Nginx restart FAILED. Check: journalctl -u nginx-rtmp -n 20"
        return 1
    fi
}

restart_fb_relay() {
    log "WARN" "FFmpeg Facebook relay is DOWN. Attempting restart..."

    # Kill stale PID file
    if [[ -f /var/run/fb_relay.pid ]]; then
        OLD_PID=$(cat /var/run/fb_relay.pid)
        kill "$OLD_PID" 2>/dev/null || true
        rm -f /var/run/fb_relay.pid
    fi
    # Kill any stray ffmpeg processes
    pkill -f "fbsink/stream" 2>/dev/null || true
    sleep 1

    # Restart in background
    nohup bash "${SCRIPT_DIR}/fb_relay.sh" \
        >> "${BASE_DIR}/logs/ffmpeg/fb_relay.log" 2>&1 &
    NEW_PID=$!
    echo "$NEW_PID" > /var/run/fb_relay.pid

    sleep 3
    if fb_relay_is_running; then
        log "INFO" "✓ FFmpeg Facebook relay restarted (PID $NEW_PID)."
        fb_restarts=0
        return 0
    else
        log "ERROR" "✗ FFmpeg relay restart FAILED. Check: ${BASE_DIR}/logs/ffmpeg/fb_relay.log"
        return 1
    fi
}

in_backoff() {
    local restarts="$1"
    local last_restart="$2"
    local now
    now=$(date +%s)
    if [[ "$restarts" -ge "$MAX_RESTARTS" ]]; then
        local since=$(( now - last_restart ))
        if [[ "$since" -lt "$BACKOFF_WAIT" ]]; then
            local remaining=$(( BACKOFF_WAIT - since ))
            log "WARN" "Max restarts ($MAX_RESTARTS) reached. Backoff: ${remaining}s remaining."
            return 0
        else
            # Reset counter after backoff period expires
            return 1
        fi
    fi
    return 1
}

# -----------------------------------------------------------------------
# Main watchdog loop
# -----------------------------------------------------------------------
while true; do
    NOW=$(date +%s)

    # ── Check Nginx ──────────────────────────────────────────────────
    if ! nginx_is_running; then
        if ! in_backoff "$nginx_restarts" "$nginx_last_restart"; then
            ((nginx_restarts++)) || true
            nginx_last_restart=$NOW
            if restart_nginx; then
                :
            else
                log "ERROR" "Nginx restart attempt $nginx_restarts/$MAX_RESTARTS failed."
            fi
        fi
    else
        # Reset counter if running fine
        [[ "$nginx_restarts" -gt 0 ]] && nginx_restarts=0
    fi

    # ── Check FFmpeg Facebook relay ──────────────────────────────────
    if ! fb_relay_is_running; then
        # Only try to restart fb_relay if Nginx is already healthy
        if nginx_is_running; then
            if ! in_backoff "$fb_restarts" "$fb_last_restart"; then
                ((fb_restarts++)) || true
                fb_last_restart=$NOW
                if restart_fb_relay; then
                    :
                else
                    log "ERROR" "FFmpeg relay restart attempt $fb_restarts/$MAX_RESTARTS failed."
                fi
            fi
        else
            log "INFO" "Skipping FFmpeg restart — waiting for Nginx to recover first."
        fi
    else
        [[ "$fb_restarts" -gt 0 ]] && fb_restarts=0
    fi

    # ── Periodic status heartbeat (every 5 minutes) ──────────────────
    if (( NOW % 300 < CHECK_INTERVAL )); then
        NGINX_STATUS=$( nginx_is_running && echo "UP" || echo "DOWN" )
        FB_STATUS=$( fb_relay_is_running && echo "UP" || echo "DOWN" )
        log "INFO" "Heartbeat | nginx=$NGINX_STATUS | fb_relay=$FB_STATUS | nginx_restarts=$nginx_restarts | fb_restarts=$fb_restarts"
    fi

    sleep "$CHECK_INTERVAL"
done
