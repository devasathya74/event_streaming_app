# Live Event Readiness Checklist
### For: Police Parades, Public Ceremonies, Formal Event Broadcasts
### Complete this checklist at least 1 hour before the event start time

---

## ⏱ 48 Hours Before the Event

- [ ] Create YouTube Live event (scheduled, Unlisted for test, Public for event)
  - [ ] Copy YouTube stream key → update `/etc/nginx/rtmp.conf`
  - [ ] Reload Nginx: `sudo nginx -s reload`
- [ ] Create Facebook Live event
  - [ ] Copy Facebook stream key → update `keys/stream_keys.env`
  - [ ] Restart fb-relay: `sudo systemctl restart fb-relay`
- [ ] Confirm server/laptop is fully charged or on power supply
- [ ] Confirm event venue internet access method: Ethernet / Wi-Fi / 4G
- [ ] Order/test Ethernet cable if wired connection is available at venue

---

## ⏱ Day Before the Event

- [ ] Run full pre-event test from the event location (or equivalent network)
  ```bash
  sudo bash /opt/streaming-backend/scripts/pre_event_test.sh
  ```
- [ ] All checks PASS — no failures
- [ ] Test end-to-end stream: OBS → Relay → YouTube + Facebook (use Unlisted/Private)
  - [ ] Video appears on YouTube within 30 seconds of OBS start
  - [ ] Video appears on Facebook within 30 seconds of OBS start
  - [ ] Audio is clear and in sync
  - [ ] 1080p scenes look sharp at 720p output
- [ ] Test OBS reconnect:
  - [ ] Stop OBS, wait 60 seconds, restart OBS
  - [ ] Both platforms resume without manual intervention
- [ ] Test watchdog:
  - [ ] Kill Nginx manually (`sudo systemctl stop nginx-rtmp`)
  - [ ] Confirm watchdog restarts it within 60 seconds
- [ ] Log rotation is working:
  - [ ] Check log file sizes: `du -sh /opt/streaming-backend/logs/**/*`
  - [ ] Logs should not be growing unboundedly

---

## ⏱ 2 Hours Before the Event

- [ ] Arrive at venue, set up equipment
- [ ] Connect to venue internet (Ethernet preferred)
- [ ] Confirm internet speed: upload ≥ 8 Mbps on [speedtest.net](https://speedtest.net)
  - [ ] If upload < 8 Mbps, reduce OBS bitrate to 2000 kbps and alert the team
- [ ] Start relay stack:
  ```bash
  sudo bash /opt/streaming-backend/scripts/start_relay.sh
  ```
- [ ] Run port check:
  ```bash
  sudo bash /opt/streaming-backend/scripts/check_ports.sh
  ```
  - [ ] Port 1935 is listening
  - [ ] Port 8080 is listening
- [ ] Run health check:
  ```bash
  bash /opt/streaming-backend/scripts/health_check.sh
  ```
  - [ ] Nginx: PASS
  - [ ] FFmpeg fb-relay: PASS
  - [ ] Watchdog: PASS

---

## ⏱ 1 Hour Before the Event

- [ ] Start OBS and confirm it connects to the relay server
- [ ] Do a 5-minute private test stream to BOTH platforms simultaneously
  - [ ] Check YouTube Studio preview — video and audio confirmed
  - [ ] Check Facebook Live Producer preview — video and audio confirmed
- [ ] Set YouTube event to PUBLIC (or schedule it to go public at start time)
- [ ] Set Facebook Live to PUBLIC or Friends-only per event policy
- [ ] Confirm camera angles, microphone levels, and scene transitions in OBS
- [ ] Brief backup operator: who to call and what to do if stream drops
- [ ] Open monitoring terminals:
  ```bash
  # Terminal 1 — Live Nginx error feed
  sudo tail -f /var/log/nginx/error.log

  # Terminal 2 — FFmpeg relay live feed
  tail -f /opt/streaming-backend/logs/ffmpeg/fb_relay.log

  # Terminal 3 — Watchdog
  tail -f /opt/streaming-backend/logs/watchdog.log
  ```

---

## ⏱ 30 Minutes Before the Event

- [ ] Do NOT change any configuration now
- [ ] Run a final health check:
  ```bash
  bash /opt/streaming-backend/scripts/health_check.sh
  ```
  All green? You're ready.
- [ ] Keep this checklist open for the during-event reference below

---

## 🔴 During the Event — Monitoring

Check these every 15 minutes during the event:

| What to Monitor | How | Expected |
|---|---|---|
| OBS dropped frames indicator | OBS status bar bottom-right | < 1% dropped |
| OBS network indicator | OBS status bar | Green circle |
| YouTube stream health | YouTube Studio → Go Live | "Good" status |
| Facebook stream health | Facebook Live Producer | "Your stream is live" |
| Nginx error log | `tail -f /var/log/nginx/error.log` | No new errors |
| FFmpeg relay log | `tail -f .../fb_relay.log` | No `ERROR` lines |
| Server CPU | `htop` or `top` | < 60% CPU usage |
| Server RAM | `free -h` | > 500 MB free |

---

## 🔴 Emergency Recovery During Live Event

### Scenario 1: OBS disconnects from relay
```
Symptom: OBS shows error, platforms go offline
Action:
1. Wait 10 seconds (OBS auto-reconnect)
2. If not reconnected: click Stop Streaming → Start Streaming in OBS
3. Health check: bash health_check.sh
Expected recovery time: < 30 seconds
```

### Scenario 2: YouTube stream drops but Facebook continues
```
Symptom: YouTube goes offline, Facebook still live
Action:
1. Check if nginx-rtmp is still running: sudo systemctl status nginx-rtmp
2. If Nginx is up, the YouTube push may have dropped:
   sudo nginx -s reload
3. If Nginx is down: sudo systemctl start nginx-rtmp
Expected recovery time: 60–90 seconds
```

### Scenario 3: Facebook stream drops but YouTube continues
```
Symptom: Facebook goes offline, YouTube still live
Action:
1. sudo systemctl restart fb-relay
2. Monitor: tail -f /opt/streaming-backend/logs/ffmpeg/fb_relay.log
Expected recovery time: 15–30 seconds
```

### Scenario 4: Both platforms drop simultaneously
```
Symptom: Both YouTube and Facebook offline
Action:
1. Check OBS — is it still connected?
2. sudo systemctl restart nginx-rtmp
3. sleep 5 && sudo systemctl restart fb-relay
4. If issue persists: bash health_check.sh to diagnose
Expected recovery time: 2–3 minutes
```

### Scenario 5: Relay server crashes completely (laptop/VPS offline)
```
Symptom: Everything offline, cannot SSH into relay
Action:
1. VPS: Check cloud provider dashboard, reboot if needed
2. Laptop: Hard reboot. Services auto-start via systemd on boot.
3. After boot: sudo bash start_relay.sh
4. Reconnect OBS
Expected recovery time: 5–10 minutes
```

---

## ✅ Post-Event Checklist

- [ ] Stop OBS streaming
- [ ] Stop relay: `sudo bash /opt/streaming-backend/scripts/stop_relay.sh`
- [ ] End the YouTube Live event in YouTube Studio
- [ ] End the Facebook Live broadcast in Facebook
- [ ] Archive logs: `cp -r /opt/streaming-backend/logs /opt/streaming-backend/logs_archive_$(date +%Y%m%d)`
- [ ] Rotate stream keys: Reset both YouTube and Facebook stream keys in their dashboards
- [ ] Update `stream_keys.env` and `rtmp.conf` with placeholder values so old keys are not left active
- [ ] Note any issues observed during the event for future improvement

---

## 📋 Quick Reference Card (Print This)

```
RELAY SERVER:   [SERVER_IP]
OBS URL:        rtmp://[SERVER_IP]:1935/live
OBS KEY:        stream

START:    sudo bash /opt/streaming-backend/scripts/start_relay.sh
STOP:     sudo bash /opt/streaming-backend/scripts/stop_relay.sh
HEALTH:   bash /opt/streaming-backend/scripts/health_check.sh

RESTART NGINX:     sudo systemctl restart nginx-rtmp
RESTART FB RELAY:  sudo systemctl restart fb-relay
RESTART WATCHDOG:  sudo systemctl restart watchdog

LOGS:
  Nginx:   sudo tail -f /var/log/nginx/error.log
  FB:      tail -f /opt/streaming-backend/logs/ffmpeg/fb_relay.log
  Watchdog: tail -f /opt/streaming-backend/logs/watchdog.log
```
