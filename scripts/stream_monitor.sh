#!/usr/bin/env bash
# =============================================================================
# stream_monitor.sh — Real-Time Ingest Traffic & Quality Monitor
# =============================================================================
# Purpose: Provides 'X-ray vision' into the live RTMP ingest.
# Displays: Bitrate (kbps), Ingress Bandwidth, and Active Client count.
# =============================================================================

set -uo pipefail

# Configuration
STAT_URL="http://127.0.0.1:8080/stat"
INTERVAL=2

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

clear
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║          LIVE STREAM INGEST QUALITY MONITOR                ║${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "Monitoring ingest at $STAT_URL... (Ctrl+C to stop)\n"

prev_bytes=0
prev_time=0

while true; do
    # Fetch XML stat
    STAT_XML=$(curl -sf --max-time 2 "$STAT_URL" 2>/dev/null || echo "")

    if [[ -z "$STAT_XML" ]]; then
        echo -e "${RED}[ERROR]${NC} Cannot reach Nginx Stat page. Is Nginx running?"
        sleep 5
        continue
    fi

    # Parse using grep/sed (avoiding heavy XML tools for zero-dependency)
    CLIENTS=$(echo "$STAT_XML" | grep -oP '(?<=<nclients>)\d+' | head -1 || echo "0")
    
    # Get total bytes in for the 'live' application
    # This is a bit tricky with grep, let's find the 'live' app block and then the <bytes_in>
    BYTES_IN=$(echo "$STAT_XML" | sed -n '/<name>live<\/name>/,/<\/application>/p' | grep -oP '(?<=<bytes_in>)\d+' | head -1 || echo "0")
    
    NOW=$(date +%s)
    
    if [[ "$prev_bytes" -gt 0 ]]; then
        # Calculate Delta
        DELTA_BYTES=$(( BYTES_IN - prev_bytes ))
        DELTA_TIME=$(( NOW - prev_time ))
        
        if [[ "$DELTA_TIME" -gt 0 ]]; then
            # Bitrate in kbps (bits per second / 1000)
            BITRATE=$(( (DELTA_BYTES * 8) / (DELTA_TIME * 1024) ))
            
            # Formatting
            STATUS_COLOR=$GREEN
            [[ "$BITRATE" -lt 1500 ]] && STATUS_COLOR=$YELLOW
            [[ "$BITRATE" -lt 500 ]] && STATUS_COLOR=$RED
            [[ "$CLIENTS" -eq 0 ]] && STATUS_COLOR=$NC
            
            printf "\r${BOLD}Status:${NC} %-10s | ${BOLD}Ingest:${NC} ${STATUS_COLOR}%4d kbps${NC} | ${BOLD}Clients:${NC} %2d | ${BOLD}Time:${NC} %s" \
                "$([[ "$CLIENTS" -gt 0 ]] && echo -e "${GREEN}ACTIVE${NC}" || echo -e "${RED}WAITING${NC}")" \
                "$BITRATE" \
                "$CLIENTS" \
                "$(date '+%H:%M:%S')"
        fi
    fi

    prev_bytes=$BYTES_IN
    prev_time=$NOW
    sleep "$INTERVAL"
done
