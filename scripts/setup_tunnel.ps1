# =============================================================================
# setup_tunnel.ps1 — StreamOps Public Tunnel via Cloudflare
# =============================================================================
# Makes the stream and dashboard publicly accessible worldwide — FREE.
# Uses Cloudflare Quick Tunnel (no account needed).
#
# What it does:
#   1. Downloads cloudflared.exe from Cloudflare (one-time)
#   2. Creates a public HTTPS tunnel: Internet → localhost:3000
#   3. The tunnel covers:
#       https://xxxx.trycloudflare.com/          → Dashboard
#       https://xxxx.trycloudflare.com/watch/    → Public Viewer
#       https://xxxx.trycloudflare.com/hls-proxy/live/<key>/index.m3u8 → HLS Stream
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File setup_tunnel.ps1
#   powershell -ExecutionPolicy Bypass -File setup_tunnel.ps1 -RunAsService
# =============================================================================

param(
    [switch]$RunAsService,
    [switch]$Stop
)

$BaseDir    = if ($env:STREAMING_BASE -ne $null) { $env:STREAMING_BASE } else { "C:\streaming-backend" }
$BinDir     = "$BaseDir\bin"
$LogDir     = "$BaseDir\logs"
$PidFile    = "$BaseDir\tmp\tunnel.pid"
$UrlFile    = "$BaseDir\tmp\tunnel_url.txt"
$CloudflareExe = "$BinDir\cloudflared.exe"
$CloudflareLog = "$LogDir\tunnel.log"

# Colours
function Write-OK   { param($m) Write-Host "  OK   $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "  >>   $m" -ForegroundColor Cyan }
function Write-Warn { param($m) Write-Host "  WARN $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "  FAIL $m" -ForegroundColor Red }

Write-Host ""
Write-Host "======================================================" -ForegroundColor Magenta
Write-Host "  StreamOps — Cloudflare Public Tunnel Setup" -ForegroundColor Magenta
Write-Host "======================================================" -ForegroundColor Magenta
Write-Host ""

# ── Stop existing tunnel ─────────────────────────────────────────────────────
if ($Stop) {
    if (Test-Path $PidFile) {
        $pid = Get-Content $PidFile -ErrorAction SilentlyContinue
        if ($pid) {
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            Write-OK "Tunnel stopped (PID $pid)"
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        Remove-Item $UrlFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Warn "No tunnel PID file found — tunnel may not be running"
        # Try killing by process name anyway
        Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue | Stop-Process -Force
        Write-OK "Killed all cloudflared processes"
    }
    exit 0
}

# ── Download cloudflared if needed ───────────────────────────────────────────
if (-not (Test-Path $CloudflareExe)) {
    Write-Info "Downloading cloudflared.exe from Cloudflare..."
    $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $CloudflareExe -UseBasicParsing -TimeoutSec 120
        Write-OK "Downloaded: $CloudflareExe"
    } catch {
        Write-Fail "Download failed: $_"
        Write-Host ""
        Write-Host "  Manual download: https://github.com/cloudflare/cloudflared/releases/latest" -ForegroundColor Yellow
        Write-Host "  Save as: $CloudflareExe" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-OK "cloudflared.exe already present"
}

# ── Ensure stream-api is running ─────────────────────────────────────────────
$apiSvc = (Get-Service "stream-api" -ErrorAction SilentlyContinue).Status
if ($apiSvc -ne "Running") {
    Write-Warn "stream-api is not running — starting it..."
    Start-Service "stream-api" -ErrorAction SilentlyContinue
    Start-Sleep 3
}

# ── Kill any existing cloudflared tunnel ─────────────────────────────────────
Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 1

# ── Prepare directories ───────────────────────────────────────────────────────
New-Item -ItemType Directory -Path "$BaseDir\tmp" -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir         -Force | Out-Null

# ── Start tunnel ─────────────────────────────────────────────────────────────
Write-Info "Starting Cloudflare Quick Tunnel on port 3000..."
Write-Host ""

$tunnelArgs = @(
    "tunnel",
    "--url", "http://localhost:3000",
    "--no-autoupdate",
    "--logfile", $CloudflareLog,
    "--loglevel", "info"
)

$proc = Start-Process -FilePath $CloudflareExe `
    -ArgumentList $tunnelArgs `
    -PassThru -WindowStyle Hidden

$proc.Id | Out-File $PidFile -Encoding ascii

Write-Info "Tunnel process started (PID $($proc.Id))"
Write-Info "Waiting for tunnel URL..."

# ── Wait for the public URL to appear in the log ─────────────────────────────
$publicUrl = $null
$waited = 0
while ($waited -lt 30 -and -not $publicUrl) {
    Start-Sleep 2
    $waited += 2
    if (Test-Path $CloudflareLog) {
        $log = Get-Content $CloudflareLog -Raw -ErrorAction SilentlyContinue
        if ($log -match "https://[a-z0-9\-]+\.trycloudflare\.com") {
            $publicUrl = $Matches[0]
        }
    }
}

if (-not $publicUrl) {
    # Fallback: try stderr/stdout capture method
    Write-Warn "Could not auto-detect URL from log — check $CloudflareLog"
    Write-Host ""
    Write-Host "  Look for a line like:" -ForegroundColor Yellow
    Write-Host "  'Your quick Tunnel has been created! Visit it at: https://xxxx.trycloudflare.com'" -ForegroundColor Yellow
    exit 1
}

# ── Save public URL ───────────────────────────────────────────────────────────
$publicUrl | Out-File $UrlFile -Encoding ascii
Write-OK "Tunnel is LIVE!"
Write-Host ""

# ── Print the URLs ────────────────────────────────────────────────────────────
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║       YOUR PUBLIC STREAMING URLS (worldwide)         ║" -ForegroundColor Green
Write-Host "  ╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  🌐 Dashboard:                                       ║" -ForegroundColor Green
Write-Host "     $publicUrl/" -ForegroundColor White
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  📺 Public Viewer (share with audience):             ║" -ForegroundColor Green
Write-Host "     $publicUrl/watch/" -ForegroundColor Cyan
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  📡 HLS Stream URL (VLC / embed):                   ║" -ForegroundColor Green
Write-Host "     $publicUrl/hls-proxy/live/mystream/index.m3u8" -ForegroundColor Yellow
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Share this with your audience: $publicUrl/watch/" -ForegroundColor Magenta
Write-Host ""
Write-Host "  NOTE: This URL changes every restart. For a permanent URL," -ForegroundColor DarkGray
Write-Host "  sign up free at https://dash.cloudflare.com and create a Named Tunnel." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To stop the tunnel: powershell -File setup_tunnel.ps1 -Stop" -ForegroundColor DarkGray
Write-Host ""

# ── Copy URL to clipboard ────────────────────────────────────────────────────
try {
    "$publicUrl/watch/" | Set-Clipboard
    Write-OK "Viewer URL copied to clipboard!"
} catch {}

Write-Host "  Tunnel log: $CloudflareLog" -ForegroundColor DarkGray

# Keep running if not launched as service (show tunnel status)
if (-not $RunAsService) {
    Write-Host ""
    Write-Host "  Press Ctrl+C to stop the tunnel." -ForegroundColor Yellow
    Write-Host ""
    # Monitor the process
    while (-not $proc.HasExited) {
        Start-Sleep 10
        # Refresh URL in case it updated
        if (Test-Path $CloudflareLog) {
            $log = Get-Content $CloudflareLog -Raw -ErrorAction SilentlyContinue
            if ($log -match "https://[a-z0-9\-]+\.trycloudflare\.com") {
                $newUrl = $Matches[0]
                if ($newUrl -ne $publicUrl) {
                    $publicUrl = $newUrl
                    $publicUrl | Out-File $UrlFile -Encoding ascii
                    Write-Info "Tunnel URL updated: $publicUrl/watch/"
                }
            }
        }
    }
    Write-Warn "Tunnel process exited."
}
