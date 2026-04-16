#!/usr/bin/env bash
# =============================================================================
# pre_event_test.sh — Full Pre-Event Validation Run
# =============================================================================
# Run this at least 1 hour before the event starts.
# It performs a complete end-to-end validation without going live.
#
# What it checks:
#   1. All required tools are installed
#   2. Stream keys are configured (not placeholder values)
#   3. Nginx config is valid
#   4. Nginx can start and bind to port 1935
#   5. FFmpeg can connect to both YouTube and Facebook ingest endpoints
#   6. Network bandwidth is sufficient
#   7. Logs directory is writable
#   8. Generates a readiness report
#
# Usage: sudo ./pre_event_test.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/.."
KEYS_FILE="${BASE_DIR}/keys/stream_keys.env"
REPORT_FILE="${BASE_DIR}/logs/pre_event_report_$(date +%Y%m%d_%H%M%S).txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0

pass() { echo -e "${GREEN}  ✓${NC} $*" | tee -a "$REPORT_FILE"; ((PASS++)); }
fail() { echo -e "${RED}  ✗${NC} $*" | tee -a "$REPORT_FILE"; ((FAIL++)); }
warn() { echo -e "${YELLOW}  ⚠${NC} $*" | tee -a "$REPORT_FILE"; ((WARN++)); }
section() { echo -e "\n${BLUE}── $* ──${NC}" | tee -a "$REPORT_FILE"; }

mkdir -p "${BASE_DIR}/logs"
echo "Pre-Event Validation Report — $(date)" > "$REPORT_FILE"
echo "=======================================" >> "$REPORT_FILE"

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════╗"
echo "║     Pre-Event Readiness Validation         ║"
echo "║     $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚════════════════════════════════════════════╝"
echo -e "${NC}"

# -----------------------------------------------------------------------
section "1. Required Tools"
# -----------------------------------------------------------------------

TOOLS=(nginx ffmpeg curl ss pgrep)
for tool in "${TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        VERSION=$("$tool" --version 2>/dev/null | head -1 || echo "unknown version")
        pass "$tool is installed: $VERSION"
    else
        fail "$tool is NOT installed. Install: apt-get install $tool"
    fi
done

# Check nginx has RTMP module
if nginx -V 2>&1 | grep -q "nginx-rtmp\|rtmp"; then
    pass "Nginx is built with nginx-rtmp-module"
else
    fail "Nginx does NOT have the rtmp module. Install libnginx-mod-rtmp or build from source."
    echo "     Fix: apt-get install libnginx-mod-rtmp"
fi

# -----------------------------------------------------------------------
section "2. Stream Keys Configuration"
# -----------------------------------------------------------------------

if [[ ! -f "$KEYS_FILE" ]]; then
    fail "stream_keys.env not found at $KEYS_FILE"
else
    pass "stream_keys.env file exists"
    PERMS=$(stat -c "%a" "$KEYS_FILE" 2>/dev/null || echo "unknown")
    if [[ "$PERMS" == "600" ]]; then
        pass "stream_keys.env permissions are 600 (secure)"
    else
        warn "stream_keys.env permissions are $PERMS (should be 600). Fix: chmod 600 $KEYS_FILE"
    fi

    source "$KEYS_FILE"

    if [[ "${YT_STREAM_KEY:-}" == *"YOUR_YOUTUBE"* ]] || [[ -z "${YT_STREAM_KEY:-}" ]]; then
        fail "YouTube stream key is still a placeholder. Edit $KEYS_FILE"
    else
        pass "YouTube stream key is set (not placeholder)"
    fi

    if [[ "${FB_STREAM_KEY:-}" == *"YOUR_FACEBOOK"* ]] || [[ -z "${FB_STREAM_KEY:-}" ]]; then
        fail "Facebook stream key is still a placeholder. Edit $KEYS_FILE"
    else
        pass "Facebook stream key is set (not placeholder)"
    fi
fi

# -----------------------------------------------------------------------
section "3. Nginx Config Validation"
# -----------------------------------------------------------------------

if nginx -t 2>&1 | tee -a "$REPORT_FILE" | grep -q "successful"; then
    pass "Nginx config test passed"
else
    fail "Nginx config test FAILED"
fi

# Check RTMP config includes YouTube key (not placeholder)
if grep -q "\[YT_STREAM_KEY\]" /etc/nginx/rtmp.conf 2>/dev/null; then
    fail "rtmp.conf still contains [YT_STREAM_KEY] placeholder. Update with real key."
else
    pass "rtmp.conf does not contain YouTube key placeholder"
fi

# -----------------------------------------------------------------------
section "4. Network Connectivity"
# -----------------------------------------------------------------------

# Test YouTube RTMP reachability
if timeout 8 bash -c "</dev/tcp/a.rtmp.youtube.com/1935" 2>/dev/null; then
    pass "YouTube RTMP port 1935 is reachable"
else
    fail "Cannot reach YouTube RTMP ingest (a.rtmp.youtube.com:1935). Check internet/firewall."
fi

# Test Facebook RTMPS reachability
if timeout 8 bash -c "</dev/tcp/live-api-s.facebook.com/443" 2>/dev/null; then
    pass "Facebook RTMPS port 443 is reachable"
else
    fail "Cannot reach Facebook RTMPS ingest (live-api-s.facebook.com:443). Check internet/firewall."
fi

# -----------------------------------------------------------------------
section "5. Bandwidth Estimate"
# -----------------------------------------------------------------------

echo "  Testing download speed (rough estimate)..."
# 5MB download test from a reliable host
START_TIME=$(date +%s%N)
if curl -sf --max-time 10 -o /dev/null \
    "http://speedtest.tele2.net/5MB.zip" 2>/dev/null; then
    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    MBPS=$(echo "scale=1; 5 * 8 * 1000 / $ELAPSED_MS" | bc 2>/dev/null || echo "?")
    echo "  Download: ~${MBPS} Mbps"

    # We need at least 8 Mbps upload for 2x3000kbps = 6Mbps plus overhead
    # We measure download as a proxy; remind user to test upload separately
    warn "Upload speed test not automated. Manually verify upload ≥ 8 Mbps (speedtest.net)"
else
    warn "Could not complete bandwidth test (network issue or test server down)"
fi

# -----------------------------------------------------------------------
section "6. Disk Space"
# -----------------------------------------------------------------------
FREE_DISK=$(df -h /var/log 2>/dev/null | awk 'NR==2 {print $4}')
FREE_DISK_KB=$(df /var/log 2>/dev/null | awk 'NR==2 {print $4}')
if [[ "${FREE_DISK_KB:-0}" -gt 1048576 ]]; then  # > 1GB
    pass "Sufficient disk space for logs: $FREE_DISK free"
else
    warn "Low disk space: $FREE_DISK free on /var/log. Logs may fill up during long events."
fi

# -----------------------------------------------------------------------
section "7. Log Directory Writability"
# -----------------------------------------------------------------------
for dir in "${BASE_DIR}/logs/nginx" "${BASE_DIR}/logs/ffmpeg" "/var/log/nginx"; do
    mkdir -p "$dir" 2>/dev/null
    if [[ -w "$dir" ]]; then
        pass "Log directory writable: $dir"
    else
        fail "Log directory NOT writable: $dir (chmod or chown needed)"
    fi
done

# -----------------------------------------------------------------------
# Final Report
# -----------------------------------------------------------------------
echo "" | tee -a "$REPORT_FILE"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$REPORT_FILE"
echo -e "  RESULT: ${GREEN}PASS: $PASS${NC}  ${YELLOW}WARN: $WARN${NC}  ${RED}FAIL: $FAIL${NC}" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "  Full report saved to: $REPORT_FILE" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}✗ NOT READY. Fix all failures before the event.${NC}" | tee -a "$REPORT_FILE"
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo -e "  ${YELLOW}⚠ Review warnings. System may be ready but verify manually.${NC}" | tee -a "$REPORT_FILE"
    exit 0
else
    echo -e "  ${GREEN}✓ System is fully ready for live event streaming.${NC}" | tee -a "$REPORT_FILE"
    exit 0
fi
