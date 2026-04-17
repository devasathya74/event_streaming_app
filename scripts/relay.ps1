param([string]$StreamPath = "live/mystream")
$ErrorActionPreference = "SilentlyContinue"
$BaseDir  = if ($env:STREAMING_BASE) { $env:STREAMING_BASE } else { "C:\streaming-backend" }
$LogDir   = Join-Path $BaseDir "logs"
$LogFile  = Join-Path $LogDir "relay.log"
$KeysFile = Join-Path $BaseDir "keys\stream_keys.env"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Level = "INF", [string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$ts][$Level] $Msg" -Encoding UTF8
    Write-Host "[$ts][$Level] $Msg"
}

$ytKey = ""; $fbKey = ""; $fbUrl = "rtmps://live-api-s.facebook.com:443/rtmp/"
if (Test-Path $KeysFile) {
    foreach ($rawline in Get-Content $KeysFile) {
        $l = $rawline.Trim()
        if ($l.StartsWith("#") -or -not $l.Contains("=")) { continue }
        $parts = $l.Split("=", 2)
        $k = $parts[0].Trim()
        $v = $parts[1].Trim().Trim('"').Trim("'")
        if ($k -eq "YT_STREAM_KEY") { $ytKey = $v }
        elseif ($k -eq "FB_STREAM_KEY") { $fbKey = $v }
        elseif ($k -eq "FB_RTMPS_URL")  { $fbUrl = if($v.EndsWith("/")){ $v }else{ "$v/" } }
    }
}

$ffmpeg = "ffmpeg"
$local = Join-Path $BaseDir "bin\ffmpeg.exe"
if (Test-Path $local) { $ffmpeg = $local }

$src = "rtsp://127.0.0.1:8554/$StreamPath"
Write-Log "INF" "=== Relay Starting === src=$src"
Write-Log "INF" "YT key set: $($ytKey.Length -gt 0) | FB key set: $($fbKey.Length -gt 0)"

$retryDelay = 5
$attempt = 0

while ($true) {
    $attempt++
    Write-Log "INF" "Attempt #$attempt"
    if ($attempt -eq 1) { Start-Sleep -Seconds 2 }

    # Common encode args (shared input -> encode once)
    $commonArgs = @(
        "-loglevel", "warning",
        "-rtsp_transport", "tcp",
        "-thread_queue_size", "1024",
        "-i", $src,
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-tune", "zerolatency",
        "-b:v", "2000k",
        "-maxrate", "2500k",
        "-bufsize", "5000k",
        "-force_key_frames", "expr:gte(t,n_forced*2)",
        "-g", "60",
        "-keyint_min", "60",
        "-sc_threshold", "0",
        "-c:a", "aac",
        "-b:a", "128k",
        "-ar", "44100"
    )

    $outputs = @()
    if ($ytKey) { $outputs += @("-f", "flv", "rtmp://a.rtmp.youtube.com/live2/$ytKey") }
    if ($fbKey) { $outputs += @("-f", "flv", "${fbUrl}${fbKey}") }

    if ($outputs.Count -eq 0) {
        Write-Log "ERR" "No stream keys — exit."
        exit 1
    }

    $allArgs = $commonArgs + $outputs
    Write-Log "INF" "Pushing to $($outputs.Count / 2) destination(s)"

    try {
        $proc = Start-Process -FilePath $ffmpeg -ArgumentList $allArgs -NoNewWindow -PassThru `
            -RedirectStandardError (Join-Path $LogDir "relay_ffmpeg.log")
        $proc.WaitForExit()
        Write-Log "WRN" "FFmpeg exited code=$($proc.ExitCode)"
        Get-Content (Join-Path $LogDir "relay_ffmpeg.log") -Tail 5 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Log "WRN" "ffmpeg: $_" }
    } catch {
        Write-Log "ERR" "FFmpeg error: $_"
    }

    Write-Log "INF" "Retry in ${retryDelay}s"
    Start-Sleep -Seconds $retryDelay
    if ($retryDelay -lt 30) { $retryDelay += 5 }
}