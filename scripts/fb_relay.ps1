<#
.SYNOPSIS
  StreamOps — Facebook RTMPS Relay (Windows Edition)
  Replaces fb_relay.sh for native Windows operation.

.DESCRIPTION
  Reads FB_STREAM_KEY from keys\stream_keys.env, then uses FFmpeg to pull
  from the local MediaMTX RTMP path and push to Facebook over RTMPS (TLS 443).

  Called by the Windows Service wrapper (NSSM) or run directly:
    powershell -ExecutionPolicy Bypass -File fb_relay.ps1

.NOTES
  Requires: FFmpeg in PATH or at C:\streaming-backend\bin\ffmpeg.exe
#>

$ErrorActionPreference = "Stop"
$BaseDir  = if ($env:STREAMING_BASE -ne $null) { $env:STREAMING_BASE } else { "C:\streaming-backend" }
$KeysFile = Join-Path $BaseDir "keys\stream_keys.env"
$LogDir   = Join-Path $BaseDir "logs"
$LogFile  = Join-Path $LogDir  "fb_relay.log"

# ── Ensure log directory ──────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ── Load stream keys from env file ───────────────────────────────────────────
if (-not (Test-Path $KeysFile)) {
    Write-Log "ERROR: Keys file not found: $KeysFile"
    Write-Log "Create it via the dashboard Stream Keys tab or copy from the project."
    Start-Sleep -Seconds 3600
    exit 1
}

$fbKey    = ""
$fbRtmps  = "rtmps://live-api-s.facebook.com:443/rtmp/"

foreach ($line in Get-Content $KeysFile) {
    $line = $line.Trim()
    if ($line.StartsWith("#") -or -not $line.Contains("=")) { continue }
    $parts = $line.Split("=", 2)
    $val   = $parts[1].Trim().Trim('"')
    if ($parts[0] -eq "FB_STREAM_KEY") { $fbKey   = $val }
    if ($parts[0] -eq "FB_RTMPS_URL")  { $fbRtmps = $val }
}

if (-not $fbKey -or $fbKey.StartsWith("YOUR_")) {
    Write-Log "NOTICE: FB_STREAM_KEY is not set. Facebook relay disabled."
    Write-Log "Set it via the dashboard → Stream Keys tab, then restart this service."
    Start-Sleep -Seconds 3600
    exit 0
}

$SourceUrl = "rtmp://127.0.0.1:1935/live"
$Dest      = "$fbRtmps$fbKey"

Write-Log "Starting Facebook RTMPS relay"
Write-Log "  Source : $SourceUrl"
Write-Log "  Target : ${fbRtmps}[FB_KEY_REDACTED]"

# ── Find ffmpeg ───────────────────────────────────────────────────────────────
$ffmpeg = "ffmpeg"
$local  = Join-Path $BaseDir "bin\ffmpeg.exe"
if (Test-Path $local) { $ffmpeg = $local }

# ── Run FFmpeg relay in a loop (reconnect on failure) ─────────────────────────
while ($true) {
    Write-Log "Connecting to source and starting relay..."
    try {
        & $ffmpeg `
            -loglevel warning `
            -reconnect 1 `
            -reconnect_at_eof 1 `
            -reconnect_streamed 1 `
            -reconnect_delay_max 30 `
            -timeout 10000000 `
            -i $SourceUrl `
            -c copy `
            -f flv `
            -flvflags no_duration_filesize `
            $Dest 2>&1 | ForEach-Object {
                $ts   = Get-Date -Format "HH:mm:ss"
                $line = "[$ts] $_ "
                Write-Host $line
                Add-Content -Path $LogFile -Value $line -Encoding UTF8
            }
    }
    catch {
        Write-Log "FFmpeg exited: $_"
    }

    Write-Log "Relay disconnected — reconnecting in 5 seconds..."
    Start-Sleep -Seconds 5
}
