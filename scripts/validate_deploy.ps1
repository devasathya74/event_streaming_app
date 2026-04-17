<#
.SYNOPSIS  StreamOps — Pre-Event Deployment Validation Script (Windows)
.DESCRIPTION
  Runs a comprehensive pre-fight checklist before any live event.
  Tests services, ports, network connectivity, stream key config,
  and optionally sends a 5-second FFmpeg test stream to verify
  the full RTMP→HLS pipeline end-to-end.

  Usage:
    powershell -ExecutionPolicy Bypass -File validate_deploy.ps1
    powershell -ExecutionPolicy Bypass -File validate_deploy.ps1 -TestStream
#>
param([switch]$TestStream)

$BaseDir = if ($env:STREAMING_BASE -ne $null) { $env:STREAMING_BASE } else { "C:\streaming-backend" }
$BinDir  = "$BaseDir\bin"
$pass = 0; $warn = 0; $fail = 0

function OK($msg)   { Write-Host "  ✔  $msg" -ForegroundColor Green;  $script:pass++ }
function WARN($msg) { Write-Host "  ⚠  $msg" -ForegroundColor Yellow; $script:warn++ }
function FAIL($msg) { Write-Host "  ✘  $msg" -ForegroundColor Red;    $script:fail++ }

Write-Host @"

╔══════════════════════════════════════════════════╗
║  StreamOps — Pre-Event Validation                ║
║  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')                         ║
╚══════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# ── 1. Windows Services ───────────────────────────────────────────────────────
Write-Host "`n[1] Windows Services" -ForegroundColor White
foreach ($svc in @("mediamtx", "stream-api", "stream-clipper", "fb-relay")) {
    $s = (Get-Service $svc -ErrorAction SilentlyContinue).Status
    if ($s -eq "Running") { OK "$svc → Running" }
    else                  { FAIL "$svc → $s  (fix: Start-Service $svc)" }
}

# ── 2. Executable Check ───────────────────────────────────────────────────────
Write-Host "`n[2] Executables" -ForegroundColor White
$exes = @{
    "mediamtx.exe" = "$BinDir\mediamtx.exe"
    "ffmpeg.exe"   = "$BinDir\ffmpeg.exe"
    "ffprobe.exe"  = "$BinDir\ffprobe.exe"
    "nssm.exe"     = "$BinDir\nssm.exe"
}
foreach ($name in $exes.Keys) {
    $ffInPath  = Get-Command $name -ErrorAction SilentlyContinue
    $ffLocal   = Test-Path $exes[$name]
    if ($ffInPath -or $ffLocal) { OK "$name found" }
    else                         { FAIL "$name NOT found — run install_windows.ps1" }
}

# ── 3. Port Bindings ──────────────────────────────────────────────────────────
Write-Host "`n[3] Port Bindings" -ForegroundColor White
$ports = @{
    1935 = "RTMP (OBS ingress)"
    8888 = "HLS (public viewer)"
    3000 = "Management API"
    9997 = "MediaMTX internal API"
}
foreach ($port in $ports.Keys) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($conn) { OK "Port $port open — $($ports[$port])" }
    else        { WARN "Port $port not listening — $($ports[$port])" }
}

# ── 4. Firewall Rules ─────────────────────────────────────────────────────────
Write-Host "`n[4] Firewall Rules" -ForegroundColor White
$fwPorts = @(1935, 8888, 3000)
foreach ($p in $fwPorts) {
    $rule = Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -eq $p } |
            Get-NetFirewallRule |
            Where-Object { $_.Enabled -eq "True" -and $_.Direction -eq "Inbound" }
    if ($rule) { OK "Firewall allows TCP $p inbound" }
    else        { WARN "No inbound firewall rule for TCP $p — OBS may not connect from other machines" }
}

# ── 5. Stream Keys ────────────────────────────────────────────────────────────
Write-Host "`n[5] Stream Keys" -ForegroundColor White
$keysFile = "$BaseDir\keys\stream_keys.env"
if (Test-Path $keysFile) {
    $ytKey = ""; $fbKey = ""
    foreach ($line in Get-Content $keysFile) {
        if ($line -match '^YT_STREAM_KEY="?([^"]+)"?') { $ytKey = $Matches[1] }
        if ($line -match '^FB_STREAM_KEY="?([^"]+)"?') { $fbKey = $Matches[1] }
    }
    if ($ytKey -and $ytKey -notlike "*YOUR_*") { OK "YouTube stream key is set" }
    else { WARN "YouTube stream key not configured — YouTube push disabled" }
    if ($fbKey -and $fbKey -notlike "*YOUR_*") { OK "Facebook stream key is set" }
    else { WARN "Facebook stream key not configured — Facebook push disabled" }
} else {
    FAIL "stream_keys.env not found at $keysFile"
}

# ── 6. API Token ──────────────────────────────────────────────────────────────
Write-Host "`n[6] API Security" -ForegroundColor White
$tokenFile = "$BaseDir\keys\api_token"
if (Test-Path $tokenFile) {
    $tok = Get-Content $tokenFile
    if ($tok.Length -ge 32) { OK "API token exists ($($tok.Length) chars)" }
    else                     { WARN "API token looks short — regenerate by deleting $tokenFile" }
} else {
    WARN "API token file not found — will be auto-created on first server.py launch"
}

# ── 7. Network Connectivity ───────────────────────────────────────────────────
Write-Host "`n[7] Network Connectivity" -ForegroundColor White
$targets = @{
    "YouTube RTMP ingest" = "a.rtmp.youtube.com"
    "Facebook RTMPS"      = "live-api-s.facebook.com"
    "DNS resolution"      = "8.8.8.8"
}
foreach ($name in $targets.Keys) {
    $host_ = $targets[$name]
    $ping  = Test-Connection $host_ -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ping) { OK "$name reachable ($host_)" }
    else        { WARN "$name unreachable — check internet/firewall ($host_)" }
}

# ── 8. Disk Space ─────────────────────────────────────────────────────────────
Write-Host "`n[8] Disk Space" -ForegroundColor White
$drive = (Split-Path $BaseDir -Qualifier)
$disk  = Get-PSDrive -Name ($drive.TrimEnd(":")) -ErrorAction SilentlyContinue
if ($disk) {
    $freeGB = [math]::Round($disk.Free / 1GB, 1)
    if ($freeGB -gt 20)     { OK "Disk free: ${freeGB} GB" }
    elseif ($freeGB -gt 5)  { WARN "Disk free: ${freeGB} GB — recordings may fill up fast" }
    else                     { FAIL "Disk free: ${freeGB} GB — critically low! Clear old recordings." }
}

# ── 9. MediaMTX API health ────────────────────────────────────────────────────
Write-Host "`n[9] MediaMTX API" -ForegroundColor White
try {
    $resp = Invoke-RestMethod "http://127.0.0.1:9997/v3/paths/list" -TimeoutSec 3
    OK "MediaMTX API responding ($(($resp.items).Count) paths)"
} catch {
    WARN "MediaMTX API not responding — is mediamtx service running?"
}

# ── 10. Optional: Live Stream Test ────────────────────────────────────────────
if ($TestStream) {
    Write-Host "`n[10] Live Stream Test (5-second FFmpeg test pattern)" -ForegroundColor White
    $ffmpeg = if (Test-Path "$BinDir\ffmpeg.exe") { "$BinDir\ffmpeg.exe" } else { "ffmpeg" }
    Write-Host "  Sending 5s test pattern to rtmp://127.0.0.1:1935/live..." -ForegroundColor Gray
    $proc = Start-Process $ffmpeg -ArgumentList @(
        "-re", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30",
        "-f", "lavfi", "-i", "sine=frequency=1000",
        "-c:v", "libx264", "-b:v", "1000k", "-preset", "ultrafast",
        "-c:a", "aac", "-b:a", "128k",
        "-f", "flv", "rtmp://127.0.0.1:1935/live"
    ) -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 6
    $proc | Stop-Process -Force -ErrorAction SilentlyContinue

    # Check HLS
    $hls = "$BaseDir\www\hls\live\index.m3u8"
    if (Test-Path $hls) {
        $age = (Get-Date) - (Get-Item $hls).LastWriteTime
        if ($age.TotalSeconds -lt 15) { OK "HLS playlist updated — pipeline working!" }
        else                           { WARN "HLS playlist exists but is old ($([int]$age.TotalSeconds)s)" }
    } else {
        FAIL "HLS playlist not created at $hls — check mediamtx.yml hlsDirectory setting"
    }
}

# ── SUMMARY ───────────────────────────────────────────────────────────────────
Write-Host "`n══ RESULTS ═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✔ PASS: $pass  ⚠ WARN: $warn  ✘ FAIL: $fail" -ForegroundColor White

if ($fail -eq 0 -and $warn -eq 0) {
    Write-Host "`n  🟢 ALL CLEAR — System ready for live broadcast!`n" -ForegroundColor Green
} elseif ($fail -eq 0) {
    Write-Host "`n  🟡 READY WITH WARNINGS — Review warnings above before going live.`n" -ForegroundColor Yellow
} else {
    Write-Host "`n  🔴 NOT READY — Fix failures before attempting to stream.`n" -ForegroundColor Red
}
