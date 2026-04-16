/**
 * StreamOps Public Viewer — player.js
 * HLS.js powered live stream player with auto-reconnect
 */
'use strict';

// ═══════════════════════════════════════════════════════════
// STATE
// ═══════════════════════════════════════════════════════════
const PLAYER = {
  hls            : null,
  isLive         : false,
  isMuted        : true,        // Start muted (browser autoplay policy)
  statusInterval : null,
  idleTimer      : null,
  retryCount     : 0,
  maxRetries     : 20,
  lastInteraction: Date.now(),
};

// ═══════════════════════════════════════════════════════════
// INIT
// ═══════════════════════════════════════════════════════════
document.addEventListener('DOMContentLoaded', () => {
  applyConfig();
  checkStreamStatus();
  PLAYER.statusInterval = setInterval(checkStreamStatus, STREAM_CONFIG.pollInterval);
  initInteractionHandlers();
});

// ═══════════════════════════════════════════════════════════
// APPLY CONFIG (from dashboard localStorage values)
// ═══════════════════════════════════════════════════════════
function applyConfig() {
  const { eventName, orgName, eventDate } = STREAM_CONFIG;

  // Update page title
  document.getElementById('pageTitle').textContent =
    eventName ? `${eventName} — LIVE` : 'Live Stream';

  // Offline screen
  setEl('offlineTitle',     'Stream Not Live Yet');
  setEl('offlineEventName', eventName || '—');
  setEl('offlineEventDate', eventDate || '—');

  // Player labels
  setEl('playerEventName', eventName || 'Live Broadcast');
  setEl('playerOrg',       orgName   || '');

  // OG meta
  setMeta('og:title', `${eventName} — LIVE`);
}

// ═══════════════════════════════════════════════════════════
// STREAM STATUS CHECK
// ═══════════════════════════════════════════════════════════
async function checkStreamStatus() {
  try {
    const resp = await fetch(STREAM_CONFIG.statusApi + '?t=' + Date.now());

    if (resp.ok) {
      const data = await resp.json();
      const isLive = data.status === 'live';
      handleStatusChange(isLive);
    } else {
      // Fall back to HLS playlist direct check
      fallbackHLSCheck();
    }
  } catch {
    // Network error — try HLS direct
    fallbackHLSCheck();
  }
}

async function fallbackHLSCheck() {
  try {
    const resp = await fetch(STREAM_CONFIG.hlsUrl + '?t=' + Date.now(),
      { method: 'HEAD', cache: 'no-store' });
    handleStatusChange(resp.ok);
  } catch {
    handleStatusChange(false);
  }
}

function handleStatusChange(isLive) {
  if (isLive && !PLAYER.isLive) {
    PLAYER.isLive = true;
    PLAYER.retryCount = 0;
    startPlayer();
  } else if (!isLive && PLAYER.isLive) {
    PLAYER.isLive = false;
    onStreamEnded();
  }

  // Update loading screen → correct screen
  const loadingScreen = document.getElementById('loadingScreen');
  if (loadingScreen.style.display !== 'none') {
    loadingScreen.style.display = 'none';
    show(isLive ? 'playerScreen' : 'offlineScreen');
  }
}

// ═══════════════════════════════════════════════════════════
// HLS PLAYER
// ═══════════════════════════════════════════════════════════
function startPlayer() {
  hide('offlineScreen');
  hide('streamEndedOverlay');
  show('playerScreen');
  show('bufferOverlay');

  const video = document.getElementById('liveVideo');
  video.muted = PLAYER.isMuted;

  if (PLAYER.hls) {
    PLAYER.hls.destroy();
    PLAYER.hls = null;
  }

  if (Hls.isSupported()) {
    const hls = new Hls({
      enableWorker:       true,
      lowLatencyMode:     true,
      liveSyncDurationCount: 3,    // Stay close to live edge
      liveMaxLatencyDurationCount: 10,
      maxBufferLength:    20,
      maxMaxBufferLength: 30,
      // Auto retry on error
      manifestLoadingMaxRetry:    6,
      levelLoadingMaxRetry:       6,
      fragLoadingMaxRetry:        6,
    });

    PLAYER.hls = hls;
    hls.loadSource(STREAM_CONFIG.hlsUrl);
    hls.attachMedia(video);

    hls.on(Hls.Events.MANIFEST_PARSED, () => {
      hide('bufferOverlay');
      video.play().then(() => {
        if (PLAYER.isMuted) show('unmuteOverlay');
      }).catch(() => {
        // Autoplay blocked — show unmute overlay
        show('unmuteOverlay');
      });
    });

    hls.on(Hls.Events.FRAG_CHANGED, (_, data) => {
      hide('bufferOverlay');
      updateLatency(hls);
    });

    hls.on(Hls.Events.ERROR, (_, data) => {
      if (data.fatal) {
        switch (data.type) {
          case Hls.ErrorTypes.NETWORK_ERROR:
            handleNetworkError(hls);
            break;
          case Hls.ErrorTypes.MEDIA_ERROR:
            hls.recoverMediaError();
            break;
          default:
            onStreamEnded();
        }
      }
    });

  } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
    // Safari native HLS support
    video.src = STREAM_CONFIG.hlsUrl;
    video.addEventListener('loadedmetadata', () => {
      hide('bufferOverlay');
      video.play();
    });
  } else {
    showToast('⚠ Your browser does not support HLS. Try Chrome or Safari.');
  }

  // Simulated viewer count (in production, read from nginx stat API)
  simulateViewerCount();
}

function handleNetworkError(hls) {
  PLAYER.retryCount++;
  const delay = Math.min(2000 * PLAYER.retryCount, 15000);

  if (PLAYER.retryCount <= PLAYER.maxRetries) {
    show('bufferOverlay');
    setTimeout(() => {
      if (PLAYER.isLive) hls.startLoad();
    }, delay);
  } else {
    onStreamEnded();
  }
}

function onStreamEnded() {
  PLAYER.isLive = false;
  if (PLAYER.hls) {
    PLAYER.hls.destroy();
    PLAYER.hls = null;
  }
  show('streamEndedOverlay');
}

// ═══════════════════════════════════════════════════════════
// LATENCY
// ═══════════════════════════════════════════════════════════
function updateLatency(hls) {
  const latencyEl = document.getElementById('latencyTag');
  if (!latencyEl || !hls.media) return;
  const latency = hls.latency;
  if (latency !== undefined) latencyEl.textContent = `~${latency.toFixed(1)}s delay`;
}

// ═══════════════════════════════════════════════════════════
// CONTROLS
// ═══════════════════════════════════════════════════════════
function toggleMute() {
  const video = document.getElementById('liveVideo');
  PLAYER.isMuted = !PLAYER.isMuted;
  video.muted = PLAYER.isMuted;
  document.getElementById('muteIconOn').style.display  = PLAYER.isMuted ? 'none'  : '';
  document.getElementById('muteIconOff').style.display = PLAYER.isMuted ? ''      : 'none';
  hide('unmuteOverlay');
}

function unmute() {
  const video = document.getElementById('liveVideo');
  video.muted = false;
  PLAYER.isMuted = false;
  document.getElementById('muteIconOn').style.display  = '';
  document.getElementById('muteIconOff').style.display = 'none';
  hide('unmuteOverlay');
}

function setVolume(val) {
  const video = document.getElementById('liveVideo');
  video.volume = parseFloat(val);
  if (video.volume > 0 && PLAYER.isMuted) {
    unmute();
  }
}

function seekToLive() {
  const video = document.getElementById('liveVideo');
  if (video && video.buffered.length > 0) {
    video.currentTime = video.buffered.end(video.buffered.length - 1);
    showToast('⚡ Jumped to live edge');
  }
}

function toggleFullscreen() {
  const el = document.getElementById('playerScreen');
  const expand  = document.getElementById('fsIconExpand');
  const collapse = document.getElementById('fsIconCollapse');

  if (!document.fullscreenElement) {
    el.requestFullscreen().then(() => {
      expand.style.display  = 'none';
      collapse.style.display = '';
    });
  } else {
    document.exitFullscreen().then(() => {
      expand.style.display   = '';
      collapse.style.display = 'none';
    });
  }
}

// ═══════════════════════════════════════════════════════════
// IDLE / AUTO-HIDE CONTROLS
// ═══════════════════════════════════════════════════════════
function initInteractionHandlers() {
  const events = ['mousemove', 'click', 'touchstart', 'keydown'];
  events.forEach(e => {
    document.addEventListener(e, resetIdle, { passive: true });
  });
  resetIdle();
}

function resetIdle() {
  const screen = document.getElementById('playerScreen');
  if (screen) screen.classList.remove('idle');
  clearTimeout(PLAYER.idleTimer);
  PLAYER.idleTimer = setTimeout(() => {
    const screen = document.getElementById('playerScreen');
    if (screen) screen.classList.add('idle');
  }, 4000);
}

// ═══════════════════════════════════════════════════════════
// VIEWER COUNT (simulated — in production use nginx stat XML)
// ═══════════════════════════════════════════════════════════
function simulateViewerCount() {
  let count = Math.floor(Math.random() * 30) + 5;
  setEl('viewerCountNum', count.toString());
  setInterval(() => {
    count += Math.floor(Math.random() * 5) - 2;
    if (count < 1) count = 1;
    setEl('viewerCountNum', count.toString());
  }, 15000);
}

// ═══════════════════════════════════════════════════════════
// SHARE
// ═══════════════════════════════════════════════════════════
function copyPageUrl() {
  const url = window.location.href;
  if (navigator.clipboard) {
    navigator.clipboard.writeText(url).then(() => showToast('✅ Link copied! Share with anyone.'));
  } else {
    const ta = document.createElement('textarea');
    ta.value = url;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    showToast('✅ Link copied!');
  }
}

// ═══════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════
function show(id) {
  const el = document.getElementById(id);
  if (el) el.style.display = '';
}
function hide(id) {
  const el = document.getElementById(id);
  if (el) el.style.display = 'none';
}
function setEl(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}
function setMeta(prop, content) {
  let el = document.querySelector(`meta[property="${prop}"]`);
  if (el) el.setAttribute('content', content);
}

function showToast(msg) {
  const wrap = document.getElementById('toastWrap');
  const toast = document.createElement('div');
  toast.className = 'toast';
  toast.textContent = msg;
  wrap.appendChild(toast);
  setTimeout(() => toast.remove(), 3200);
}
