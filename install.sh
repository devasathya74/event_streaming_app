#!/usr/bin/env bash
# =============================================================================
# install.sh — Master One-Shot Deployment Script (Kali Linux Optimized)
# =============================================================================
# Purpose: Deploys a production-grade live streaming relay stack.
# Target: Kali Linux, Ubuntu 22.04+, Debian 11+
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/streaming-backend"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAT_DIR="/var/www/nginx-rtmp"
VIEWER_DIR="/var/www/html/watch"
HLS_DIR="/var/www/html/hls"

# ── Color Definitions ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Helper Functions ──────────────────────────────────────────────────────────
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BLUE}${BOLD}▶ $*${NC}"; }
log_success() { echo -e "${GREEN}${BOLD}✓ $*${NC}"; }
die()         { log_error "$*"; exit 1; }

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
cat << 'EOF'
    ____        __ _                                _  _ 
   / ___| _ __  / _(_) __ _ _ __ __ ___   _(_) |_ _   | || |
  | |  _ | '__|| |_| |/ _` | '__/ _` \ \ / / | __| | | | || |_
  | |_| || |   |  _| | (_| | | | (_| |\ V /| | |_| |_| |__   _|
   \____||_|   |_| |_|\__, |_|  \__,_| \_/ |_|\__|\__, |  |_|
                      |___/                       |___/ 
      LIVE STREAMING BACKEND — KALI MASTER INSTALLER
EOF
echo -e "${NC}"

# ── Phase 1: Environment Validation ───────────────────────────────────────────
log_step "Phase 1: Environment Validation"

# 1.1 Root check
[[ $EUID -ne 0 ]] && die "This script must be run as root. Use: sudo bash install.sh"

# 1.2 OS check
if ! grep -qi "kali\|ubuntu\|debian" /etc/os-release; then
    log_warn "OS not officially supported. Kali/Ubuntu/Debian recommended."
fi

# 1.3 Port 80 Conflict Check
if ss -tlnp 2>/dev/null | grep ':80 ' | grep -q 'apache'; then
    log_warn "Apache is running on port 80. Nginx requires this port."
    read -p "Disable Apache and proceed? [y/N] " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true
        log_info "Apache disabled."
    else
        die "Port 80 conflict. Please stop the application using port 80."
    fi
fi

# ── Phase 2: Dependency Management ────────────────────────────────────────────
log_step "Phase 2: Dependency Management"

apt-get update -qq
PACKAGES=(nginx libnginx-mod-rtmp ffmpeg curl ufw rsync bc python3)

for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" &>/dev/null; then
        log_info "Installing $pkg..."
        apt-get install -y "$pkg" -qq
    else
        log_info "$pkg is already installed."
    fi
done

log_success "Dependencies ready."

# ── Phase 3: Project Deployment ───────────────────────────────────────────────
log_step "Phase 3: Project Deployment"

mkdir -p "$INSTALL_DIR"
log_info "Deploying files to $INSTALL_DIR..."
rsync -a --exclude='.git' "${SOURCE_DIR}/" "$INSTALL_DIR/"

mkdir -p "$INSTALL_DIR/logs/"{nginx,ffmpeg,rtmp}
mkdir -p "$STAT_DIR" "$VIEWER_DIR" "$HLS_DIR"
mkdir -p /var/recordings /var/www/html/clips
chown -R www-data:www-data /var/recordings /var/www/html/clips
chown -R www-data:www-data "$HLS_DIR" "$VIEWER_DIR"

log_info "Deploying Nginx configurations..."
cp "$INSTALL_DIR/nginx/nginx.conf" /etc/nginx/nginx.conf
cp "$INSTALL_DIR/nginx/rtmp.conf"  /etc/nginx/rtmp.conf

log_info "Deploying HLS Viewer assets..."
if [[ -d "$INSTALL_DIR/viewer" ]]; then
    cp -r "$INSTALL_DIR/viewer/"* "$VIEWER_DIR/"
fi

chmod +x "$INSTALL_DIR/scripts/"*.sh
chmod 600 "$INSTALL_DIR/keys/stream_keys.env"
chown root:root "$INSTALL_DIR/keys/stream_keys.env"

log_success "Deployment complete."

# ── Phase 4: Stream Key Configuration (Optional) ─────────────────────────────
log_step "Phase 4: Stream Key Configuration (Optional)"

KEYS_FILE="$INSTALL_DIR/keys/stream_keys.env"
RTMP_CONF="/etc/nginx/rtmp.conf"

setup_keys() {
    echo -e "${CYAN}Enter stream keys now or leave blank to set later via Dashboard:${NC}"
    
    # Load defaults
    source "$KEYS_FILE"

    read -p "YouTube Key [${YT_STREAM_KEY:-None}]: " new_yt
    if [[ -n "$new_yt" ]]; then
        sed -i "s|YT_STREAM_KEY=.*|YT_STREAM_KEY=\"$new_yt\"|g" "$KEYS_FILE"
        # Update rtmp.conf block
        sed -i "/# YT_PUSH_START/,/# YT_PUSH_END/{ /# push/c\    push rtmp://a.rtmp.youtube.com/live2/$new_yt;" "$RTMP_CONF"
        log_info "YouTube key updated."
    fi

    read -p "Facebook Key [${FB_STREAM_KEY:-None}]: " new_fb
    if [[ -n "$new_fb" ]]; then
        sed -i "s|FB_STREAM_KEY=.*|FB_STREAM_KEY=\"$new_fb\"|g" "$KEYS_FILE"
        sed -i "/# FB_PUSH_START/,/# FB_PUSH_END/{ /# push/c\    push rtmp://127.0.0.1:1936/fbsink/stream;" "$RTMP_CONF"
        log_info "Facebook key updated."
    fi
}

read -p "Configure stream keys now? [y/N] " do_keys
if [[ $do_keys =~ ^[Yy]$ ]]; then setup_keys; fi

log_success "Key configuration handled."

# ── Phase 5: System Services ─────────────────────────────────────────────────
log_step "Phase 5: System Services"

for service in "$INSTALL_DIR/systemd/"*.service; do
    s_name=$(basename "$service")
    log_info "Installing service: $s_name"
    sed "s|/opt/streaming-backend|$INSTALL_DIR|g" "$service" > "/etc/systemd/system/$s_name"
done

systemctl daemon-reload

# Validate nginx config BEFORE trying to start nginx-rtmp
log_info "Validating nginx config..."
if ! nginx -t 2>&1; then
    log_error "Nginx config is invalid — fixing and retrying..."
    # Emergency: copy configs from install dir to /etc/nginx
    cp "$INSTALL_DIR/nginx/nginx.conf" /etc/nginx/nginx.conf
    cp "$INSTALL_DIR/nginx/rtmp.conf"  /etc/nginx/rtmp.conf
    if ! nginx -t 2>&1; then
        log_error "Still invalid. Check: nginx -t"
        log_error "Common fix: libnginx-mod-rtmp not installed"
        log_info  "Run: apt-get install -y libnginx-mod-rtmp"
    fi
fi

SERVICES=("nginx-rtmp" "fb-relay" "watchdog" "stream-api" "stream-clipper")

for s in "${SERVICES[@]}"; do
    log_info "Starting $s..."
    if systemctl enable "$s" --now 2>/dev/null; then
        log_info "  ✓ $s started"
    else
        log_warn "  ✗ $s failed — journalctl -u $s -n 20"
    fi
done

log_success "Services processed."

# ── Phase 6: Permission Hardening ────────────────────────────────────────────
log_step "Phase 6: Permission Hardening"

log_info "Configuring sudoers for management API..."
cat > /etc/sudoers.d/streaming-ops <<EOF
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart nginx-rtmp
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx-rtmp
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart fb-relay
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart watchdog
EOF
chmod 440 /etc/sudoers.d/streaming-ops

log_success "Permissions set."

# ── Phase 7: Security Hardening ──────────────────────────────────────────────
log_step "Phase 7: Security Hardening"

if command -v ufw &>/dev/null; then
    log_info "Configuring UFW Firewall..."
    ufw allow 22/tcp    comment "SSH Access"
    ufw allow 80/tcp    comment "Public HLS Viewer"
    ufw allow 1935/tcp  comment "RTMP Ingest"
    ufw --force enable > /dev/null
fi

# ── Phase 9: Final Validation ─────────────────────────────────────────────────
log_step "Phase 8: Final Validation"

if nginx -t 2>&1 | grep -q "successful"; then
    log_info "Nginx: OK"
else
    log_error "Nginx configuration error! Check: nginx -t"
fi

for s in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$s"; then
        log_info "$s: ACTIVE"
    else
        log_warn "$s: FAILED TO START"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
IP_ADDR=$(hostname -I | awk '{print $1}')

API_TOKEN=$(cat "$INSTALL_DIR/keys/api_token" 2>/dev/null || echo "[generated on first start]")

echo -e "\n${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}        STREAMOPS — MASTER DEPLOYMENT COMPLETE                 ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "\n  ${BOLD}Public Viewer:${NC}     ${CYAN}http://$IP_ADDR/watch${NC}"
echo -e "  ${BOLD}Dashboard:${NC}         ${CYAN}http://$IP_ADDR/watch${NC} (→ dashboard tab)"
echo -e "  ${BOLD}OBS RTMP URL:${NC}      ${CYAN}rtmp://$IP_ADDR:1935/live${NC}"
echo -e "  ${BOLD}OBS Stream Key:${NC}    ${CYAN}stream${NC} (literal word 'stream')"
echo -e "  ${BOLD}API Token:${NC}         ${YELLOW}$API_TOKEN${NC}"
echo -e "\n  ${BOLD}Post-install commands:${NC}"
echo -e "    ${CYAN}cat /opt/streaming-backend/commands.txt${NC}"
echo -e "\n${GREEN}${BOLD}================================================================${NC}\n"
