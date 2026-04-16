#!/usr/bin/env bash
# =============================================================================
# health_check.sh — Stream and Process Health Verification
# =============================================================================
# Run this:
#   - After starting the relay, before going live
#   - Periodically during a live event to confirm all outputs are active
#   - After any network interruption
#
# Usage: ./health_check.sh [--json]
#   --json  Output results in JSON format for scripted monitoring
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${SCRIPT_DIR}/../keys/stream_keys.env"

JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

PASS=0; WARN=0; FAIL=0
declare -A RESULTS

check_pass() { echo -e "${GREEN}  ✓${NC} $*"; RESULTS["$1"]="PASS"; ((PASS++)); }
check_warn() { echo -e "${YELLOW}  ⚠${NC} $*"; RESULTS["$1"]="WARN"; ((WARN++)); }
check_fail() { echo -e "${RED}  ✗${NC} $*"; RESULTS["$1"]="FAIL"; ((FAIL++)); }

header() { echo -e "\n${BLUE}── $* ──${NC}"; }

# Load keys for URL checks
[[ -f "$KEYS_FILE" ]] && source "$KEYS_FILE" || true

# =============================================================================
echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Live Stream Health Check               ║${NC}"
echo -e "${CYAN}║   $(date '+%Y-%m-%d %H:%M:%S')                    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"

# -----------------------------------------------------------------------
header "Process Status"
# -----------------------------------------------------------------------

# Nginx
if pgrep -x nginx > /dev/null 2>&1; then
    NGINX_PID=$(pgrep -x nginx | head -1)
    check_pass "nginx_process" "Nginx is running (PID $NGINX_PID)"
else
    check_fail "nginx_process" "Nginx is NOT running"
fi

# FFmpeg Facebook relay
if pgrep -f "fbsink/stream" > /dev/null 2>&1; then
    FB_PID=$(pgrep -f "fbsink/stream" | head -1)
    check_pass "ffmpeg_fb_process" "FFmpeg Facebook relay is running (PID $FB_PID)"
else
    check_fail "ffmpeg_fb_process" "FFmpeg Facebook relay is NOT running"
fi

# Watchdog
if pgrep -f "watchdog.sh" > /dev/null 2>&1; then
    check_pass "watchdog_process" "Watchdog script is running"
else
    check_warn "watchdog_process" "Watchdog script not detected (OK if using systemd timer)"
fi

# -----------------------------------------------------------------------
header "Port Availability"
# -----------------------------------------------------------------------

check_port_listening() {
    local port=$1 desc=$2 key=$3
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        check_pass "$key" "Port $port ($desc) is listening"
        return 0
    else
        check_fail "$key" "Port $port ($desc) is NOT listening"
        return 1
    fi
}

check_port_listening 1935 "RTMP ingress"   "port_1935"
check_port_listening 8080 "HTTP stat page" "port_8080"

# -----------------------------------------------------------------------
header "Active Stream Detection"
# -----------------------------------------------------------------------

# Check Nginx RTMP stat page for active streams
STAT_URL="http://127.0.0.1:8080/stat"

if command -v curl &>/dev/null; then
    STAT_BODY=$(curl -sf --max-time 3 "$STAT_URL" 2>/dev/null || echo "")

    if [[ -n "$STAT_BODY" ]]; then
        check_pass "stat_page" "Nginx stat page is reachable at $STAT_URL"

        # Check active client count
        NCLIENTS=$(echo "$STAT_BODY" | grep -oP '(?<=<nclients>)\d+' | head -1 || echo "0")
        if [[ "${NCLIENTS:-0}" -gt 0 ]]; then
            check_pass "active_streams" "$NCLIENTS active client(s) connected to Nginx RTMP"
        else
            check_warn "active_streams" "No active clients on Nginx RTMP yet (OBS not streaming?)"
        fi

        # Check if 'live' application has an active stream
        if echo "$STAT_BODY" | grep -q "<name>live</name>"; then
            check_pass "live_app" "'live' RTMP application is registered"
        else
            check_warn "live_app" "'live' RTMP application not visible in stats"
        fi
    else
        check_fail "stat_page" "Nginx stat page unreachable at $STAT_URL"
    fi
else
    check_warn "stat_page" "curl not installed — install with: apt-get install curl"
fi

# -----------------------------------------------------------------------
header "Nginx HTTP Health Endpoint"
# -----------------------------------------------------------------------

HEALTH_RESPONSE=$(curl -sf --max-time 3 "http://127.0.0.1:8080/health" 2>/dev/null || echo "UNREACHABLE")
if [[ "$HEALTH_RESPONSE" == "OK" ]]; then
    check_pass "health_endpoint" "Nginx health endpoint returned OK"
else
    check_fail "health_endpoint" "Health endpoint response: '$HEALTH_RESPONSE'"
fi

# -----------------------------------------------------------------------
header "Firewall / Network"
# -----------------------------------------------------------------------

# Check if UFW allows port 1935
if command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "1935"; then
        check_pass "ufw_1935" "UFW: port 1935 rule found"
    else
        check_warn "ufw_1935" "UFW: no rule for port 1935 found (may block OBS connections from LAN)"
    fi
fi

# External connectivity test (reach YouTube RTMP ingest)
if curl -sf --max-time 5 --connect-timeout 4 \
       "http://a.rtmp.youtube.com" > /dev/null 2>&1; then
    check_pass "youtube_reachable" "YouTube RTMP ingest server is reachable"
else
    check_warn "youtube_reachable" "Cannot reach YouTube RTMP server (may be a DNS/network issue)"
fi

# -----------------------------------------------------------------------
header "Log File Status"
# -----------------------------------------------------------------------

LOG_FILES=(
    "/var/log/nginx/error.log"
    "${SCRIPT_DIR}/../logs/ffmpeg/fb_relay.log"
)

for lf in "${LOG_FILES[@]}"; do
    if [[ -f "$lf" ]]; then
        SIZE=$(du -sh "$lf" 2>/dev/null | cut -f1)
        LAST_LINE=$(tail -1 "$lf" 2>/dev/null || echo "(empty)")
        echo -e "    ${CYAN}$lf${NC} (size: $SIZE)"
        echo -e "    Last line: ${LAST_LINE:0:100}"

        # Flag if Nginx error log has recent CRIT/EMERG entries
        if echo "$lf" | grep -q "error.log"; then
            RECENT_ERRORS=$(tail -20 "$lf" 2>/dev/null | grep -c '\[crit\]\|\[emerg\]\|\[alert\]' || echo 0)
            if [[ "$RECENT_ERRORS" -gt 0 ]]; then
                check_warn "nginx_errors" "$RECENT_ERRORS critical errors in Nginx error log (check the file)"
            else
                check_pass "nginx_errors" "No critical errors in Nginx error log"
            fi
        fi
    else
        check_warn "log_${lf##*/}" "Log file not found: $lf"
    fi
done

# -----------------------------------------------------------------------
header "FFmpeg Relay Log (last 5 lines)"
# -----------------------------------------------------------------------
FB_LOG="${SCRIPT_DIR}/../logs/ffmpeg/fb_relay.log"
if [[ -f "$FB_LOG" ]]; then
    tail -5 "$FB_LOG" | sed 's/^/    /'
else
    echo "    (log file not found — FFmpeg relay may not have started yet)"
fi

# -----------------------------------------------------------------------
header "Summary"
# -----------------------------------------------------------------------
echo ""
echo -e "  ${GREEN}PASS: $PASS${NC}   ${YELLOW}WARN: $WARN${NC}   ${RED}FAIL: $FAIL${NC}"
echo ""

if $JSON_MODE; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"pass\": $PASS, \"warn\": $WARN, \"fail\": $FAIL,"
    echo "  \"results\": {"
    for k in "${!RESULTS[@]}"; do
        echo "    \"$k\": \"${RESULTS[$k]}\","
    done
    echo "  }"
    echo "}"
fi

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}  ⚠ System has failures. Do NOT go live until resolved.${NC}\n"
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo -e "${YELLOW}  ⚠ System has warnings. Review before going live.${NC}\n"
    exit 0
else
    echo -e "${GREEN}  ✓ All checks passed. System is ready for live streaming.${NC}\n"
    exit 0
fi
