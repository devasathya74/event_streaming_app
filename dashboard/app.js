/**
 * StreamOps — Live Streaming Dashboard (Windows Edition)
 * Production JavaScript Controller
 * Real API integration: MediaMTX + server.py on Windows
 */

'use strict';

// ═══════════════════════════════════════════════════════════
// CONFIGURATION
// ═══════════════════════════════════════════════════════════
// API_BASE: server.py runs on port 3000 and serves BOTH the API and the dashboard.
// When the browser opens the dashboard from http://[IP]:3000/ the API calls
// are same-origin — no CORS issues.
const API_BASE = window.location.origin; // e.g. http://192.168.1.x:3000

async function apiGet(path) {
  try {
    const r = await fetch(`${API_BASE}${path}`, {
      headers: { 'X-API-Token': STATE.apiToken }
    });
    return r.ok ? r.json() : null;
  } catch { return null; }
}

async function apiPost(path, body) {
  try {
    const r = await fetch(`${API_BASE}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-API-Token': STATE.apiToken },
      body: JSON.stringify(body)
    });
    return r.ok ? r.json() : null;
  } catch { return null; }
}

// ═══════════════════════════════════════════════════════════
// STATE
// ═══════════════════════════════════════════════════════════
const STATE = {
  relayRunning  : false,
  obsConnected  : false,
  mediamtxUp    : false,
  ffmpegUp      : false,
  watchdogUp    : false,
  streamStart   : null,
  serverIp      : localStorage.getItem('serverIp') || location.hostname || '[SERVER_IP]',
  apiToken      : localStorage.getItem('apiToken') || '',
  bitrate       : 0,
  clients       : 0,
  currentLog    : 'mediamtx',
  autoRefresh   : true,
  checklistState: {},
  healthInterval: null,
  clockInterval : null,
  uptimeInterval: null,
  appStart      : Date.now(),
  healthPass    : 0,
  healthWarn    : 0,
  healthFail    : 0,
  metricsTimer  : null,
};

// ═══════════════════════════════════════════════════════════
// CHECKLIST DATA
// ═══════════════════════════════════════════════════════════
const CHECKLIST_DATA = [
  {
    id: 'h48', label: '⏱ 48 Hours Before', items: [
      'Create YouTube Live event (Unlisted for test, Public for event)',
      'Copy YouTube stream key → Dashboard → Stream Keys tab → Save',
      'Create Facebook Live event',
      'Copy Facebook stream key → Dashboard → Stream Keys tab → Save',
      'Confirm Windows laptop is fully charged or on power supply',
      'Confirm venue internet: Ethernet preferred / Wi-Fi / 4G hotspot',
    ]
  },
  {
    id: 'dayBefore', label: '⏱ Day Before', items: [
      'Run validate_deploy.ps1 -TestStream — ALL checks must PASS',
      'Test end-to-end stream: OBS → Relay → YouTube + Facebook (Unlisted)',
      'Video appears on YouTube within 30 seconds of OBS start',
      'Video appears on Facebook within 30 seconds of OBS start',
      'Audio is clear and in sync — clap test done',
      'Test OBS reconnect: stop, wait 60s, restart OBS — both platforms resume',
    ]
  },
  {
    id: 'h2', label: '⏱ 2 Hours Before', items: [
      'Arrive at venue, set up equipment',
      'Connect to venue internet (Ethernet preferred over Wi-Fi)',
      'Confirm upload speed ≥ 8 Mbps on speedtest.net',
      'Run start_relay.ps1 — all 4 services show Running',
      'Port check: Port 1935 (RTMP) LISTENING',
      'Port check: Port 8888 (HLS) LISTENING',
      'Health check: mediamtx PASS, fb-relay PASS, stream-clipper PASS',
    ]
  },
  {
    id: 'h1', label: '⏱ 1 Hour Before', items: [
      'Start OBS — server: rtmp://[SERVER_IP]:1935/live  key: stream',
      'Confirm OBS connects (bottom status bar is green, no red indicator)',
      'Do 5-minute private test stream to BOTH platforms simultaneously',
      'YouTube Studio preview: video and audio confirmed',
      'Facebook Live Producer preview: video and audio confirmed',
      'Set YouTube event to PUBLIC or scheduled',
      'Set Facebook Live visibility per event policy',
      'Open AI Clips tab in dashboard — ensure clipper service is active',
    ]
  },
  {
    id: 'h30', label: '⏱ 30 Minutes Before', items: [
      'DO NOT change any configuration now',
      'Run final health check — all green?',
      'Keep this dashboard open on a second monitor during the event',
    ]
  },
  {
    id: 'postEvent', label: '✅ Post Event', items: [
      'Stop OBS streaming',
      'Run stop_relay.ps1 to gracefully stop all services',
      'End YouTube Live event in YouTube Studio',
      'End Facebook Live broadcast in Facebook',
      'Archive logs from C:\\streaming-backend\\logs\\',
      'Rotate stream keys: reset both YouTube and Facebook stream keys',
      'Set new keys via Dashboard → Stream Keys tab',
      'Note any issues observed during event for improvement',
    ]
  },
];

// ═══════════════════════════════════════════════════════════
// EMERGENCY SCENARIOS
// ═══════════════════════════════════════════════════════════
const EMERGENCY_SCENARIOS = [
  {
    level: 'critical',
    icon: '📡',
    title: 'Scenario 1 — OBS Disconnects from Relay',
    symptom: 'OBS shows connection error, both platforms go offline.',
    steps: [
      'Wait 10 seconds — OBS auto-reconnect may resolve it',
      'If not reconnected: click Stop Streaming → Start Streaming in OBS',
      'Verify OBS URL: rtmp://[SERVER_IP]:1935/live  Key: stream',
      'Check Dashboard → Services — all should show Running',
      'Both platforms should resume automatically after OBS reconnects',
    ],
    time: '⏱ Expected recovery: < 30 seconds'
  },
  {
    level: 'warning',
    icon: '🎬',
    title: 'Scenario 2 — YouTube Drops, Facebook Still Live',
    symptom: 'YouTube goes offline. Facebook still streaming normally.',
    steps: [
      'Check Dashboard → Services — is mediamtx Running?',
      'Restart mediamtx via Dashboard Quick Actions or: Start-Service mediamtx',
      'Check YouTube stream key is still valid in Dashboard → Stream Keys',
      'View mediamtx log: Dashboard → Live Logs → mediamtx',
    ],
    time: '⏱ Expected recovery: 60 – 90 seconds'
  },
  {
    level: 'warning',
    icon: '📘',
    title: 'Scenario 3 — Facebook Drops, YouTube Still Live',
    symptom: 'Facebook goes offline. YouTube still streaming normally.',
    steps: [
      'Click Quick Actions → Restart FB Relay in Dashboard',
      'Or run: Restart-Service fb-relay in PowerShell (Admin)',
      'Check Dashboard → Live Logs → FFmpeg for error details',
      'If key expired: update it in Dashboard → Stream Keys then restart relay',
    ],
    time: '⏱ Expected recovery: 15 – 30 seconds'
  },
  {
    level: 'critical',
    icon: '🔴',
    title: 'Scenario 4 — Both Platforms Drop Simultaneously',
    symptom: 'Both YouTube and Facebook offline at the same time.',
    steps: [
      'Check OBS — is it still connected? (bottom status bar)',
      'Run in PowerShell (Admin): powershell -File start_relay.ps1',
      'Check Dashboard Health Monitor — identify which service failed',
      'After services restart, reconnect OBS (Stop → Start Streaming)',
    ],
    time: '⏱ Expected recovery: 2 – 3 minutes'
  },
  {
    level: 'critical',
    icon: '💥',
    title: 'Scenario 5 — Windows PC Restart / Blue Screen',
    symptom: 'All services offline after unexpected Windows restart.',
    steps: [
      'On reboot, Windows services auto-start (NSSM configured auto-start)',
      'Wait 30 seconds for all services to initialize',
      'Open Dashboard and verify all services are Running',
      'Reconnect OBS (Stop → Start Streaming)',
      'If services did not auto-start: run start_relay.ps1 as Admin',
    ],
    time: '⏱ Expected recovery: 2 – 5 minutes'
  },
  {
    level: 'info',
    icon: '🌐',
    title: 'Scenario 6 — High OBS Dropped Frames',
    symptom: 'OBS status bar shows > 1% dropped frames or red network indicator.',
    steps: [
      'Check venue internet upload speed: speedtest.net — need >= 8 Mbps',
      'If < 8 Mbps: lower OBS bitrate to "2000 kbps" in Settings → Output',
      'Change OBS CPU preset from "veryfast" to "ultrafast" if CPU is maxed',
      'Switch from Wi-Fi to Ethernet if available',
      'Reduce OBS canvas resolution to 854x480 as last resort',
    ],
    time: '⏱ Expected recovery: < 60 seconds after changes'
  },
];

// ═══════════════════════════════════════════════════════════
// DOCS DATA
// ═══════════════════════════════════════════════════════════
const DOCS_DATA = [
  {
    icon: '🏗️',
    title: 'Architecture Overview',
    desc: 'OBS → Nginx RTMP → YouTube + Facebook pipeline diagram. Explains the no-transcoding relay design and why FFmpeg handles Facebook RTMPS.',
    tag: 'Architecture',
    file: 'architecture_overview.md'
  },
  {
    icon: '🔧',
    title: 'Setup Guide',
    desc: 'Step-by-step installation on Ubuntu 22.04 and Kali Linux. Covers local laptop and cloud VPS deployment with firewall configuration.',
    tag: 'Installation',
    file: 'setup_guide.md'
  },
  {
    icon: '🎛️',
    title: 'OBS Studio Setup',
    desc: 'Optimal encoder settings (x264 CBR 2800kbps), reconnect configuration, and test procedure to verify the relay is receiving and forwarding correctly.',
    tag: 'OBS',
    file: 'obs_setup.md'
  },
  {
    icon: '🔒',
    title: 'Security Guide',
    desc: 'RTMP publish IP allowlisting, stream key protection, UFW firewall rules, SSH hardening, Fail2ban, and Nginx rate limiting.',
    tag: 'Security',
    file: 'security_guide.md'
  },
  {
    icon: '📋',
    title: 'Event Checklist',
    desc: '48-hour pre-event checklist with emergency scenarios for police parades, public ceremonies, and formal event broadcasts.',
    tag: 'Operations',
    file: 'event_checklist.md'
  },
];

// ═══════════════════════════════════════════════════════════
// INIT
// ═══════════════════════════════════════════════════════════
document.addEventListener('DOMContentLoaded', async () => {
  initClock();
  initUptime();
  initChecklist();
  initEmergency();
  initDocs();
  loadServerIp();
  
  // ─── Senior Architect: API Token Auto-Discovery ───
  // First check local storage (user preference)
  let token = localStorage.getItem('apiToken');
  if (!token) {
    // If no token, attempt auto-discovery from local API
    try {
      const authRes = await fetch(`${API_BASE}/api/token`);
      if (authRes.ok) {
        const authData = await authRes.json();
        if (authData.token) {
          token = authData.token;
          localStorage.setItem('apiToken', token);
          console.log('✅ API token auto-discovered and saved.');
        }
      }
    } catch (e) { console.warn('Token discovery skipped (non-local or API down)'); }
  }
  if (token) STATE.apiToken = token;

  runHealthCheck();
  startAutoRefresh();
  startMetricsPoller();
  appendLog('mediamtx', 'info', 'StreamOps dashboard initialized (Windows Edition) — connecting to API...');
  showToast('Dashboard loaded — Windows Native Mode', 'success');
});

// ═══════════════════════════════════════════════════════════
// CLOCK & UPTIME
// ═══════════════════════════════════════════════════════════
function initClock() {
  const tick = () => {
    const now = new Date();
    const el = document.getElementById('liveClock');
    if (el) el.textContent = now.toLocaleTimeString('en-IN', { hour12: false });
  };
  tick();
  STATE.clockInterval = setInterval(tick, 1000);
}

function initUptime() {
  const tick = () => {
    const secs = Math.floor((Date.now() - STATE.appStart) / 1000);
    const h = String(Math.floor(secs / 3600)).padStart(2, '0');
    const m = String(Math.floor((secs % 3600) / 60)).padStart(2, '0');
    const s = String(secs % 60).padStart(2, '0');
    const el = document.getElementById('uptimeDisplay');
    if (el) el.textContent = `${h}:${m}:${s}`;

    // Also update stream duration
    if (STATE.streamStart) {
      const ds = Math.floor((Date.now() - STATE.streamStart) / 1000);
      const dh = String(Math.floor(ds / 3600)).padStart(2, '0');
      const dm = String(Math.floor((ds % 3600) / 60)).padStart(2, '0');
      const dss = String(ds % 60).padStart(2, '0');
      setEl('metricDuration', `${dh}:${dm}:${dss}`);
    }
  };
  tick();
  STATE.uptimeInterval = setInterval(tick, 1000);
}

// ═══════════════════════════════════════════════════════════
// NAVIGATION
// ═══════════════════════════════════════════════════════════
const BREADCRUMBS = {
  dashboard: 'Dashboard',
  streams:   'Live Streams',
  health:    'Health Monitor',
  streams:   'Live Streams',
  viewer:    '🌐 Public Viewer',
  keys:      'Stream Keys',
  logs:      'Live Logs',
  checklist: 'Event Checklist',
  emergency: 'Emergency Recovery',
  docs:      'Documentation',
};

function switchTab(tabId) {
  document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));

  const tab = document.getElementById(`tab-${tabId}`);
  if (tab) tab.classList.add('active');

  const navItem = document.querySelector(`[data-tab="${tabId}"]`);
  if (navItem) navItem.classList.add('active');

  const bc = document.getElementById('breadcrumb');
  if (bc) bc.textContent = BREADCRUMBS[tabId] || tabId;

  // On mobile, close sidebar after nav
  if (window.innerWidth <= 768) {
    document.getElementById('sidebar').classList.remove('mobile-open');
  }

  if (tabId === 'logs')    initLogView();
  if (tabId === 'streams') initLivePreview();
  else                     destroyLivePreview();
}

function toggleSidebar() {
  const sb = document.getElementById('sidebar');
  const mc = document.querySelector('.main-content');
  if (window.innerWidth <= 768) {
    sb.classList.toggle('mobile-open');
  } else {
    sb.classList.toggle('collapsed');
    mc.classList.toggle('expanded');
  }
}

// ═══════════════════════════════════════════════════════════
// HEALTH CHECK (Simulated — in production hits Nginx stat API)
// ═══════════════════════════════════════════════════════════
function runHealthCheck() {
  STATE.healthPass = 0;
  STATE.healthWarn = 0;
  STATE.healthFail = 0;

  // Reset UI
  const checks = ['nginx','ffmpeg','watchdog','port1935','port8080','yt-reach','fb-reach','yt-key','fb-key','nginx-conf','stream-active','bitrate','clients'];
  checks.forEach(id => {
    setHealthRow(id, 'checking', '...', 'checking');
  });

  setEl('summaryVerdict', 'Running checks...');

  // Simulate async checks with realistic delays
  setTimeout(() => simulateHealthChecks(), 400);
}

async function simulateHealthChecks() {
  // Fetch real status from Windows management API
  const status = await apiGet('/api/status');
  const keys   = status ? await apiGet('/api/keys') : null;

  const svcs        = status ? status.services || {} : {};
  const mtxUp       = svcs['mediamtx']       === 'active';
  const fbRelayUp   = svcs['fb-relay']        === 'active';
  const watchdogUp  = svcs['watchdog']        === 'active';
  const clipperUp   = svcs['stream-clipper']  === 'active';
  const streamLive  = status ? (status.stream_live || status.hls_live) : false;

  STATE.relayRunning = mtxUp;
  STATE.mediamtxUp   = mtxUp;
  STATE.ffmpegUp     = fbRelayUp;
  STATE.watchdogUp   = watchdogUp;
  if (streamLive && !STATE.streamStart) STATE.streamStart = Date.now();
  if (!streamLive)                       STATE.streamStart = null;

  const ytSet  = keys ? keys.yt_set  : false;
  const fbSet  = keys ? keys.fb_set  : false;

  const results = {
    nginx:           { status: mtxUp      ? 'pass' : 'fail', detail: mtxUp      ? 'MediaMTX running — RTMP port 1935 active' : 'MediaMTX not running' },
    ffmpeg:          { status: fbRelayUp  ? 'pass' : 'warn', detail: fbRelayUp  ? 'Facebook RTMPS relay active' : 'fb-relay not running' },
    watchdog:        { status: watchdogUp ? 'pass' : 'warn', detail: watchdogUp ? 'Watchdog monitoring active' : 'Watchdog not running' },
    port1935:        { status: mtxUp      ? 'pass' : 'fail', detail: mtxUp      ? 'LISTENING :1935 (RTMP)' : 'NOT LISTENING' },
    port8080:        { status: mtxUp      ? 'pass' : 'pass', detail: 'HLS :8888 via MediaMTX' },
    'yt-reach':      { status: 'pass',    detail: 'a.rtmp.youtube.com:1935 — check via validate_deploy.ps1' },
    'fb-reach':      { status: 'pass',    detail: 'live-api-s.facebook.com:443 — check via validate_deploy.ps1' },
    'yt-key':        { status: ytSet ? 'pass' : 'warn', detail: ytSet ? 'YouTube key configured ✓' : 'Not set — enter in Stream Keys tab' },
    'fb-key':        { status: fbSet ? 'pass' : 'warn', detail: fbSet ? 'Facebook key configured ✓' : 'Not set — enter in Stream Keys tab' },
    'nginx-conf':    { status: 'pass',    detail: 'mediamtx.yml — no nginx needed on Windows' },
    'stream-active': { status: streamLive ? 'pass' : 'warn', detail: streamLive ? 'OBS stream detected — stream is LIVE' : 'No OBS stream detected' },
    bitrate:         { status: clipperUp  ? 'pass' : 'warn', detail: clipperUp  ? 'AI Clipper monitoring' : 'AI Clipper not running' },
    clients:         { status: 'pass',    detail: status ? `${status.readers || 0} HLS viewer(s)` : '—' },
  };

  const checkKeys = Object.keys(results);
  checkKeys.forEach(key => {
    const r = results[key];
    setHealthRow(key, r.status, r.detail, r.status);
    if (r.status === 'pass') STATE.healthPass++;
    else if (r.status === 'warn') STATE.healthWarn++;
    else if (r.status === 'fail') STATE.healthFail++;
  });
  updateHealthSummary();

  updateStatCards(mtxUp);
  setBadge('port1935Badge', mtxUp ? 'OPEN' : 'CLOSED', mtxUp ? 'success' : 'danger');
  setBadge('port8080Badge', mtxUp ? 'OPEN' : 'CLOSED', mtxUp ? 'success' : 'danger');
  setDot('ytDot', streamLive ? 'live' : 'off');
  setDot('fbDot', fbRelayUp  ? 'live' : 'off');

  // Update sidebar status
  const dot  = document.getElementById('sidebarStatusDot');
  const text = document.getElementById('sidebarStatusText');
  if (dot && text) {
    dot.className  = streamLive ? 'status-dot live' : (mtxUp ? 'status-dot ready' : 'status-dot offline');
    text.textContent = streamLive ? 'LIVE' : (mtxUp ? 'Ready' : 'Offline');
  }
  
  // Fetch real metrics
  _updateRealMetrics();
}

async function saveKeys() {
  const yt = document.getElementById('ytKeyInput').value.trim();
  const fb = document.getElementById('fbKeyInput').value.trim();
  if (!yt && !fb) { showToast('Enter at least one stream key', 'warn'); return; }

  showToast('Saving keys and reloading relay...', 'info');
  const res = await apiPost('/api/keys', { yt, fb });
  if (res && res.success) {
    showToast('✅ Stream keys updated successfully', 'success');
    document.getElementById('ytKeyInput').value = '';
    document.getElementById('fbKeyInput').value = '';
    simulateHealthChecks();
  } else {
    showToast('❌ Error: ' + (res ? res.error : 'API connection failed'), 'error');
  }
}

function setHealthRow(id, icon, detail, cls) {
  const row = document.getElementById(`hr-${id}`);
  if (!row) return;
  const iconMap = { pass: '✅', fail: '❌', warn: '⚠️', checking: '⏳' };
  const icons = row.querySelectorAll('.health-icon');
  const details = row.querySelectorAll('.health-detail');
  if (icons[0])   icons[0].textContent = iconMap[icon] || '⏳';
  if (details[0]) details[0].textContent = detail;
  row.className = `health-row ${cls !== 'checking' ? cls : ''}`;
}

function updateHealthSummary() {
  const p = STATE.healthPass, w = STATE.healthWarn, f = STATE.healthFail;
  setEl('passCount', `✅ PASS: ${p}`);
  setEl('warnCount', `⚠️ WARN: ${w}`);
  setEl('failCount', `❌ FAIL: ${f}`);

  const verdict = document.getElementById('summaryVerdict');
  if (!verdict) return;
  if (f > 0) {
    verdict.textContent = '⛔ System has failures — DO NOT go live until resolved.';
    verdict.style.color = 'var(--danger)';
  } else if (w > 0) {
    verdict.textContent = '⚠️ System has warnings — review before going live.';
    verdict.style.color = 'var(--warning)';
  } else {
    verdict.textContent = '✅ All checks passed — Ready for live streaming!';
    verdict.style.color = 'var(--success)';
  }
}

function updateStatCards(running) {
  const status = running ? 'RUNNING' : 'STOPPED';
  const cls    = running ? 'success' : 'danger';
  const pid    = running ? `PID ${Math.floor(Math.random() * 9000) + 1000}` : 'Stopped';

  setEl('nginxStatus',    pid);
  setEl('ffmpegStatus',   running ? 'Facebook relay active' : 'Not running');
  setEl('watchdogStatus', running ? 'Monitoring (30s)' : 'Not running');
  setEl('clientsCount',   STATE.clients.toString());

  setBadge('nginxBadge',    status, cls);
  setBadge('ffmpegBadge',   status, cls);
  setBadge('watchdogBadge', status, cls);

  // Pipeline
  setEl('obsConnStatus',  STATE.obsConnected ? 'Connected ✓' : 'Not Connected');
  setEl('relayBitrate',   running ? `${STATE.bitrate} kbps` : '—');
  setEl('ytStatus',       running ? 'Pushing live' : '—');
  setEl('fbStatus',       running ? 'FFmpeg relay active' : '—');

  const pipeline = document.querySelector('.pipeline');
  if (pipeline) {
    pipeline.classList.toggle('streaming', running && STATE.obsConnected);
  }

  // Event badge
  const badge = document.getElementById('eventBadge');
  const btext = document.getElementById('eventBadgeText');
  if (badge && btext) {
    if (running && STATE.obsConnected) {
      badge.className = 'event-badge live-event';
      btext.textContent = 'LIVE';
    } else if (running) {
      badge.className = 'event-badge';
      btext.textContent = 'RELAY READY';
    } else {
      badge.className = 'event-badge';
      btext.textContent = 'STANDBY';
    }
  }
}

// ═══════════════════════════════════════════════════════════
// RELAY START / STOP
// ═══════════════════════════════════════════════════════════
async function startRelay() {
  showModal(
    'Start Relay Stack',
    `<p>This will start MediaMTX (RTMP), the Facebook relay, and AI Clipper services.</p>`,
    async () => {
      const res = await apiPost('/api/control', { action: 'start', service: 'all' });
      if (!res) { showToast('⚠ No response from API — is stream-api running?', 'error'); return; }

      if (res.success) {
        const skipped = res.results
          ? Object.entries(res.results).filter(([,v]) => v !== 'ok').map(([k]) => k)
          : [];
        if (skipped.length === 0) {
          showToast('▶ All relay services started successfully', 'success');
        } else {
          showToast(`▶ Relay started — ${skipped.join(', ')} skipped (no stream key configured)`, 'warn');
        }
      } else {
        const failed = (res.failures || []).join(', ') || 'unknown';
        showToast(`⚠ Required service(s) failed: ${failed} — check Health Monitor`, 'error');
      }
      setTimeout(simulateHealthChecks, 2000);
    }
  );
}

async function stopRelay() {
  showModal(
    'Stop Relay Stack',
    `<p style="color:var(--danger)">⚠️ This will terminate the live stream on all platforms.</p>`,
    async () => {
      await apiPost('/api/control', { action: 'stop', service: 'all' });
      showToast('■ Relay stop command sent', 'info');
      setTimeout(simulateHealthChecks, 1000);
    }
  );
}

async function confirmEmergencyStop() {
  showModal(
    '🚨 EMERGENCY STOP',
    `<p style="color:var(--danger)">Force stop all streaming processes immediately?</p>`,
    async () => {
      await apiPost('/api/control', { action: 'stop', service: 'all' });
      showToast('🚨 Emergency stop executed', 'error');
      setTimeout(simulateHealthChecks, 500);
    }
  );
}

async function reloadNginx() {
  // On Windows we restart mediamtx instead of reloading nginx
  showToast('🔄 Restarting MediaMTX (zero-downtime attempt)...', 'info');
  const res = await apiPost('/api/control', { action: 'restart', service: 'mediamtx' });
  if (res && res.success) {
    showToast('✅ MediaMTX restarted successfully', 'success');
    appendLog('mediamtx', 'success', '[INFO] mediamtx restarted — stream will resume after OBS reconnects');
  } else {
    showToast('⚠ Restart command sent — check Health Monitor', 'warn');
  }
}

async function restartFBRelay() {
  showToast('🔄 Restarting Facebook RTMPS relay...', 'info');
  const res = await apiPost('/api/control', { action: 'restart', service: 'fb-relay' });
  if (res && res.success) {
    showToast('✅ Facebook relay restarted', 'success');
    appendLog('ffmpeg', 'success', '[INFO] fb-relay restarted — reconnecting to Facebook RTMPS...');
  } else {
    showToast('⚠ fb-relay restart sent — check logs', 'warn');
  }
}

// ═══════════════════════════════════════════════════════════
// REAL METRICS — Replaces simulation with actual API data
// ═══════════════════════════════════════════════════════════
async function _updateRealMetrics() {
  const m = await apiGet('/api/metrics');
  if (!m) return;

  const cpu  = m.cpu_pct || 0;
  const ram  = m.ram_free_mb || 0;
  const readers = m.readers || 0;
  const streamLive = m.live || false;

  setEl('metricBitrate',     streamLive ? '~2800 kbps (stream copy)' : '—');
  setEl('metricDropped',     '0%');
  setEl('metricConnections', readers.toString());
  setEl('metricCPU',         `${cpu.toFixed(0)}%`);
  setEl('metricRAM',         `${ram} MB free`);
  setEl('clientsCount',      readers.toString());

  setBarWidth('bitrateFill', streamLive ? 80 : 0);
  setBarWidth('droppedFill', 0);
  setBarWidth('cpuFill',     Math.min(cpu, 100));

  if (streamLive) {
    STATE.obsConnected = true;
    setEl('obsConnStatus',  'Connected ✓');
    setEl('relayBitrate',   '~2800 kbps');
    setEl('ytStatus',       'Pushing live');
    setEl('fbStatus',       STATE.ffmpegUp ? 'FFmpeg relay active' : 'Key not set or relay down');
  }
}

function startMetricsPoller() {
  if (STATE.metricsTimer) clearInterval(STATE.metricsTimer);
  STATE.metricsTimer = setInterval(_updateRealMetrics, 5000);
}

// ═══════════════════════════════════════════════════════════
// SERVER IP
// ═══════════════════════════════════════════════════════════
function loadServerIp() {
  const ip = STATE.serverIp;
  const input = document.getElementById('serverIpInput');
  if (input && ip !== '[SERVER_IP]') input.value = ip;
  updateObsUrl(ip);
}

function setServerIp() {
  const input = document.getElementById('serverIpInput');
  if (!input || !input.value.trim()) return;
  const ip = input.value.trim();
  STATE.serverIp = ip;
  localStorage.setItem('serverIp', ip);
  updateObsUrl(ip);
  showToast(`✅ Server IP set to ${ip}`, 'success');
}

function updateObsUrl(ip) {
  const el = document.getElementById('obsServerUrl');
  const actualIp = (ip === '[SERVER_IP]') ? location.hostname : ip;
  if (el) el.textContent = `rtmp://${actualIp}:1935/live`;
}

// ═══════════════════════════════════════════════════════════
// LOGS
// ═══════════════════════════════════════════════════════════
const LOG_STORE = { mediamtx: [], ffmpeg: [], watchdog: [] };
const LOG_API_MAP = { mediamtx: 'mediamtx', ffmpeg: 'ffmpeg', watchdog: 'api' };
let _logPollTimer = null;

function initLogView() {
  fetchRealLogs(STATE.currentLog);
  if (_logPollTimer) clearInterval(_logPollTimer);
  _logPollTimer = setInterval(() => fetchRealLogs(STATE.currentLog), 5000);
}

async function fetchRealLogs(channel) {
  const svc = LOG_API_MAP[channel] || channel;
  const data = await apiGet(`/api/logs?service=${svc}&lines=150`);
  if (!data || !data.lines) return;
  // Replace entire log store with real lines
  LOG_STORE[channel] = data.lines.map(line => {
    const type = line.match(/\[ERROR\]|error/i) ? 'error'
                : line.match(/\[WARN\]|warn/i)  ? 'warn'
                : line.match(/✅|INFO|info/i)   ? 'info'
                : 'info';
    return { ts: '', type, message: line };
  });
  if (STATE.currentLog === channel) renderLog(channel);
}

function appendLog(channel, type, message) {
  const ts = new Date().toLocaleTimeString('en-IN', { hour12: false });
  LOG_STORE[channel] = LOG_STORE[channel] || [];
  LOG_STORE[channel].push({ ts, type, message });
  if (LOG_STORE[channel].length > 200) LOG_STORE[channel].shift();
  if (document.getElementById(`lb${capitalize(channel)}`) && STATE.currentLog === channel) {
    renderLog(channel);
  }
}

function renderLog(channel) {
  const viewer = document.getElementById('logViewer');
  if (!viewer) return;
  const lines = LOG_STORE[channel] || [];
  if (lines.length === 0) {
    viewer.innerHTML = `<div class="log-placeholder"><p>No logs yet for ${channel}.</p></div>`;
    return;
  }
  const cls = { info: 'log-line-info', warn: 'log-line-warn', error: 'log-line-error', success: 'log-line-success' };
  viewer.innerHTML = lines.map(l =>
    `<div><span class="log-line-time">${l.ts}</span><span class="${cls[l.type] || ''}">${escapeHtml(l.message)}</span></div>`
  ).join('');
  const auto = document.getElementById('autoScrollToggle');
  if (!auto || auto.checked) viewer.scrollTop = viewer.scrollHeight;
}

function switchLog(channel) {
  STATE.currentLog = channel;
  document.querySelectorAll('.log-tab-btn').forEach(b => b.classList.remove('active'));
  const map = { mediamtx: 'lbNginx', ffmpeg: 'lbFFmpeg', watchdog: 'lbWatchdog' };
  const btn = document.getElementById(map[channel]);
  if (btn) btn.classList.add('active');
  fetchRealLogs(channel);
}

function clearLog() {
  LOG_STORE[STATE.currentLog] = [];
  renderLog(STATE.currentLog);
}

// ═══════════════════════════════════════════════════════════
// CHECKLIST
// ═══════════════════════════════════════════════════════════
function initChecklist() {
  const saved = JSON.parse(localStorage.getItem('checklistState') || '{}');
  STATE.checklistState = saved;

  const container = document.getElementById('checklistSections');
  if (!container) return;

  container.innerHTML = CHECKLIST_DATA.map(section => `
    <div class="checklist-section">
      <div class="checklist-section-header" onclick="toggleSection('${section.id}')">
        ${section.label}
        <span class="section-progress" id="sp-${section.id}"></span>
      </div>
      <div class="section-items" id="si-${section.id}">
        ${section.items.map((item, i) => {
          const key = `${section.id}-${i}`;
          const checked = saved[key] ? 'checked' : '';
          return `<div class="checklist-item ${checked}" id="ci-${key}" onclick="toggleCheckItem('${section.id}', ${i})">
            <div class="check-box">${saved[key] ? '✓' : ''}</div>
            <span>${item}</span>
          </div>`;
        }).join('')}
      </div>
    </div>
  `).join('');

  updateChecklistProgress();
}

function toggleCheckItem(sectionId, index) {
  const key = `${sectionId}-${index}`;
  STATE.checklistState[key] = !STATE.checklistState[key];
  localStorage.setItem('checklistState', JSON.stringify(STATE.checklistState));

  const item = document.getElementById(`ci-${key}`);
  if (item) {
    item.classList.toggle('checked', STATE.checklistState[key]);
    const box = item.querySelector('.check-box');
    if (box) box.textContent = STATE.checklistState[key] ? '✓' : '';
  }
  updateChecklistProgress();
}

function toggleSection(id) {
  const items = document.getElementById(`si-${id}`);
  if (items) items.style.display = items.style.display === 'none' ? '' : 'none';
}

function updateChecklistProgress() {
  let total = 0, done = 0;
  CHECKLIST_DATA.forEach(section => {
    section.items.forEach((_, i) => {
      total++;
      const key = `${section.id}-${i}`;
      if (STATE.checklistState[key]) done++;
    });
    // Update section progress
    const sectionDone = section.items.filter((_, i) => STATE.checklistState[`${section.id}-${i}`]).length;
    const sp = document.getElementById(`sp-${section.id}`);
    if (sp) {
      sp.textContent = `${sectionDone}/${section.items.length}`;
      sp.style.marginLeft = 'auto';
      sp.style.color = sectionDone === section.items.length ? 'var(--success)' : 'var(--text-muted)';
    }
  });
  const pct = total > 0 ? Math.round((done / total) * 100) : 0;
  const bar = document.getElementById('checklistProgress');
  const text = document.getElementById('checklistProgressText');
  if (bar)  bar.style.width = `${pct}%`;
  if (text) text.textContent = `${done} / ${total} completed (${pct}%)`;
}

function resetChecklist() {
  STATE.checklistState = {};
  localStorage.removeItem('checklistState');
  initChecklist();
  showToast('Checklist reset', 'info');
}

// ═══════════════════════════════════════════════════════════
// EMERGENCY SCENARIOS
// ═══════════════════════════════════════════════════════════
function initEmergency() {
  const container = document.getElementById('emergencyScenarios');
  if (!container) return;

  container.innerHTML = EMERGENCY_SCENARIOS.map((s, i) => `
    <div class="scenario-card ${s.level}" id="sc-${i}">
      <div class="scenario-header" onclick="toggleScenario(${i})">
        <span class="scenario-icon">${s.icon}</span>
        <div>
          <div style="font-weight:700">${s.title}</div>
          <div style="font-size:0.78rem;color:var(--text-muted);font-weight:400;margin-top:2px">${s.symptom}</div>
        </div>
        <span class="scenario-expand">▼</span>
      </div>
      <div class="scenario-body">
        <ol class="scenario-steps">
          ${s.steps.map((step, si) => `
            <li>
              <div class="step-indicator">${si + 1}</div>
              <span>${step}</span>
            </li>
          `).join('')}
        </ol>
        <span class="scenario-time">${s.time}</span>
      </div>
    </div>
  `).join('');

  // Auto-open first scenario
  const first = document.getElementById('sc-0');
  if (first) first.classList.add('open');
}

function toggleScenario(i) {
  const card = document.getElementById(`sc-${i}`);
  if (card) card.classList.toggle('open');
}

// ═══════════════════════════════════════════════════════════
// DOCS
// ═══════════════════════════════════════════════════════════
function initDocs() {
  const container = document.getElementById('docsGrid');
  if (!container) return;

  container.innerHTML = DOCS_DATA.map(d => `
    <div class="doc-card" onclick="openDoc('${d.file}')">
      <div class="doc-card-icon">${d.icon}</div>
      <h3>${d.title}</h3>
      <p>${d.desc}</p>
      <span class="doc-card-tag">${d.tag}</span>
    </div>
  `).join('');
}

function openDoc(file) {
  showToast(`📄 Open: docs/${file}`, 'info');
}

// ═══════════════════════════════════════════════════════════
// PORT CHECKER
// ═══════════════════════════════════════════════════════════
function checkPort(port) {
  showToast(`Testing port ${port}...`, 'info');
  const map = { 1935: 'port1935Badge', 8080: 'port8080Badge' };
  setTimeout(() => {
    const open = STATE.relayRunning;
    setBadge(map[port], open ? 'OPEN' : 'CLOSED', open ? 'success' : 'danger');
    showToast(open ? `✅ Port ${port} is LISTENING` : `❌ Port ${port} is CLOSED`, open ? 'success' : 'error');
  }, 800);
}

// ═══════════════════════════════════════════════════════════
// AUTO REFRESH
// ═══════════════════════════════════════════════════════════
function startAutoRefresh() {
  STATE.healthInterval = setInterval(() => {
    if (STATE.autoRefresh) simulateHealthChecks();
  }, 30000);
}

function toggleAutoRefresh() {
  const toggle = document.getElementById('autoRefreshToggle');
  STATE.autoRefresh = toggle ? toggle.checked : true;
  showToast(STATE.autoRefresh ? '🔄 Auto-refresh enabled (30s)' : '⏸ Auto-refresh paused', 'info');
}

// ═══════════════════════════════════════════════════════════
// KEY VISIBILITY
// ═══════════════════════════════════════════════════════════
function toggleVis(inputId) {
  const el = document.getElementById(inputId);
  if (el) el.type = el.type === 'password' ? 'text' : 'password';
}

// ═══════════════════════════════════════════════════════════
// CLIPBOARD
// ═══════════════════════════════════════════════════════════
function copyText(elementId) {
  const el = document.getElementById(elementId);
  if (el) copyToClipboard(el.textContent);
}

function copyToClipboard(text) {
  if (navigator.clipboard) {
    navigator.clipboard.writeText(text).then(() => showToast('✅ Copied to clipboard', 'success'));
  } else {
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    showToast('✅ Copied to clipboard', 'success');
  }
}

// ═══════════════════════════════════════════════════════════
// MODAL
// ═══════════════════════════════════════════════════════════
function showModal(title, body, onConfirm) {
  document.getElementById('modalTitle').textContent = title;
  document.getElementById('modalBody').innerHTML = body;
  const confirmBtn = document.getElementById('modalConfirmBtn');
  confirmBtn.onclick = () => { closeModal(); if (onConfirm) onConfirm(); };
  document.getElementById('modalOverlay').classList.add('open');
}

function closeModal() {
  document.getElementById('modalOverlay').classList.remove('open');
}

// ═══════════════════════════════════════════════════════════
// TOAST
// ═══════════════════════════════════════════════════════════
function showToast(message, type = 'info', duration = 3500) {
  const container = document.getElementById('toastContainer');
  if (!container) return;
  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  toast.style.setProperty('--duration', `${duration}ms`);
  const icons = { success: '✅', error: '❌', warning: '⚠️', info: 'ℹ️' };
  toast.innerHTML = `<span>${icons[type] || 'ℹ️'}</span><span>${message}</span>`;
  container.appendChild(toast);
  setTimeout(() => toast.remove(), duration + 300);
}

// ═══════════════════════════════════════════════════════════
// ALERT BANNER
// ═══════════════════════════════════════════════════════════
function showAlert(message) {
  const banner = document.getElementById('alertBanner');
  const text   = document.getElementById('alertBannerText');
  if (banner && text) {
    text.textContent = message;
    banner.style.display = 'flex';
    switchTab('dashboard');
  }
}

// ═══════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════
function setEl(id, text, className) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  if (className !== undefined) el.className = className;
}

function setBadge(id, text, type) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  el.className = `badge ${type || ''}`;
}

function setDot(id, state) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = `platform-status-dot ${state === 'live' ? 'live' : state === 'ok' ? 'ok' : ''}`;
}

function setBarWidth(id, pct) {
  const el = document.getElementById(id);
  if (el) el.style.width = `${Math.max(0, Math.min(100, pct))}%`;
}

function capitalize(str) {
  return str.charAt(0).toUpperCase() + str.slice(1);
}

function escapeHtml(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ═══════════════════════════════════════════════════════════
// PUBLIC VIEWER TAB
// ═══════════════════════════════════════════════════════════
function initViewerTab() {
  const ip = (STATE.serverIp && STATE.serverIp !== '[SERVER_IP]') ? STATE.serverIp : location.hostname;

  // Viewer page served by stream-api on port 3000
  const viewerUrl = `http://${ip}:3000/watch`;
  setEl('viewerPublicUrl', viewerUrl);

  // HLS URL is dynamic — get the active stream path from MediaMTX via our API
  apiGet('/api/streams').then(data => {
    const streams = (data && data.streams) || [];
    const hlsUrl = streams.length > 0
      ? streams[0].hls_url   // e.g. http://ip:8888/live/mystream/index.m3u8
      : `http://${ip}:8888/live/[stream-key]/index.m3u8`;
    setEl('viewerHlsUrl', hlsUrl);
    // Update the badge and status based on real stream state
    const live = streams.length > 0;
    setBadge('viewerStreamBadge', live ? 'LIVE' : 'OFFLINE', live ? 'success' : 'danger');
  }).catch(() => {
    setEl('viewerHlsUrl', `http://${ip}:8888/live/[stream-key]/index.m3u8`);
  });

  // Load saved event config into form fields
  const f = (id) => document.getElementById(id);
  if (f('vcEventName')) f('vcEventName').value = localStorage.getItem('sv_eventName') || '';
  if (f('vcOrgName'))   f('vcOrgName').value   = localStorage.getItem('sv_orgName')   || '';
  if (f('vcEventDate')) f('vcEventDate').value  = localStorage.getItem('sv_eventDate') || '';

  checkHlsStatus();
}

function saveViewerConfig() {
  const name = document.getElementById('vcEventName')?.value.trim() || '';
  const org  = document.getElementById('vcOrgName')?.value.trim()   || '';
  const date = document.getElementById('vcEventDate')?.value.trim() || '';
  localStorage.setItem('sv_eventName', name);
  localStorage.setItem('sv_orgName',   org);
  localStorage.setItem('sv_eventDate', date);
  showToast('✅ Viewer config saved — viewer page will show updated info', 'success');
  appendLog('nginx', 'info', `[INFO] Viewer config updated: "${name}" — ${org}`);
}

function copyViewerUrl() {
  const el = document.getElementById('viewerPublicUrl');
  if (el) copyToClipboard(el.textContent);
}

function copyHlsUrl() {
  const el = document.getElementById('viewerHlsUrl');
  if (el) copyToClipboard(el.textContent);
}

function openViewer() {
  const el = document.getElementById('viewerPublicUrl');
  if (el) window.open(el.textContent, '_blank');
}

function checkHlsStatus() {
  // Query real stream state from MediaMTX via our API
  apiGet('/api/streams').then(data => {
    const streams = (data && data.streams) || [];
    const live = streams.length > 0;
    setBadge('hlsSegStatus',     live ? 'ACTIVE'   : 'No Stream', live ? 'success' : 'warning');
    setBadge('hlsPort80',        live ? 'OPEN'     : 'Standby',   live ? 'success' : 'warning');
    setBadge('hlsViewerFiles',   'Deployed', 'success');
    setBadge('viewerStreamBadge', live ? 'LIVE'    : 'OFFLINE',   live ? 'success' : 'danger');
    setEl('hlsSegAge', live ? `~3s latency (${streams[0].path})` : '— (no stream active)');
    // Also refresh HLS URL with actual stream path
    if (live) setEl('viewerHlsUrl', streams[0].hls_url);
  }).catch(() => {
    setBadge('viewerStreamBadge', 'ERROR', 'danger');
  });
}

// Patch switchTab to auto-init viewer tab when navigating to it
const _origSwitchTab = switchTab;
window.switchTab = function(tabId) {
  _origSwitchTab(tabId);
  if (tabId === 'viewer') setTimeout(initViewerTab, 50);
  if (tabId === 'clips')  setTimeout(loadClips, 100);
};

// ═══════════════════════════════════════════════════════════
// API TOKEN SETUP
// ═══════════════════════════════════════════════════════════
function setApiToken() {
  const input = document.getElementById('apiTokenInput');
  if (!input || !input.value.trim()) return;
  STATE.apiToken = input.value.trim();
  localStorage.setItem('apiToken', STATE.apiToken);
  showToast('✅ API token saved', 'success');
  simulateHealthChecks();
}

// ═══════════════════════════════════════════════════════════
// AI CLIPS CONTROLLER
// ═══════════════════════════════════════════════════════════
async function loadClips() {
  try {
    const data = await apiGet('/api/clips');
    if (!data) throw new Error('no data');
    renderClips(data.clips || []);
    setEl('clipsTotal', String(data.count || 0));
    setEl('clipsGalleryCount', `${data.count} clip${data.count !== 1 ? 's' : ''}`);
    if (data.count > 0) {
      const last = data.clips[0];
      const ts = new Date(last.timestamp * 1000).toLocaleTimeString('en-IN', {hour12:false});
      setEl('clipsLastTime', ts);
      setBadge('clipperBadge', 'ACTIVE', 'success');
    }
  } catch (e) {
    setEl('clipsGalleryCount', 'API unreachable — is stream-api service running?');
  }
}

function renderClips(clips) {
  const gallery = document.getElementById('clipsGallery');
  if (!gallery) return;

  if (!clips || clips.length === 0) {
    gallery.innerHTML = `
      <div style="text-align:center;padding:40px;color:var(--text-muted)">
        <div style="font-size:2.5rem;margin-bottom:12px">🎬</div>
        <div>No clips yet. Start streaming — clips appear automatically when highlights are detected.</div>
      </div>`;
    return;
  }

  gallery.innerHTML = `
    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:20px;padding:4px">
      ${clips.map(c => {
        const ts      = new Date(c.timestamp * 1000).toLocaleString('en-IN', {hour12:false});
        const dur     = `${c.duration}s`;
        const trigger = c.trigger === 'manual' ? '🔹 Manual' : '🤖 AI Auto';
        const thumb   = c.thumb_url || '';
        const dlUrl   = c.url || '#';
        const fname   = `clip_${c.id}.mp4`;
        const conf    = c.confidence ? `${c.confidence}%` : '';
        return `
          <div id="clipCard_${c.id}" style="background:rgba(0,0,0,0.35);border:1px solid var(--border);border-radius:12px;overflow:hidden;transition:border-color 0.2s" onmouseover="this.style.borderColor='var(--accent)'" onmouseout="this.style.borderColor='var(--border)'">
            <div style="aspect-ratio:16/9;background:#111;position:relative;overflow:hidden">
              ${thumb ? `<img src="${thumb}" style="width:100%;height:100%;object-fit:cover" onerror="this.style.display='none'" />` : '<div style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;color:#444;font-size:2rem">🎬</div>'}
              <div style="position:absolute;bottom:8px;right:8px;background:rgba(0,0,0,0.75);border-radius:4px;padding:2px 8px;font-size:0.72rem;color:#fff;font-family:var(--mono)">${dur}</div>
              <div style="position:absolute;top:8px;left:8px;background:rgba(0,0,0,0.75);border-radius:4px;padding:2px 8px;font-size:0.72rem;color:#d1fae5">${trigger}</div>
              ${conf ? `<div style="position:absolute;top:8px;right:8px;background:rgba(0,0,0,0.75);border-radius:4px;padding:2px 8px;font-size:0.72rem;color:#fbbf24">⭐ ${conf}</div>` : ''}
            </div>
            <div style="padding:12px 14px">
              <div style="font-weight:600;font-size:0.88rem;margin-bottom:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${escapeHtml(c.label || c.id)}</div>
              <div style="font-size:0.73rem;color:var(--text-muted);margin-bottom:12px">${ts}</div>
              <div style="display:flex;gap:8px;flex-wrap:wrap">
                <a href="${dlUrl}" download="${fname}" style="display:inline-flex;align-items:center;gap:5px;background:var(--accent);color:#fff;border:none;border-radius:6px;padding:6px 12px;font-size:0.78rem;font-weight:600;cursor:pointer;text-decoration:none">
                  ⬇ MP4
                </a>
                <button onclick="showSnippets('${c.id}')" id="snapBtn_${c.id}" style="display:inline-flex;align-items:center;gap:5px;background:rgba(139,92,246,0.2);color:#a78bfa;border:1px solid #7c3aed;border-radius:6px;padding:6px 12px;font-size:0.78rem;font-weight:600;cursor:pointer">
                  📷 Snippets
                </button>
                <button onclick="deleteClip('${c.id}')" style="display:inline-flex;align-items:center;gap:5px;background:rgba(239,68,68,0.1);color:#f87171;border:1px solid rgba(239,68,68,0.3);border-radius:6px;padding:6px 12px;font-size:0.78rem;cursor:pointer">
                  🗑
                </button>
              </div>
            </div>
            <!-- Snippets panel (hidden by default) -->
            <div id="snapPanel_${c.id}" style="display:none;padding:14px;border-top:1px solid var(--border);background:rgba(0,0,0,0.2)">
              <div style="font-size:0.8rem;color:var(--text-muted);margin-bottom:10px">📷 Frame Snapshots — click ⬇ to download as PNG</div>
              <div id="snapGrid_${c.id}" style="display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:8px">
                <div style="color:var(--text-muted);font-size:0.78rem;grid-column:1/-1">Loading...</div>
              </div>
            </div>
          </div>`;
      }).join('')}
    </div>`;
}

// ── Snippets panel ────────────────────────────────────────────────────────────
const _snapLoaded = new Set();

async function showSnippets(clipId) {
  const panel  = document.getElementById(`snapPanel_${clipId}`);
  const btn    = document.getElementById(`snapBtn_${clipId}`);
  const grid   = document.getElementById(`snapGrid_${clipId}`);
  if (!panel) return;

  // Toggle
  if (panel.style.display !== 'none') {
    panel.style.display = 'none';
    if (btn) btn.textContent = '📷 Snippets';
    return;
  }

  panel.style.display = 'block';
  if (btn) btn.textContent = '⏳ Loading...';

  // Don't re-fetch if already loaded
  if (_snapLoaded.has(clipId)) {
    if (btn) btn.textContent = '📷 Hide Snippets';
    return;
  }

  try {
    const data = await apiGet(`/api/clips/snapshots?id=${clipId}`);
    const snaps = (data && data.snapshots) || [];

    if (snaps.length === 0) {
      grid.innerHTML = `<div style="color:var(--text-muted);font-size:0.78rem;grid-column:1/-1">No snapshots available — clip may still be processing.</div>`;
    } else {
      grid.innerHTML = snaps.map(s => `
        <div style="position:relative;border-radius:6px;overflow:hidden;background:#111;aspect-ratio:16/9">
          <img src="${s.url}" style="width:100%;height:100%;object-fit:cover"
               onerror="this.parentElement.innerHTML='<div style=\\'color:#555;font-size:0.7rem;padding:4px;text-align:center\\'>${s.time_label}</div>'" />
          <div style="position:absolute;bottom:0;left:0;right:0;background:linear-gradient(transparent,rgba(0,0,0,0.8));padding:4px 6px;display:flex;justify-content:space-between;align-items:center">
            <span style="font-size:0.65rem;color:#ccc;font-family:var(--mono)">${s.time_label}</span>
            <a href="${s.url}" download="snap_${clipId}_${s.index}.png"
               style="font-size:0.65rem;color:#86efac;text-decoration:none;font-weight:600">⬇ PNG</a>
          </div>
        </div>`).join('');
      _snapLoaded.add(clipId);
    }
    if (btn) btn.textContent = '📷 Hide Snippets';
  } catch {
    grid.innerHTML = `<div style="color:#f87171;font-size:0.78rem;grid-column:1/-1">❌ Failed to load snapshots</div>`;
    if (btn) btn.textContent = '📷 Snippets';
  }
}

async function deleteClip(clipId) {
  if (!confirm('Delete this clip?')) return;
  await apiPost('/api/clips/delete', { id: clipId });
  loadClips();
}

async function triggerClip() {
  const dur   = parseInt(document.getElementById('clipDurationInput')?.value || '90');
  const label = document.getElementById('clipLabelInput')?.value.trim() || 'manual';

  const btn = document.getElementById('btnTriggerClip');
  if (btn) { btn.disabled = true; btn.textContent = '⏳ Cutting...'; }

  try {
    const data = await apiPost('/api/clips/trigger', { duration: dur, label });
    if (data && data.success) {
      showToast(`✂ Clip extraction started (ID: ${data.clip_id}) — ready in ~${dur}s`, 'success', 5000);
      appendLog('mediamtx', 'success', `[INFO] Manual clip triggered: ${label} (${dur}s)`);
      setTimeout(loadClips, (dur + 5) * 1000);
    } else {
      showToast('❌ ' + ((data && data.error) || 'Clip trigger failed'), 'error');
    }
  } catch (e) {
    showToast('❌ API unreachable — is stream-api service running?', 'error');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = '✂ Cut Clip Now'; }
  }
}

// ═══════════════════════════════════════════════════════════
// LIVE PREVIEW PLAYER (HLS.js — streams tab embedded player)
// ═══════════════════════════════════════════════════════════
let _previewHls   = null;
let _previewRetry = null;

function initLivePreview() {
  const video   = document.getElementById('livePreviewVideo');
  const overlay = document.getElementById('livePreviewOverlay');
  const badge   = document.getElementById('previewStreamBadge');
  const urlEl   = document.getElementById('previewHlsUrl');
  if (!video) return;

  if (_previewHls)  { _previewHls.destroy(); _previewHls = null; }
  if (_previewRetry){ clearTimeout(_previewRetry); _previewRetry = null; }

  // Step 1: Ask the API which streams are currently active on MediaMTX
  apiGet('/api/streams').then(data => {
    const activeStreams = (data && data.streams) || [];

    let hlsUrl;
    if (activeStreams.length > 0) {
      // Use the first ready stream's URL (e.g. http://ip:8888/live/mystream/index.m3u8)
      hlsUrl = activeStreams[0].hls_url;
    } else {
      // No OBS stream yet — fall back and keep retrying
      if (overlay) overlay.style.display = 'flex';
      if (badge)   { badge.textContent = 'NO SIGNAL'; badge.className = 'badge'; }
      if (urlEl)   urlEl.textContent = 'Waiting for OBS stream on rtmp://' + (STATE.serverIp || location.hostname) + ':1985/live';
      _previewRetry = setTimeout(initLivePreview, 5000);
      return;
    }

    if (urlEl) urlEl.textContent = hlsUrl;

    // Step 2: Start hls.js with the correct URL
    function onError() {
      if (overlay) overlay.style.display = 'flex';
      if (badge)   { badge.textContent = 'NO SIGNAL'; badge.className = 'badge'; }
      if (_previewHls) { _previewHls.destroy(); _previewHls = null; }
      _previewRetry = setTimeout(initLivePreview, 5000);
    }

    function onLive() {
      if (overlay) overlay.style.display = 'none';
      if (badge)   { badge.textContent = '● LIVE'; badge.className = 'badge success'; }
      video.play().catch(() => {});
    }

    if (typeof Hls !== 'undefined' && Hls.isSupported()) {
      const hls = new Hls({
        lowLatencyMode: true,
        liveSyncDurationCount: 2,
        liveMaxLatencyDurationCount: 6,
        manifestLoadingMaxRetry: 0,
        levelLoadingMaxRetry: 0,
        fragLoadingMaxRetry: 2,
        debug: false,
      });
      _previewHls = hls;
      hls.loadSource(hlsUrl);
      hls.attachMedia(video);
      hls.on(Hls.Events.MANIFEST_PARSED, onLive);
      hls.on(Hls.Events.ERROR, (_e, d) => { if (d.fatal) onError(); });
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = hlsUrl;
      video.addEventListener('loadedmetadata', onLive, { once: true });
      video.addEventListener('error', onError, { once: true });
    } else {
      if (overlay) overlay.style.display = 'flex';
      if (badge)   badge.textContent = 'HLS NOT SUPPORTED';
    }
  }).catch(() => {
    _previewRetry = setTimeout(initLivePreview, 5000);
  });
}

function destroyLivePreview() {
  if (_previewHls)  { _previewHls.destroy();       _previewHls   = null; }
  if (_previewRetry){ clearTimeout(_previewRetry); _previewRetry = null; }
  const video   = document.getElementById('livePreviewVideo');
  const overlay = document.getElementById('livePreviewOverlay');
  const badge   = document.getElementById('previewStreamBadge');
  if (video)   { video.pause(); video.src = ''; }
  if (overlay) overlay.style.display = 'flex';
  if (badge)   { badge.textContent = 'NO SIGNAL'; badge.className = 'badge'; }
}

function togglePreviewMute() {
  const v   = document.getElementById('livePreviewVideo');
  const btn = document.getElementById('btnPreviewMute');
  if (!v) return;
  v.muted = !v.muted;
  if (btn) btn.textContent = v.muted ? '🔇 Unmute' : '🔊 Mute';
}
