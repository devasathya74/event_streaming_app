#!/usr/bin/env bash
# =============================================================================
# serve_hls.sh — HLS Setup Validator & Viewer URL Printer
# =============================================================================
# Run this after starting the relay to verify HLS is working and get the
# shareable viewer URL.
#
# Usage: bash scripts/serve_hls.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_ok()   { echo -e "${GREEN}[  OK  ]${NC} $*"; }
log_fail() { echo -e "${RED}[ FAIL ]${NC} $*"; }
log_info() { echo -e "${BLUE}[ INFO ]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[ WARN ]${NC} $*"; }

echo -e "${CYAN}"
cat << 'EOF'
╔══════════════════════════════════════════════════╗
║   StreamOps — HLS Viewer Setup Check             ║
╚══════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

PASS=0; FAIL=0

# ── 1: HLS directory exists ──────────────────────────────
HLS_DIR="/var/www/html/hls"
if [[ -d "$HLS_DIR" ]]; then
    log_ok "HLS directory exists: $HLS_DIR"
    ((PASS++))
else
    log_fail "HLS directory missing — creating..."
    mkdir -p "$HLS_DIR"
    chmod 755 "$HLS_DIR"
    chown www-data:www-data "$HLS_DIR" 2>/dev/null || true
    log_ok "Created $HLS_DIR"
    ((PASS++))
fi

# ── 2: Viewer files deployed ─────────────────────────────
VIEWER_DIR="/var/www/html/viewer"
SCRIPT_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -d "$VIEWER_DIR" ]] && [[ -f "$VIEWER_DIR/index.html" ]]; then
    log_ok "Viewer files deployed at $VIEWER_DIR"
    ((PASS++))
else
    log_warn "Viewer files not deployed — copying now..."
    mkdir -p "$VIEWER_DIR"
    cp -r "$SCRIPT_BASE/viewer/." "$VIEWER_DIR/"
    chmod -R 755 "$VIEWER_DIR"
    chown -R www-data:www-data "$VIEWER_DIR" 2>/dev/null || true
    log_ok "Viewer deployed to $VIEWER_DIR"
    ((PASS++))
fi

# ── 3: Nginx running on port 80 ──────────────────────────
if ss -tlnp 2>/dev/null | grep -q ':80 ' || netstat -tlnp 2>/dev/null | grep -q ':80 '; then
    log_ok "Nginx is LISTENING on port 80"
    ((PASS++))
else
    log_fail "Port 80 not listening — is Nginx running?"
    log_info "Start: sudo systemctl start nginx-rtmp"
    ((FAIL++))
fi

# ── 4: Nginx running on port 1935 ────────────────────────
if ss -tlnp 2>/dev/null | grep -q ':1935 ' || netstat -tlnp 2>/dev/null | grep -q ':1935 '; then
    log_ok "Nginx RTMP is LISTENING on port 1935"
    ((PASS++))
else
    log_fail "Port 1935 not listening — RTMP relay not running"
    ((FAIL++))
fi

# ── 5: Port 80 UFW open ──────────────────────────────────
if command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "80.*ALLOW"; then
        log_ok "UFW: port 80 is open (HTTP)"
        ((PASS++))
    else
        log_warn "UFW: port 80 is NOT open"
        log_info "Run: sudo ufw allow 80/tcp && sudo ufw reload"
        ((FAIL++))
    fi
fi

# ── 6: Viewer page reachable ─────────────────────────────
if curl -sf http://127.0.0.1/watch/ -o /dev/null 2>/dev/null; then
    log_ok "Viewer page is reachable at http://127.0.0.1/watch/"
    ((PASS++))
else
    log_warn "Viewer page not reachable — is Nginx config correct?"
    log_info "Test: sudo nginx -t"
    ((FAIL++))
fi

# ── 7: HLS stream active ─────────────────────────────────
HLS_PLAYLIST="$HLS_DIR/stream/index.m3u8"
if [[ -f "$HLS_PLAYLIST" ]]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$HLS_PLAYLIST" 2>/dev/null || echo 0) ))
    if [[ $AGE -lt 10 ]]; then
        log_ok "HLS playlist is LIVE (updated ${AGE}s ago)"
        ((PASS++))
    else
        log_warn "HLS playlist exists but is ${AGE}s old — OBS may not be streaming"
        ((FAIL++))
    fi
else
    log_warn "No HLS stream yet — start OBS and relay first"
    log_info "Start: sudo bash scripts/start_relay.sh"
fi

# ── Get server's public IP ───────────────────────────────
echo ""
echo -e "${CYAN}── Server Information ──────────────────────────────────${NC}"
PUBLIC_IP=$(curl -sf --max-time 5 https://ipinfo.io/ip 2>/dev/null || \
            curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
            echo "[unknown — check with: curl ipinfo.io/ip]")
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

echo -e "  Public IP  : ${YELLOW}${PUBLIC_IP}${NC}"
echo -e "  Local  IP  : ${YELLOW}${LOCAL_IP}${NC}"

# ── Shareable URLs ───────────────────────────────────────
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}🌐 SHAREABLE VIEWER URLs${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${YELLOW}Public URL (share this link):${NC}"
echo -e "  ${GREEN}http://${PUBLIC_IP}/watch${NC}"
echo ""
echo -e "  ${YELLOW}Local URL (same network):${NC}"
echo -e "  ${GREEN}http://${LOCAL_IP}/watch${NC}"
echo ""
echo -e "  ${YELLOW}HLS stream (m3u8) for VLC / media players:${NC}"
echo -e "  ${GREEN}http://${PUBLIC_IP}/hls/stream/index.m3u8${NC}"
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"

# ── QR Code (if qrencode is available) ──────────────────
if command -v qrencode &>/dev/null; then
    echo ""
    echo -e "${BLUE}QR Code for mobile sharing:${NC}"
    qrencode -t ANSI -m 2 "http://${PUBLIC_IP}/watch"
    echo ""
fi

# ── Summary ──────────────────────────────────────────────
echo ""
echo -e "${CYAN}── Summary ─────────────────────────────────────────────${NC}"
echo -e "  Passed: ${GREEN}${PASS}${NC}  |  Failed: ${RED}${FAIL}${NC}"
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}✅ Everything looks good — share the URL above!${NC}"
else
    echo -e "  ${YELLOW}⚠ Fix the failures above, then run again.${NC}"
fi
echo ""
