# Live Streaming Backend — Setup Guide

## 🚀 One-Shot Installation (Recommended)

The easiest way to set up the entire streaming backend on **Kali Linux**, **Ubuntu**, or **Debian** is using the master installer script. This script handles dependencies, configurations, security, and services in a single step.

### Step 1: Clone the Repository
```bash
git clone https://github.com/devasathya74/event_streaming_app.git
cd event_streaming_app
```

### Step 2: Run the Installer
```bash
sudo bash install.sh
```

### What This Script Does:
1.  **Validates Environment**: Checks OS and common port conflicts (e.g., Apache).
2.  **Installs Dependencies**: Nginx (with RTMP), FFmpeg, UFW, etc.
3.  **Deploys Project**: Configures `/opt/streaming-backend`.
4.  **Sets Up Viewer**: Deploys the HLS web player to `/var/www/html/watch`.
5.  **Interactive Config**: Prompts for YouTube and Facebook stream keys.
6.  **Hardens Security**: Configures UFW firewall rules automatically.
7.  **Starts Services**: Registers and starts `nginx-rtmp`, `fb-relay`, and `watchdog`.

---

## 🛠 Manual Configuration (Advanced)

If you prefer to set up components manually or are using a different OS, follow the steps below.

### 1. Update System
```bash
sudo apt-get update && sudo apt-get upgrade -y
```

### 2. Install Nginx + RTMP
```bash
sudo apt-get install -y nginx libnginx-mod-rtmp ffmpeg
```

### 3. Deploy Project Files
```bash
sudo mkdir -p /opt/streaming-backend
sudo cp -r . /opt/streaming-backend/
sudo chmod +x /opt/streaming-backend/scripts/*.sh
```

### 4. Deploy Nginx Config
```bash
sudo cp nginx/nginx.conf /etc/nginx/nginx.conf
sudo cp nginx/rtmp.conf /etc/nginx/rtmp.conf
sudo nginx -t && sudo systemctl reload nginx
```

### 5. Setup Viewers
```bash
sudo mkdir -p /var/www/html/watch /var/www/html/hls
sudo cp -r viewer/* /var/www/html/watch/
sudo chown -R www-data:www-data /var/www/html/hls
```

---

## 📺 OBS Studio Configuration

To start streaming to your new relay:

1.  **Service**: Custom...
2.  **Server**: `rtmp://[YOUR_SERVER_IP]:1935/live`
3.  **Stream Key**: `stream`

### Recommended Settings:
-   **Encoder**: x264 or NVIDIA NVENC
-   **Rate Control**: CBR
-   **Bitrate**: 2500–4000 Kbps
-   **Keyframe Interval**: 2 seconds (Crucial for HLS!)
-   **Profile**: high
-   **Tune**: zerolatency

---

## 🔒 Security Posture

Access the internal dashboard and stats only via SSH tunnel:
```bash
ssh -L 8080:127.0.0.1:8080 user@your-server-ip
```
Then browse to `http://localhost:8080/stat`.
