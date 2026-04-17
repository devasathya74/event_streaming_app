param([switch]$Stop)

$BaseDir    = if ($env:STREAMING_BASE) { $env:STREAMING_BASE } else { 'C:\streaming-backend' }
$BinDir     = "$BaseDir\bin"
$LogDir     = "$BaseDir\logs"
$PidFile    = "$BaseDir\tmp\tunnel.pid"
$UrlFile    = "$BaseDir\tmp\tunnel_url.txt"
$CloudflareExe = "$BinDir\cloudflared.exe"
$CloudflareLog = "$LogDir\tunnel.log"

function OK   { param($m) Write-Host "  OK   $m" -ForegroundColor Green }
function INFO { param($m) Write-Host "  >>   $m" -ForegroundColor Cyan }
function WARN { param($m) Write-Host "  WARN $m" -ForegroundColor Yellow }
function FAIL { param($m) Write-Host "  FAIL $m" -ForegroundColor Red }

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Magenta
Write-Host "  StreamOps -- Cloudflare Public Tunnel" -ForegroundColor Magenta
Write-Host "=====================================================" -ForegroundColor Magenta
Write-Host ""

# ---- Stop mode --------------------------------------------------------------
if ($Stop) {
    $pid2 = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($pid2) {
        Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
        OK "Tunnel stopped (PID $pid2)"
        Remove-Item $PidFile,$UrlFile -Force -ErrorAction SilentlyContinue
    } else {
        Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
        OK "Killed all cloudflared processes"
    }
    exit 0
}

# ---- Download cloudflared ---------------------------------------------------
if (-not (Test-Path $CloudflareExe)) {
    INFO "Downloading cloudflared.exe ..."
    $url = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $CloudflareExe -UseBasicParsing -TimeoutSec 180
        OK "Downloaded: $CloudflareExe"
    } catch {
        FAIL "Download failed: $_"
        Write-Host "  Manual: https://github.com/cloudflare/cloudflared/releases/latest" -ForegroundColor Yellow
        Write-Host "  Save as: $CloudflareExe" -ForegroundColor Yellow
        exit 1
    }
} else {
    OK "cloudflared.exe already present"
}

# ---- Ensure stream-api is running -------------------------------------------
$svc = (Get-Service 'stream-api' -ErrorAction SilentlyContinue).Status
if ($svc -ne 'Running') {
    WARN "stream-api not running -- starting..."
    Start-Service 'stream-api' -ErrorAction SilentlyContinue
    Start-Sleep 3
}
OK "stream-api: Running"

# ---- Kill old tunnel process ------------------------------------------------
Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 1

# ---- Prepare dirs -----------------------------------------------------------
New-Item -ItemType Directory -Path "$BaseDir\tmp" -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir         -Force | Out-Null
if (Test-Path $CloudflareLog) { Remove-Item $CloudflareLog -Force }

# ---- Start tunnel -----------------------------------------------------------
INFO "Starting Cloudflare Quick Tunnel -> localhost:3000 ..."
$proc = Start-Process -FilePath $CloudflareExe `
    -ArgumentList @('tunnel','--url','http://localhost:3000','--no-autoupdate','--logfile',$CloudflareLog,'--loglevel','info') `
    -PassThru -WindowStyle Hidden

$proc.Id | Out-File $PidFile -Encoding ascii
INFO "Tunnel PID: $($proc.Id)  |  Waiting for URL (up to 40s)..."

# ---- Wait for public URL in log ---------------------------------------------
$publicUrl = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep 2
    if (Test-Path $CloudflareLog) {
        $txt = Get-Content $CloudflareLog -Raw -ErrorAction SilentlyContinue
        if ($txt -match 'https://[a-z0-9-]+\.trycloudflare\.com') {
            $publicUrl = $Matches[0]
            break
        }
    }
}

if (-not $publicUrl) {
    WARN "Could not auto-detect public URL. Check log: $CloudflareLog"
    Write-Host ""
    Write-Host "  Tip: look for 'trycloudflare.com' in: $CloudflareLog" -ForegroundColor Yellow
    exit 1
}

# ---- Save and display -------------------------------------------------------
$publicUrl | Out-File $UrlFile -Encoding ascii

Write-Host ""
OK "TUNNEL LIVE!"
Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |   YOUR PUBLIC URLs  (share with anyone worldwide)        |" -ForegroundColor Green
Write-Host "  +----------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |                                                          |" -ForegroundColor Green
Write-Host "  |  Dashboard (admin):                                      |" -ForegroundColor Green
Write-Host "       $publicUrl/" -ForegroundColor White
Write-Host "  |                                                          |" -ForegroundColor Green
Write-Host "  |  Public Viewer  <-- SHARE THIS with your audience:      |" -ForegroundColor Cyan
Write-Host "       $publicUrl/watch/" -ForegroundColor Cyan
Write-Host "  |                                                          |" -ForegroundColor Green
Write-Host "  |  HLS Stream (VLC / embed):                              |" -ForegroundColor Yellow
Write-Host "       $publicUrl/hls-proxy/live/mystream/index.m3u8" -ForegroundColor Yellow
Write-Host "  |                                                          |" -ForegroundColor Green
Write-Host "  +----------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "  NOTE: URL changes every restart. For a permanent free URL:" -ForegroundColor DarkGray
Write-Host "  Sign up at https://dash.cloudflare.com -> Zero Trust -> Tunnels" -ForegroundColor DarkGray
Write-Host ""

try { "$publicUrl/watch/" | Set-Clipboard; OK "Viewer URL copied to clipboard!" } catch {}

Write-Host "  Tunnel log: $CloudflareLog" -ForegroundColor DarkGray
Write-Host "  To stop: powershell -File setup_tunnel.ps1 -Stop" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Press Ctrl+C to stop the tunnel." -ForegroundColor Yellow
Write-Host ""

# ---- Keep alive -------------------------------------------------------------
while (-not $proc.HasExited) {
    Start-Sleep 15
}
WARN "Tunnel process exited."
