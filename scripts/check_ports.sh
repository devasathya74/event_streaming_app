#!/usr/bin/env bash
# =============================================================================
# check_ports.sh — Verify Required Ports Are Open and Reachable
# =============================================================================
# Run before going live to confirm the server is accessible from the network.
# Also checks if firewall rules are correctly configured.
#
# Usage: sudo ./check_ports.sh [--remote OBS_IP]
#   --remote OBS_IP   Also test if port 1935 is reachable from a specific IP
#                     (requires nmap or nc, tests from server's perspective)
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

REMOTE_IP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote) REMOTE_IP="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo -e "\n${BLUE}══ Port Availability Check ══${NC}\n"

SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "  Server IP: ${CYAN:-}$SERVER_IP${NC}"
echo ""

# -----------------------------------------------------------------------
check_listen() {
    local port=$1 proto=$2 desc=$3
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "  ${GREEN}✓${NC}  Port $port/$proto ($desc) — LISTENING"
        return 0
    else
        echo -e "  ${RED}✗${NC}  Port $port/$proto ($desc) — NOT LISTENING"
        return 1
    fi
}

echo -e "${BLUE}Required Ports:${NC}"
check_listen 1935 TCP "RTMP ingress from OBS"
check_listen 8080 TCP "HTTP stat/health page"

echo ""
echo -e "${BLUE}Management Ports:${NC}"
check_listen 22   TCP "SSH remote access"

# -----------------------------------------------------------------------
echo ""
echo -e "${BLUE}Firewall Status (UFW):${NC}"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw status numbered | grep -E "1935|8080|22" | sed 's/^/  /'
    
    # Check if 1935 is allowed
    if ufw status 2>/dev/null | grep "1935" | grep -q "ALLOW"; then
        echo -e "  ${GREEN}✓${NC}  UFW allows port 1935"
    else
        echo -e "  ${YELLOW}⚠${NC}  UFW has no ALLOW rule for port 1935"
        echo -e "     Fix: sudo ufw allow 1935/tcp comment 'RTMP from OBS'"
    fi
else
    echo -e "  ${YELLOW}⚠${NC}  UFW is inactive or not installed. Verify iptables manually if needed."
fi

# -----------------------------------------------------------------------
echo ""
echo -e "${BLUE}iptables quick check (port 1935):${NC}"
if command -v iptables &>/dev/null; then
    iptables -L INPUT -n --line-numbers 2>/dev/null | grep "1935" | sed 's/^/  /' || \
        echo -e "  (no explicit iptables rule for 1935 — relying on UFW or policy)"
fi

# -----------------------------------------------------------------------
if [[ -n "$REMOTE_IP" ]]; then
    echo ""
    echo -e "${BLUE}Remote Reachability Test from $REMOTE_IP perspective:${NC}"
    if command -v nc &>/dev/null; then
        if timeout 5 nc -z "$SERVER_IP" 1935 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC}  Port 1935 reachable from this host"
        else
            echo -e "  ${RED}✗${NC}  Port 1935 NOT reachable from this host"
            echo -e "     Check: firewall, NAT rules, VPN routing"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC}  nc (netcat) not found. Install: apt install netcat-openbsd"
    fi
fi

# -----------------------------------------------------------------------
echo ""
echo -e "${BLUE}OBS Connection String:${NC}"
echo -e "  URL:        rtmp://${SERVER_IP}:1935/live"
echo -e "  Stream Key: stream"
echo ""
