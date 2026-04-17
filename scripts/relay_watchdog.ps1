# StreamOps Relay Watchdog — polls MediaMTX API, auto-starts relay on OBS connect
param([string]$YoutubeKey = "77p9-8dck-xt71-5sd4-9f3r")

$FFmpeg     = "C:\streaming-backend\bin\ffmpeg-ssl.exe"
$StreamPath = "live/mystream"
$LogFile    = "C:\streaming-backend\logs\relay_watchdog.log"
$FfmpegLog  = "C:\streaming-backend\logs\relay_ffmpeg.log"

function Log([string]$Msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content $LogFile "[$ts] $Msg" -Encoding UTF8
    Write-Host "[$ts] $Msg"
}

function Is-StreamLive {
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:9997/v3/paths/list" -TimeoutSec 3
        return ($r.items | Where-Object { $_.name -eq $StreamPath -and $_.ready }) -ne $null
    } catch { return $false }
}

Log "=== Relay Watchdog Started (YT Key: $($YoutubeKey.Substring(0,4))****) ==="
$relay  = $null
$wasLive = $false

while ($true) {
    $live = Is-StreamLive

    if ($live -and ($relay -eq $null -or $relay.HasExited)) {
        if (-not $wasLive) { Log "OBS stream LIVE on $StreamPath" }
        [System.IO.File]::WriteAllText($FfmpegLog, "", [System.Text.ASCIIEncoding]::new())
        $relay = Start-Process $FFmpeg -ArgumentList @(
            "-loglevel","warning",
            "-i","rtmp://127.0.0.1:1985/$StreamPath",
            "-c:v","copy","-c:a","aac","-b:a","128k","-ar","44100",
            "-f","flv","rtmp://a.rtmp.youtube.com/live2/$YoutubeKey"
        ) -NoNewWindow -PassThru -RedirectStandardError $FfmpegLog
        Log "Relay started PID=$($relay.Id)"
        $wasLive = $true
    } elseif (-not $live -and $wasLive) {
        Log "OBS stopped — killing relay"
        $relay | Stop-Process -Force -EA SilentlyContinue
        $relay = $null; $wasLive = $false
    } elseif ($live -and $relay -ne $null -and $relay.HasExited) {
        Log "Relay crashed (exit=$($relay.ExitCode)) — restarting..."
        $wasLive = $false  # force restart on next loop
    }

    Start-Sleep -Seconds 3
}