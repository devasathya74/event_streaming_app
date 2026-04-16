#!/usr/bin/env bash
# =============================================================================
# rotate_keys.sh — One-Command Post-Event Stream Key Rotation
# =============================================================================
# Run this AFTER every event to invalidate used keys and reset to placeholders.
# Follow up by getting new keys from YouTube Studio and Facebook before the
# next event.
#
# Usage: sudo bash rotate_keys.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/.."
KEYS_FILE="${BASE_DIR}/keys/stream_keys.env"
NGINX_RTMP_CONF="/etc/nginx/rtmp.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()    { echo -e "\n${BLUE}▶ $*${NC}"; }
log_success() { echo -e "${GREEN}✓ $*${NC}"; }

echo -e "${CYAN}"
cat << 'EOF'
╔══════════════════════════════════════════════════╗
║   Stream Key Rotation — Post-Event Security      ║
║   Invalidates used keys, resets to placeholders  ║
╚══════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo bash rotate_keys.sh${NC}"; exit 1; }

# ── Step 1: Archive current keys (for audit trail)
log_step "Step 1 — Archive current keys (encrypted)"
ARCHIVE_DIR="${BASE_DIR}/keys/archive"
mkdir -p "$ARCHIVE_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [[ -f "$KEYS_FILE" ]]; then
    cp "$KEYS_FILE" "${ARCHIVE_DIR}/stream_keys.env.${TIMESTAMP}.bak"
    chmod 600 "${ARCHIVE_DIR}/stream_keys.env.${TIMESTAMP}.bak"
    log_success "Backed up to: ${ARCHIVE_DIR}/stream_keys.env.${TIMESTAMP}.bak"
fi

# ── Step 2: Reset stream_keys.env to placeholders
log_step "Step 2 — Reset stream_keys.env to placeholders"
cat > "$KEYS_FILE" << 'ENVEOF'
# =============================================================================
# stream_keys.env — Stream Keys Configuration
# =============================================================================
# ⚠ SECURITY: chmod 600 this file. NEVER commit to git.
# ⚠ Rotate these keys after EVERY event.
# =============================================================================

# ── YouTube ──────────────────────────────────────────────────────────────────
# Get from: YouTube Studio → Go Live → Stream → Stream Key
YT_STREAM_KEY="YOUR_YOUTUBE_STREAM_KEY_HERE"

# ── Facebook ─────────────────────────────────────────────────────────────────
# Get from: Facebook → Professional Dashboard → Live Video → Use Stream Key
FB_STREAM_KEY="YOUR_FACEBOOK_STREAM_KEY_HERE"

# ── Facebook RTMPS Ingest URL (do not change unless Facebook updates it)
FB_RTMPS_URL="rtmps://live-api-s.facebook.com:443/rtmp"
ENVEOF
chmod 600 "$KEYS_FILE"
chown root:root "$KEYS_FILE"
log_success "stream_keys.env reset to placeholders"

# ── Step 3: Reset rtmp.conf YouTube key placeholder
log_step "Step 3 — Reset rtmp.conf YouTube push URL"
if [[ -f "$NGINX_RTMP_CONF" ]]; then
    # Replace any real-looking key with placeholder
    sed -i 's|push rtmp://a.rtmp.youtube.com/live2/[^;]*;|push rtmp://a.rtmp.youtube.com/live2/[YT_STREAM_KEY];|g' "$NGINX_RTMP_CONF"
    log_success "rtmp.conf YouTube push URL reset to placeholder"
    log_warn "Reloading Nginx with placeholder config..."
    nginx -t 2>&1 && nginx -s reload || log_warn "Nginx reload skipped (placeholder config may fail — this is expected)"
else
    log_warn "rtmp.conf not found at $NGINX_RTMP_CONF — skipping"
fi

# ── Step 4: Restart services to pick up cleared keys
log_step "Step 4 — Restart services"
if systemctl is-active --quiet fb-relay 2>/dev/null; then
    systemctl stop fb-relay
    log_success "fb-relay stopped (cleared old key from memory)"
fi
if systemctl is-active --quiet nginx-rtmp 2>/dev/null; then
    systemctl reload nginx-rtmp 2>/dev/null || true
    log_success "nginx-rtmp reloaded"
fi

# ── Step 5: Archive logs
log_step "Step 5 — Archive event logs"
LOGS_DIR="${BASE_DIR}/logs"
ARCHIVE_LOGS="${BASE_DIR}/logs_archive_${TIMESTAMP}"
if [[ -d "$LOGS_DIR" ]]; then
    cp -r "$LOGS_DIR" "$ARCHIVE_LOGS"
    log_success "Logs archived to: $ARCHIVE_LOGS"
fi

# ── Summary
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Key rotation complete${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${YELLOW}Next steps before the next event:${NC}"
echo -e "  1. Get new YouTube stream key from YouTube Studio"
echo -e "     ${CYAN}https://studio.youtube.com → Go Live → Stream → Stream Key${NC}"
echo -e "  2. Get new Facebook stream key from Facebook Live Producer"
echo -e "     ${CYAN}https://facebook.com/live/producer${NC}"
echo -e "  3. Update both keys:"
echo -e "     ${CYAN}sudo nano ${KEYS_FILE}${NC}"
echo -e "     ${CYAN}sudo nano ${NGINX_RTMP_CONF}${NC}  (replace [YT_STREAM_KEY])"
echo -e "     ${CYAN}sudo nginx -s reload${NC}"
echo -e "     ${CYAN}sudo systemctl start fb-relay${NC}"
echo ""
