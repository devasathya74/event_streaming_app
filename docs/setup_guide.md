# Step-by-Step Setup Guide

## Prerequisites

| Item | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 20.04 / Kali Linux | Ubuntu 22.04 LTS |
| CPU | 4 cores | 6+ cores |
| RAM | 4 GB | 8 GB |
| Upload bandwidth | 8 Mbps stable | 15+ Mbps |
| Storage | 10 GB free | 20 GB |
| Internet | Wired or strong Wi-Fi | Wired Ethernet only |

---

## Option A: Local Machine (Laptop — Kali Linux / Ubuntu)

### Step 1 — Update System

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

### Step 2 — Install Nginx with RTMP Module

The `libnginx-mod-rtmp` package provides the RTMP module as a dynamic module for the standard Nginx package.

```bash
# Install nginx and the rtmp module
sudo apt-get install -y nginx libnginx-mod-rtmp

# Verify the module is available
nginx -V 2>&1 | grep rtmp
# Expected output should include: --add-dynamic-module=...nginx-rtmp-module
```

> **If libnginx-mod-rtmp is not available in your repos**, build from source:
> ```bash
> # Install build deps
> sudo apt-get install -y build-essential libpcre3 libpcre3-dev \
>     libssl-dev libgd-dev git zlib1g zlib1g-dev
>
> # Clone nginx-rtmp-module
> git clone https://github.com/arut/nginx-rtmp-module.git /tmp/nginx-rtmp-module
>
> # Download nginx source (match version: nginx -v)
> NGINX_VER=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+')
> wget http://nginx.org/download/nginx-${NGINX_VER}.tar.gz -O /tmp/nginx.tar.gz
> tar -xzf /tmp/nginx.tar.gz -C /tmp/
>
> # Build with RTMP module
> cd /tmp/nginx-${NGINX_VER}
> ./configure --add-module=/tmp/nginx-rtmp-module $(nginx -V 2>&1 | grep -oP "(?<=configure arguments: ).*")
> make -j$(nproc)
> sudo make install
> ```

### Step 3 — Install FFmpeg

```bash
sudo apt-get install -y ffmpeg

# Verify FFmpeg version and RTMPS support
ffmpeg -version
ffmpeg -protocols 2>/dev/null | grep -i rtmps
# Must show: rtmps in the output
```

### Step 4 — Install Project Files

```bash
# Create the project directory
sudo mkdir -p /opt/streaming-backend
sudo cp -r /path/to/streaming-backend/* /opt/streaming-backend/

# Set permissions
sudo chmod +x /opt/streaming-backend/scripts/*.sh
sudo chmod 600 /opt/streaming-backend/keys/stream_keys.env
sudo chown root:root /opt/streaming-backend/keys/stream_keys.env
```

### Step 5 — Deploy Nginx Configuration

```bash
# Backup existing config
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup

# Copy new configs
sudo cp /opt/streaming-backend/nginx/nginx.conf /etc/nginx/nginx.conf
sudo cp /opt/streaming-backend/nginx/rtmp.conf /etc/nginx/rtmp.conf

# Edit rtmp.conf and replace [YT_STREAM_KEY] with your real YouTube stream key
sudo nano /etc/nginx/rtmp.conf
# Find this line:
#   push rtmp://a.rtmp.youtube.com/live2/[YT_STREAM_KEY];
# Replace [YT_STREAM_KEY] with your actual key, e.g.:
#   push rtmp://a.rtmp.youtube.com/live2/abcd-efgh-ijkl-mnop-qrst;

# Validate config
sudo nginx -t
```

### Step 6 — Configure Stream Keys

```bash
sudo nano /opt/streaming-backend/keys/stream_keys.env
```

Replace all placeholder values with your actual stream keys:
```bash
YT_STREAM_KEY="abcd-efgh-ijkl-mnop-qrst"    # Your real YouTube key
FB_STREAM_KEY="FB-123456789-0-xxxxxxxxxxxx"  # Your real Facebook key
```

Save and secure:
```bash
sudo chmod 600 /opt/streaming-backend/keys/stream_keys.env
```

### Step 7 — Set Up Nginx Stat Page Assets

```bash
# Download the stat.xsl stylesheet for the stat page
sudo mkdir -p /var/www/nginx-rtmp/
sudo wget -O /var/www/nginx-rtmp/stat.xsl \
    https://raw.githubusercontent.com/arut/nginx-rtmp-module/master/stat.xsl
```

### Step 8 — Create Log Directories

```bash
sudo mkdir -p /opt/streaming-backend/logs/{nginx,ffmpeg,rtmp}
sudo mkdir -p /var/log/nginx
sudo chown -R www-data:www-data /var/log/nginx
sudo chmod 755 /opt/streaming-backend/logs
```

### Step 9 — Configure Firewall

```bash
# Allow RTMP from OBS (adjust if OBS is on a different machine)
sudo ufw allow 1935/tcp comment "RTMP from OBS"

# Keep stat page internal only (NO external access)
# Port 8080 should NOT be opened externally — use SSH tunnel to access it remotely

# Allow SSH (if remote management)
sudo ufw allow 22/tcp comment "SSH management"

# Enable UFW
sudo ufw enable
sudo ufw status verbose
```

### Step 10 — Install systemd Services

```bash
# Copy service files
sudo cp /opt/streaming-backend/systemd/nginx-rtmp.service /etc/systemd/system/
sudo cp /opt/streaming-backend/systemd/fb-relay.service /etc/systemd/system/
sudo cp /opt/streaming-backend/systemd/watchdog.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable services to start on boot
sudo systemctl enable nginx-rtmp
sudo systemctl enable fb-relay
sudo systemctl enable watchdog

# Start services
sudo systemctl start nginx-rtmp
sleep 3
sudo systemctl start fb-relay
sleep 2
sudo systemctl start watchdog

# Check status
sudo systemctl status nginx-rtmp
sudo systemctl status fb-relay
sudo systemctl status watchdog
```

### Step 11 — Run Pre-Event Validation

```bash
sudo bash /opt/streaming-backend/scripts/pre_event_test.sh
```

All items must PASS before going live.

---

## Option B: Cloud VPS

### Recommended VPS Specs

| Provider | Plan | Cost | Notes |
|---|---|---|---|
| Hetzner | CX21 (2 vCPU, 4GB RAM) | ~€4/mo | Best value in EU/Asia |
| DigitalOcean | Basic 2GB Droplet | ~$12/mo | Good global coverage |
| Vultr | Regular 2GB | ~$12/mo | Many global regions |
| Linode/Akamai | Shared 2GB | ~$12/mo | Reliable |

Key requirement: **Server must have an upload bandwidth guarantee of at least 100 Mbps** (most budget VPS providers do). The actual stream uses ~6–7 Mbps; headroom is for other traffic.

### VPS-Specific Steps

```bash
# 1. SSH into your VPS
ssh root@[VPS_IP]

# 2. Follow Steps 1–10 from Option A exactly
#    The commands are identical on Ubuntu 22.04 VPS

# 3. Additional: configure OBS to connect to VPS public IP
#    OBS URL: rtmp://[VPS_PUBLIC_IP]:1935/live
#    OBS Key: stream
```

### VPS Network Considerations

- Your upload from OBS laptop to VPS: **~3–4 Mbps** (720p/30fps stream)
- VPS upload from VPS to YouTube: **~3 Mbps**
- VPS upload from VPS to Facebook: **~3 Mbps**
- Total VPS bandwidth used: ~6–7 Mbps (well within any VPS plan)

### Option A vs Option B Comparison

| Factor | Local Laptop | Cloud VPS |
|---|---|---|
| Cost | Free (hardware you own) | €4–$12/month |
| Latency to platforms | Depends on event venue internet | VPS datacenter (usually faster) |
| Reliability | Depends on venue Wi-Fi/Ethernet | Data center power + network |
| Setup complexity | Low | Low (same steps) |
| Single point of failure | Laptop battery, venue internet | VPS network, your laptop |
| Best for | Quick deployment, indoor events | Outdoor or mission-critical events |
| **Verdict** | Fine for most events | **Preferred for high-stakes events** |

**Recommendation**: Use a VPS for police parades and formal public events. The data center internet is more stable than a venue's Wi-Fi, and the VPS keeps running even if your laptop has issues.

---

## Updating YouTube Push Key in Nginx Config

Each time you create a new YouTube Live event, the stream key changes. Update it here:

```bash
# Edit rtmp.conf
sudo nano /etc/nginx/rtmp.conf

# Find and update:
push rtmp://a.rtmp.youtube.com/live2/[NEW_YT_STREAM_KEY];

# Reload Nginx (no restart needed — reload is zero-downtime)
sudo nginx -s reload
# Or: sudo systemctl reload nginx-rtmp
```

## Updating Facebook Stream Key

Facebook keys also change per event. Update in stream_keys.env and restart fb-relay:

```bash
sudo nano /opt/streaming-backend/keys/stream_keys.env
# Update FB_STREAM_KEY="new-key-here"

# Restart only the Facebook relay (Nginx keeps running)
sudo systemctl restart fb-relay
```
