#!/usr/bin/env bash
# =============================================================================
# install.sh — One-Shot Deployment Script
# =============================================================================
# This script deploys the entire streaming-backend to /opt/streaming-backend,
# installs Nginx configs, sets up systemd services, configures the firewall,
# and validates the installation.
#
# Run from the project root directory:
#   sudo bash install.sh
#
# Supported OS: Ubuntu 20.04+, Ubuntu 22.04 LTS, Kali Linux 2022+
# =============================================================================

set -euo pipefail

# ── Colour codes ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BLUE}${BOLD}▶ $*${NC}"; }
log_success() { echo -e "${GREEN}${BOLD}✓ $*${NC}"; }
die()         { log_error "$*"; exit 1; }

INSTALL_DIR="/opt/streaming-backend"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${CYAN}"
cat << 'EOF'
╔══════════════════════════════════════════════════════════╗
║     Live Streaming Backend — Installer                   ║
║     OBS → Nginx RTMP → YouTube + Facebook Live           ║
╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "This script must be run as root. Use: sudo bash install.sh"

# ── OS check ─────────────────────────────────────────────────────────────────
if ! grep -qi "ubuntu\|debian\|kali" /etc/os-release 2>/dev/null; then
    log_warn "OS not detected as Ubuntu/Debian/Kali. Proceeding anyway — adjust package names if needed."
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 1 of 9 — Install required packages"
# ═══════════════════════════════════════════════════════════════════════════════

apt-get update -qq

PACKAGES=(nginx libnginx-mod-rtmp ffmpeg curl ufw fail2ban bc)
MISSING=()

for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" &>/dev/null; then
        MISSING+=("$pkg")
    else
        log_info "$pkg is already installed."
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log_info "Installing: ${MISSING[*]}"
    apt-get install -y "${MISSING[@]}"
fi

# Verify nginx has RTMP module
if ! nginx -V 2>&1 | grep -q "rtmp"; then
    log_warn "nginx-rtmp-module not detected in nginx -V output."
    log_warn "If streaming fails, see docs/setup_guide.md → 'Build from source' section."
else
    log_info "nginx-rtmp-module confirmed."
fi

# Verify FFmpeg has RTMPS support
if ! ffmpeg -protocols 2>/dev/null | grep -q "rtmps"; then
    log_warn "FFmpeg may not support RTMPS. Install a newer build if Facebook relay fails."
else
    log_info "FFmpeg RTMPS support confirmed."
fi

log_success "Packages ready."

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 2 of 9 — Create installation directory"
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$SOURCE_DIR" == "$INSTALL_DIR" ]]; then
    log_info "Already running from $INSTALL_DIR — skipping copy."
else
    log_info "Copying project to $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR"
    # Copy all project files (exclude .git)
    rsync -a --exclude='.git' "${SOURCE_DIR}/" "${INSTALL_DIR}/"
    log_info "Files copied to $INSTALL_DIR"
fi

# Create log directories
mkdir -p \
    "${INSTALL_DIR}/logs/nginx" \
    "${INSTALL_DIR}/logs/ffmpeg" \
    "${INSTALL_DIR}/logs/rtmp" \
    /var/log/nginx

log_success "Directory structure ready at $INSTALL_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 3 of 9 — Set file permissions"
# ═══════════════════════════════════════════════════════════════════════════════

# Make all scripts executable
chmod +x "${INSTALL_DIR}/scripts/"*.sh

# Protect stream keys
chmod 600 "${INSTALL_DIR}/keys/stream_keys.env"
chown root:root "${INSTALL_DIR}/keys/stream_keys.env"

# Allow nginx (www-data) to write to nginx log dir
chown -R www-data:www-data /var/log/nginx 2>/dev/null || true
chmod 755 "${INSTALL_DIR}/logs"

log_success "Permissions set."

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 4 of 9 — Deploy Nginx configuration"
# ═══════════════════════════════════════════════════════════════════════════════

# Backup existing config
if [[ -f /etc/nginx/nginx.conf ]]; then
    BACKUP="/etc/nginx/nginx.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cp /etc/nginx/nginx.conf "$BACKUP"
    log_info "Backed up existing nginx.conf to $BACKUP"
fi

# Copy configs
cp "${INSTALL_DIR}/nginx/nginx.conf" /etc/nginx/nginx.conf
cp "${INSTALL_DIR}/nginx/rtmp.conf"  /etc/nginx/rtmp.conf

# Verify config
if nginx -t 2>&1 | grep -q "successful"; then
    log_success "Nginx configuration is valid."
else
    log_error "Nginx configuration validation FAILED."
    log_error "Check: nginx -t"
    nginx -t 2>&1 || true
    die "Fix nginx.conf errors and re-run install.sh"
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 5 of 9 — Set up Nginx RTMP stat page assets"
# ═══════════════════════════════════════════════════════════════════════════════

STAT_DIR="/var/www/nginx-rtmp"
mkdir -p "$STAT_DIR"

if [[ ! -f "${STAT_DIR}/stat.xsl" ]]; then
    log_info "Downloading stat.xsl stylesheet..."
    if curl -sf --max-time 15 -o "${STAT_DIR}/stat.xsl" \
        "https://raw.githubusercontent.com/arut/nginx-rtmp-module/master/stat.xsl"; then
        log_success "stat.xsl downloaded."
    else
        log_warn "Could not download stat.xsl (no internet or GitHub unreachable)."
        log_warn "RTMP stat page will still work, but without the styled view."
        # Create minimal placeholder
        echo '<?xml version="1.0"?><xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:template match="/"><html><body><pre><xsl:value-of select="."/></pre></body></html></xsl:template></xsl:stylesheet>' > "${STAT_DIR}/stat.xsl"
    fi
else
    log_info "stat.xsl already exists — skipping download."
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 6 of 9 — Install systemd service units"
# ═══════════════════════════════════════════════════════════════════════════════

# Patch ExecStart paths in service files to match actual install dir
for service_src in "${INSTALL_DIR}/systemd/"*.service; do
    service_name="$(basename "$service_src")"
    service_dest="/etc/systemd/system/${service_name}"

    # Replace /opt/streaming-backend with actual install dir if different
    if [[ "$INSTALL_DIR" != "/opt/streaming-backend" ]]; then
        sed "s|/opt/streaming-backend|${INSTALL_DIR}|g" \
            "$service_src" > "$service_dest"
    else
        cp "$service_src" "$service_dest"
    fi

    log_info "Installed: $service_dest"
done

systemctl daemon-reload

# Enable services for auto-start on boot
systemctl enable nginx-rtmp
systemctl enable fb-relay
systemctl enable watchdog

log_success "systemd units installed and enabled."

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 7 of 9 — Configure Firewall (UFW)"
# ═══════════════════════════════════════════════════════════════════════════════

if command -v ufw &>/dev/null; then
    # Set defaults
    ufw --force default deny incoming  > /dev/null
    ufw --force default allow outgoing > /dev/null

    # SSH — allow from everywhere (user can restrict later)
    ufw allow 22/tcp comment "SSH management" > /dev/null

    # RTMP ingest — allow from everywhere by default
    # To restrict to OBS machine IP, edit and run:
    #   ufw delete allow 1935/tcp
    #   ufw allow from [OBS_IP] to any port 1935 proto tcp
    ufw allow 1935/tcp comment "RTMP from OBS" > /dev/null

    # Port 8080 (RTMP stat page) — internal only, do NOT open publicly
    # Access via: ssh -L 8080:127.0.0.1:8080 user@server

    # Enable UFW non-interactively
    ufw --force enable > /dev/null

    log_success "UFW firewall configured."
    ufw status numbered | head -20
else
    log_warn "UFW not found. Configure your firewall manually. Required: allow TCP 1935."
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 8 of 9 — Validate stream keys configuration"
# ═══════════════════════════════════════════════════════════════════════════════

KEYS_FILE="${INSTALL_DIR}/keys/stream_keys.env"
# shellcheck source=/dev/null
source "$KEYS_FILE"

KEYS_NEED_UPDATE=false

if [[ "${YT_STREAM_KEY:-}" == *"YOUR_YOUTUBE"* ]] || [[ -z "${YT_STREAM_KEY:-}" ]]; then
    log_warn "⚠ YouTube stream key is still a placeholder."
    KEYS_NEED_UPDATE=true
else
    log_info "✓ YouTube stream key is set."
fi

if [[ "${FB_STREAM_KEY:-}" == *"YOUR_FACEBOOK"* ]] || [[ -z "${FB_STREAM_KEY:-}" ]]; then
    log_warn "⚠ Facebook stream key is still a placeholder."
    KEYS_NEED_UPDATE=true
else
    log_info "✓ Facebook stream key is set."
fi

if [[ "$KEYS_NEED_UPDATE" == true ]]; then
    echo ""
    log_warn "ACTION REQUIRED: Update stream keys before starting the relay."
    echo -e "  ${CYAN}sudo nano ${KEYS_FILE}${NC}"
    echo ""
fi

# Check rtmp.conf for placeholder YouTube key
if grep -q "\[YT_STREAM_KEY\]" /etc/nginx/rtmp.conf; then
    log_warn "⚠ /etc/nginx/rtmp.conf still contains [YT_STREAM_KEY] placeholder."
    log_warn "  Edit it: sudo nano /etc/nginx/rtmp.conf"
    log_warn "  Then reload: sudo nginx -s reload"
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_step "Step 9 of 9 — Start services"
# ═══════════════════════════════════════════════════════════════════════════════

log_info "Starting nginx-rtmp..."
systemctl start nginx-rtmp
sleep 2

if systemctl is-active --quiet nginx-rtmp; then
    log_success "nginx-rtmp is running."
else
    log_warn "nginx-rtmp failed to start. Check: journalctl -u nginx-rtmp -n 30"
fi

log_info "Starting fb-relay..."
systemctl start fb-relay
sleep 2

if systemctl is-active --quiet fb-relay; then
    log_success "fb-relay is running."
else
    log_warn "fb-relay failed to start (may need stream keys set first)."
fi

log_info "Starting watchdog..."
systemctl start watchdog
sleep 1

if systemctl is-active --quiet watchdog; then
    log_success "watchdog is running."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Final Summary
# ═══════════════════════════════════════════════════════════════════════════════

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Installation Complete${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Install directory : ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  OBS Server URL    : ${GREEN}rtmp://${SERVER_IP}:1935/live${NC}"
echo -e "  OBS Stream Key    : ${GREEN}stream${NC}"
echo -e "  RTMP Stat page    : ${CYAN}http://127.0.0.1:8080/stat${NC} (local only)"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"

if [[ "$KEYS_NEED_UPDATE" == true ]]; then
echo -e "  ${RED}1. Add your stream keys:${NC}"
echo -e "     sudo nano ${KEYS_FILE}"
echo -e "     sudo nano /etc/nginx/rtmp.conf   (replace [YT_STREAM_KEY])"
echo -e "     sudo nginx -s reload"
echo -e "     sudo systemctl restart fb-relay"
echo ""
fi

echo -e "  2. Run pre-event validation:"
echo -e "     ${CYAN}sudo bash ${INSTALL_DIR}/scripts/pre_event_test.sh${NC}"
echo ""
echo -e "  3. Read the docs:"
echo -e "     ${INSTALL_DIR}/docs/obs_setup.md         ← OBS configuration"
echo -e "     ${INSTALL_DIR}/docs/event_checklist.md   ← Event day runbook"
echo -e "     ${INSTALL_DIR}/docs/security_guide.md    ← Harden your server"
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""
