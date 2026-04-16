# Security Guide — Live Streaming Backend

## Threat Model

For event streaming, the primary risks are:
1. **Unauthorized stream injection** — someone else pushes a stream using your RTMP URL
2. **Stream key exposure** — keys leaked give adversaries control of your YouTube/Facebook live
3. **Server compromise** — attacker gains shell access to the relay machine
4. **Denial of service** — someone floods port 1935 to disrupt the event

This guide addresses all four.

---

## 1. Restricting RTMP Publish Access

### Option A: IP Allowlisting (Recommended)

In `rtmp.conf`, restrict publishing to only the OBS machine:

```nginx
application live {
    live on;

    # If OBS and Nginx are on the same machine:
    allow publish 127.0.0.1;

    # If OBS is on a separate machine on the same LAN:
    # allow publish 192.168.1.100;    ← OBS laptop's LAN IP

    # If OBS connects from the internet (VPS setup):
    # allow publish 203.0.113.45;     ← OBS machine's public IP

    deny publish all;
    deny play all;
}
```

To find OBS machine's IP:
```bash
# On Linux:
ip addr show | grep "inet " | grep -v 127.0.0.1

# On Windows (OBS machine):
ipconfig | findstr "IPv4"
```

> **Important**: If using a VPS and OBS connects from a 4G/LTE connection, the IP changes with each reconnect. In this case, use a stream key password approach (Option B) or use a static IP SIM card.

### Option B: RTMP Stream Key Password

Nginx RTMP does not natively support password authentication. Use this workaround:

In `rtmp.conf`, add an `on_publish` hook that validates the stream key:

```nginx
application live {
    live on;
    # Custom key validation: OBS must use stream key "event2024secure"
    # The actual stream key IS the application path portion
    # In OBS settings, set Stream Key to: stream?key=YOUR_SECRET
    on_publish http://127.0.0.1:8080/auth;
    deny play all;
}
```

This approach requires a small HTTP auth service. For simplicity at events, IP allowlisting is preferred.

---

## 2. Protecting Stream Keys

### Never store keys in plaintext in version control

```bash
# Add to .gitignore
echo "keys/*.env" >> .gitignore
echo "keys/**" >> .gitignore
```

### File permissions
```bash
sudo chmod 600 /opt/streaming-backend/keys/stream_keys.env
sudo chown root:root /opt/streaming-backend/keys/stream_keys.env
```

### Rotate keys after every event
YouTube and Facebook both allow you to reset your stream key in their dashboards. Do this after every event, especially if the stream was tested by multiple people.

---

## 3. Firewall Rules

### UFW (Ubuntu/Kali)

```bash
# Reset to defaults (clean slate)
sudo ufw --force reset

# Deny all by default
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (restrict to your management IP if possible)
sudo ufw allow from [MANAGEMENT_IP] to any port 22 proto tcp comment "SSH admin"
# Or allow from anywhere if management IP is dynamic:
# sudo ufw allow 22/tcp comment "SSH"

# Allow RTMP only from OBS machine
sudo ufw allow from [OBS_MACHINE_IP] to any port 1935 proto tcp comment "RTMP from OBS"

# Block everything else
# (UFW default deny covers this)

# Enable
sudo ufw enable
sudo ufw status verbose
```

**Critical**: Port 8080 (stat page) must NOT be opened in UFW. Access it only via SSH tunnel:
```bash
# From your local machine, tunnel to the server's stat page:
ssh -L 8080:127.0.0.1:8080 user@[SERVER_IP]
# Then browse: http://localhost:8080/stat
```

### iptables Direct (if UFW is not available)

```bash
# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow SSH from management IP
iptables -A INPUT -s [MANAGEMENT_IP] -p tcp --dport 22 -j ACCEPT

# Allow RTMP from OBS machine only
iptables -A INPUT -s [OBS_MACHINE_IP] -p tcp --dport 1935 -j ACCEPT

# Drop everything else
iptables -A INPUT -j DROP

# Save rules
iptables-save > /etc/iptables/rules.v4
```

---

## 4. Linux Server Hardening

### SSH Hardening

```bash
sudo nano /etc/ssh/sshd_config
```

Set or verify these values:
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
```

Generate and deploy SSH key (from your admin machine):
```bash
# On your admin machine:
ssh-keygen -t ed25519 -C "streaming-admin" -f ~/.ssh/streaming_key

# Copy public key to server:
ssh-copy-id -i ~/.ssh/streaming_key.pub user@[SERVER_IP]

# Restart SSH to apply changes:
sudo systemctl restart sshd
```

### Disable Unused Services

```bash
# Check what's running
sudo systemctl list-units --type=service --state=active

# Disable services you don't need (examples):
sudo systemctl disable --now bluetooth avahi-daemon cups
```

### Automatic Security Updates

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -pmedium unattended-upgrades
```

### Install Fail2ban (Brute Force Protection)

```bash
sudo apt-get install -y fail2ban

# Create local jail config
sudo nano /etc/fail2ban/jail.local
```

Add:
```ini
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 22
logpath = /var/log/auth.log
```

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

---

## 5. Nginx Hardening

### Restrict Server Tokens

Add to the `http {}` block in `nginx.conf`:
```nginx
server_tokens off;     # Don't reveal nginx version
```

### Rate Limiting on HTTP Stat Page

```nginx
# In nginx.conf http block:
limit_req_zone $binary_remote_addr zone=stat_limit:10m rate=10r/m;

# In the stat server block:
location /stat {
    limit_req zone=stat_limit burst=5 nodelay;
    allow 127.0.0.1;
    deny all;
    rtmp_stat all;
}
```

---

## 6. What NOT to Do

- ❌ Do NOT expose port 8080 to the public internet
- ❌ Do NOT use the same stream key across multiple events
- ❌ Do NOT commit `stream_keys.env` to any repository
- ❌ Do NOT run Nginx as root (it binds port 1935 as root, then drops to `www-data`)
- ❌ Do NOT allow `deny publish all` to be removed or commented out
- ❌ Do NOT share the OBS stream key with vendors or clients — it gives them control of your relay
