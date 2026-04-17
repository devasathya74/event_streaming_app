# StreamOps Windows Installer
# Run as Administrator: Right-click PowerShell -> Run as Administrator
#
# Uses WinSW (Windows Service Wrapper) from GitHub instead of NSSM.
# WinSW: https://github.com/winsw/winsw
#
# Steps 1-4 are idempotent -- safe to re-run if a previous attempt partially completed.

$ErrorActionPreference = "Stop"

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $isAdmin) {
    Write-Host "ERROR: Run this script as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    pause; exit 1
}

# ==========================================================================
# CONFIGURATION
# ==========================================================================
$BaseDir     = "C:\streaming-backend"
$BinDir      = "$BaseDir\bin"
$ScriptSrc   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptSrc

$MediaMTXVer = "v1.9.3"
$MediaMTXUrl = "https://github.com/bluenviron/mediamtx/releases/download/$MediaMTXVer/mediamtx_${MediaMTXVer}_windows_amd64.zip"
$FFmpegUrl   = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"

# WinSW -- Windows Service Wrapper (GitHub releases, always available)
$WinSWUrl    = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"

# ==========================================================================
# HELPERS
# ==========================================================================
function Write-Step($n, $msg) { Write-Host ""; Write-Host "[$n] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  OK   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  WARN $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "  FAIL $msg" -ForegroundColor Red }

function Download-File($url, $dest) {
    if (Test-Path $dest) {
        Write-OK "Already downloaded: $(Split-Path -Leaf $dest)"
        return
    }
    Write-Host "    Downloading $(Split-Path -Leaf $dest) ..." -NoNewline
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    Write-Host " done" -ForegroundColor Green
}

function Extract-Zip($zip, $dest) {
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}

function Add-ToSystemPath($dir) {
    $cur = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
    if ($cur -notlike "*$dir*") {
        [System.Environment]::SetEnvironmentVariable("PATH", "$cur;$dir", [System.EnvironmentVariableTarget]::Machine)
        $env:PATH = $env:PATH + ";" + $dir
        Write-OK "Added to system PATH: $dir"
    } else {
        Write-OK "Already in PATH: $dir"
    }
}

# Install a Windows service using WinSW
# WinSW requires one copy of winsw.exe per service, named <service>.exe, with a matching <service>.xml
function Install-WinSWService {
    param(
        [string]$SvcName,
        [string]$Executable,
        [string]$Arguments,
        [string]$DisplayName,
        [string]$EnvExtra = ""
    )

    $svcDir = "$BinDir\services"
    New-Item -ItemType Directory -Path $svcDir -Force | Out-Null

    $svcExe = "$svcDir\$SvcName.exe"
    $svcXml = "$svcDir\$SvcName.xml"

    # Each service needs its own copy of winsw.exe renamed to <service>.exe
    Copy-Item "$BinDir\winsw.exe" $svcExe -Force

    # Build env XML block if needed
    $envBlock = ""
    if ($EnvExtra -ne "") {
        foreach ($pair in ($EnvExtra -split " ")) {
            if ($pair -match "^(.+)=(.+)$") {
                $envBlock += "  <env name=`"$($Matches[1])`" value=`"$($Matches[2])`" />`n"
            }
        }
    }

    # Write WinSW XML config (v2.12.0 requires <id>, <name>, <description>, <executable>)
    $xmlContent = @(
        "<service>",
        "  <id>$SvcName</id>",
        "  <name>$DisplayName</name>",
        "  <description>$DisplayName -- StreamOps Windows Service</description>",
        "  <executable>$Executable</executable>",
        "  <arguments>$Arguments</arguments>",
        $envBlock,
        "  <logpath>$BaseDir\logs</logpath>",
        "  <log mode=`"roll-by-size`">",
        "    <sizeThreshold>10485760</sizeThreshold>",
        "    <keepFiles>3</keepFiles>",
        "  </log>",
        "  <onfailure action=`"restart`" delay=`"5 sec`"/>",
        "  <onfailure action=`"restart`" delay=`"10 sec`"/>",
        "  <onfailure action=`"restart`" delay=`"30 sec`"/>",
        "</service>"
    )
    $xmlContent | Set-Content $svcXml -Encoding UTF8

    # Uninstall old instance (ignore errors)
    & $svcExe uninstall 2>$null | Out-Null
    Start-Sleep -Milliseconds 800

    # Install new instance
    & $svcExe install
    Write-OK "Service installed: $SvcName"
}

# ==========================================================================
# HEADER
# ==========================================================================
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Magenta
Write-Host "  StreamOps -- Windows Live Streaming System Installer"               -ForegroundColor Magenta
Write-Host "  OBS -> MediaMTX -> YouTube + Facebook + HLS Viewer"                 -ForegroundColor Magenta
Write-Host "======================================================================" -ForegroundColor Magenta
Write-Host ""

# ==========================================================================
# STEP 1: Directories (idempotent)
# ==========================================================================
Write-Step "1/9" "Creating directory structure"

$dirs = @(
    "$BaseDir\bin",
    "$BaseDir\bin\services",
    "$BaseDir\keys",
    "$BaseDir\logs",
    "$BaseDir\recordings",
    "$BaseDir\clips",
    "$BaseDir\www\hls",
    "$BaseDir\www\clips",
    "$BaseDir\dashboard",
    "$BaseDir\viewer",
    "$BaseDir\mediamtx",
    "$BaseDir\scripts",
    "$BaseDir\tmp",
    "$BaseDir\docs"
)
foreach ($d in $dirs) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
Write-OK "Directories ready under $BaseDir"

# ==========================================================================
# STEP 2: MediaMTX
# ==========================================================================
Write-Step "2/9" "MediaMTX (RTMP Server)"

$mtxZip = "$env:TEMP\mediamtx.zip"
$mtxDir = "$env:TEMP\mediamtx_extract"

Download-File $MediaMTXUrl $mtxZip
if (-not (Test-Path "$BinDir\mediamtx.exe")) {
    Extract-Zip $mtxZip $mtxDir
    $mtxExe = Get-ChildItem $mtxDir -Recurse -Filter "mediamtx.exe" | Select-Object -First 1
    if (-not $mtxExe) { Write-Fail "mediamtx.exe not found in archive"; exit 1 }
    Copy-Item $mtxExe.FullName "$BinDir\mediamtx.exe" -Force
}
Write-OK "MediaMTX: $BinDir\mediamtx.exe"

$srcConf = Join-Path $ProjectRoot "mediamtx\mediamtx.yml"
if (Test-Path $srcConf) {
    Copy-Item $srcConf "$BaseDir\mediamtx\mediamtx.yml" -Force
    Write-OK "mediamtx.yml deployed"
}

# ==========================================================================
# STEP 3: FFmpeg
# ==========================================================================
Write-Step "3/9" "FFmpeg"

$ffZip = "$env:TEMP\ffmpeg.zip"
$ffDir = "$env:TEMP\ffmpeg_extract"

Download-File $FFmpegUrl $ffZip

if (-not (Test-Path "$BinDir\ffmpeg.exe")) {
    Write-Host "    Extracting FFmpeg ..." -NoNewline
    Extract-Zip $ffZip $ffDir
    Write-Host " done" -ForegroundColor Green
    $ffExe = Get-ChildItem $ffDir -Recurse -Filter "ffmpeg.exe"  | Select-Object -First 1
    $fpExe = Get-ChildItem $ffDir -Recurse -Filter "ffprobe.exe" | Select-Object -First 1
    if (-not $ffExe) { Write-Fail "ffmpeg.exe not found"; exit 1 }
    Copy-Item $ffExe.FullName "$BinDir\ffmpeg.exe" -Force
    if ($fpExe) { Copy-Item $fpExe.FullName "$BinDir\ffprobe.exe" -Force }
}
Add-ToSystemPath $BinDir
Write-OK "FFmpeg: $BinDir\ffmpeg.exe"

# ==========================================================================
# STEP 4: Python 3
# ==========================================================================
Write-Step "4/9" "Python 3"

$py = Get-Command python  -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }

if (-not $py) {
    Write-Warn "Python not found -- downloading Python 3.12 ..."
    $pyUrl  = "https://www.python.org/ftp/python/3.12.4/python-3.12.4-amd64.exe"
    $pyInst = "$env:TEMP\python-installer.exe"
    Download-File $pyUrl $pyInst
    Start-Process -FilePath $pyInst -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait
    Write-OK "Python 3 installed"
} else {
    Write-OK "Python: $($py.Source)"
}

Write-Host "    Checking psutil ..." -NoNewline
& pip install psutil --quiet 2>&1 | Out-Null
Write-Host " done" -ForegroundColor Green
Write-OK "psutil ready"

# ==========================================================================
# STEP 5: WinSW (replaces NSSM -- hosted on GitHub, always available)
# ==========================================================================
Write-Step "5/9" "WinSW Service Manager (from GitHub)"

$winswDest = "$BinDir\winsw.exe"
Download-File $WinSWUrl $winswDest
Write-OK "WinSW: $winswDest"

# ==========================================================================
# STEP 6: Deploy project files
# ==========================================================================
Write-Step "6/9" "Deploying project files"

$scriptFiles = @("server.py", "ai_clipper.py", "fb_relay.ps1", "watchdog.ps1")
foreach ($f in $scriptFiles) {
    $src = Join-Path $ScriptSrc $f
    if (Test-Path $src) {
        Copy-Item $src "$BaseDir\scripts\$f" -Force
        Write-OK "Deployed: $f"
    } else {
        Write-Warn "Not found (skipping): $f"
    }
}

if (Test-Path "$ProjectRoot\dashboard") {
    Copy-Item "$ProjectRoot\dashboard\*" "$BaseDir\dashboard\" -Recurse -Force
    Write-OK "Dashboard deployed"
}
if (Test-Path "$ProjectRoot\viewer") {
    Copy-Item "$ProjectRoot\viewer\*" "$BaseDir\viewer\" -Recurse -Force
    Write-OK "Viewer deployed"
}
if (Test-Path "$ProjectRoot\mediamtx\mediamtx.yml") {
    Copy-Item "$ProjectRoot\mediamtx\mediamtx.yml" "$BaseDir\mediamtx\mediamtx.yml" -Force
}

# stream_keys.env (only create if missing)
$keysFile = "$BaseDir\keys\stream_keys.env"
if (-not (Test-Path $keysFile)) {
    $lines = @(
        "# StreamOps Stream Key Configuration",
        "# Set keys via Dashboard -> Stream Keys tab, or edit this file directly.",
        "",
        "YT_STREAM_KEY=YOUR_YOUTUBE_STREAM_KEY_HERE",
        "FB_STREAM_KEY=YOUR_FACEBOOK_STREAM_KEY_HERE",
        "FB_RTMPS_URL=rtmps://live-api-s.facebook.com:443/rtmp/"
    )
    $lines | Set-Content $keysFile -Encoding UTF8
    Write-OK "stream_keys.env created"
} else {
    Write-OK "stream_keys.env already exists (not overwritten)"
}

# Secure keys directory — grant current user, SYSTEM, and Administrators
# (SYSTEM is required because WinSW services run as LocalSystem)
& icacls "$BaseDir\keys" /grant "${env:USERNAME}:(OI)(CI)F" /T /Q 2>$null | Out-Null
& icacls "$BaseDir\keys" /grant "SYSTEM:(OI)(CI)F"          /T /Q 2>$null | Out-Null
& icacls "$BaseDir\keys" /grant "Administrators:(OI)(CI)F"  /T /Q 2>$null | Out-Null
Write-OK "keys\ directory ACL: $env:USERNAME + SYSTEM + Administrators"

Write-OK "All project files deployed"

# ==========================================================================
# STEP 7: Install Windows Services (WinSW)
# ==========================================================================
Write-Step "7/9" "Installing Windows Services (WinSW)"

# Stop and kill any existing StreamOps services/processes before reinstalling
# (prevents file-lock errors when overwriting winsw.exe copies)
Write-Host "    Stopping existing services (if any) ..." -NoNewline
$svcNames = @("mediamtx", "stream-api", "stream-clipper", "fb-relay")
foreach ($s in $svcNames) {
    Stop-Service $s -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}
# Kill any lingering WinSW wrapper processes by name (svc_xxx or service name)
$svcExes = @("mediamtx", "stream-api", "stream-clipper", "fb-relay")
foreach ($s in $svcExes) {
    Get-Process -Name $s -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
# Kill the mediamtx process we started manually earlier (if still running)
Get-Process -Name "mediamtx" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host " done" -ForegroundColor Green


$pythonCmd = "python.exe"
$pyObj = Get-Command python -ErrorAction SilentlyContinue
if ($pyObj) { $pythonCmd = $pyObj.Source }

# Service 1: MediaMTX (RTMP server)
Install-WinSWService `
    -SvcName     "mediamtx" `
    -Executable  "$BinDir\mediamtx.exe" `
    -Arguments   "$BaseDir\mediamtx\mediamtx.yml" `
    -DisplayName "StreamOps RTMP Server (MediaMTX)"

# Service 2: Management API (Python)
Install-WinSWService `
    -SvcName     "stream-api" `
    -Executable  $pythonCmd `
    -Arguments   "$BaseDir\scripts\server.py" `
    -DisplayName "StreamOps Management API" `
    -EnvExtra    "STREAMING_BASE=$BaseDir"

# Service 3: AI Highlight Clipper (Python)
Install-WinSWService `
    -SvcName     "stream-clipper" `
    -Executable  $pythonCmd `
    -Arguments   "$BaseDir\scripts\ai_clipper.py" `
    -DisplayName "StreamOps AI Highlight Clipper" `
    -EnvExtra    "STREAMING_BASE=$BaseDir"

# Service 4: Facebook RTMPS Relay (PowerShell)
$fbArgs = "-ExecutionPolicy Bypass -NonInteractive -File $BaseDir\scripts\fb_relay.ps1"
Install-WinSWService `
    -SvcName     "fb-relay" `
    -Executable  "powershell.exe" `
    -Arguments   $fbArgs `
    -DisplayName "StreamOps Facebook RTMPS Relay" `
    -EnvExtra    "STREAMING_BASE=$BaseDir"

Write-OK "All 4 Windows services installed"

# ==========================================================================
# STEP 8: Windows Firewall
# ==========================================================================
Write-Step "8/9" "Configuring Windows Firewall"

$fwRules = @(
    @{ Name = "StreamOps-RTMP";   Port = 1935; Desc = "MediaMTX RTMP OBS ingest" },
    @{ Name = "StreamOps-HLS";    Port = 8888; Desc = "MediaMTX HLS stream" },
    @{ Name = "StreamOps-WebRTC"; Port = 8889; Desc = "MediaMTX WebRTC" },
    @{ Name = "StreamOps-API";    Port = 3000; Desc = "StreamOps Dashboard API" },
    @{ Name = "StreamOps-MTX";    Port = 9997; Desc = "MediaMTX internal API" }
)
foreach ($r in $fwRules) {
    Remove-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol TCP `
        -LocalPort $r.Port -Action Allow -Description $r.Desc | Out-Null
    Write-OK "Firewall TCP $($r.Port) open -- $($r.Desc)"
}

# ==========================================================================
# STEP 9: Start Services
# ==========================================================================
Write-Step "9/9" "Starting all services"

$svcs = @("mediamtx", "stream-api", "stream-clipper", "fb-relay")
foreach ($svc in $svcs) {
    Start-Service $svc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $st = (Get-Service $svc -ErrorAction SilentlyContinue).Status
    if ($st -eq "Running") {
        Write-OK "$svc -> Running"
    } else {
        Write-Warn "$svc -> $st  (check: $BaseDir\logs\$svc.log)"
    }
}

# ==========================================================================
# DONE
# ==========================================================================
$localIp = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object {
                $_.InterfaceAlias -notlike "*Loopback*" -and
                $_.InterfaceAlias -notlike "*WSL*" -and
                $_.InterfaceAlias -notlike "*vEthernet*" -and
                $_.IPAddress -notmatch "^169\." -and
                $_.IPAddress -notmatch "^172\."
            } |
            Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "  INSTALLATION COMPLETE!" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  OBS SETTINGS:" -ForegroundColor White
Write-Host "    Server    : rtmp://${localIp}:1935/live" -ForegroundColor Yellow
Write-Host "    Stream Key: stream" -ForegroundColor Yellow
Write-Host "    Encoder   : x264  CBR  2800 kbps  Keyframe: 2 sec" -ForegroundColor Gray
Write-Host ""
Write-Host "  OPEN IN BROWSER:" -ForegroundColor White
Write-Host "    Dashboard : http://${localIp}:3000" -ForegroundColor Cyan
Write-Host "    HLS Feed  : http://${localIp}:8888/live" -ForegroundColor Cyan
Write-Host "    Viewer    : http://${localIp}:3000/watch" -ForegroundColor Cyan
Write-Host ""
Write-Host "  API Token file: $BaseDir\keys\api_token" -ForegroundColor White
Write-Host "  (Token is auto-created when stream-api service starts)" -ForegroundColor Gray
Write-Host ""
Write-Host "  NEXT: Open Dashboard, paste API token in sidebar, set stream keys." -ForegroundColor White
Write-Host "======================================================================" -ForegroundColor Green
Write-Host ""

pause
