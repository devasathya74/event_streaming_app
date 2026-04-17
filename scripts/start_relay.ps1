<#
.SYNOPSIS  StreamOps — Start all services + show status
#>
$BaseDir = $env:STREAMING_BASE ?? "C:\streaming-backend"
Write-Host "`nStarting StreamOps services..." -ForegroundColor Cyan

foreach ($svc in @("mediamtx", "stream-api", "stream-clipper", "fb-relay")) {
    Start-Service $svc -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    $s = (Get-Service $svc -ErrorAction SilentlyContinue).Status
    $icon = if ($s -eq "Running") {"✔"} else {"✘"}
    $color = if ($s -eq "Running") {"Green"} else {"Red"}
    Write-Host "  $icon $svc → $s" -ForegroundColor $color
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notmatch "^169\." } |
       Select-Object -First 1).IPAddress

Write-Host "`n  Dashboard : http://${ip}:3000" -ForegroundColor Yellow
Write-Host "  HLS Feed  : http://${ip}:8888/live" -ForegroundColor Yellow
Write-Host "  OBS URL   : rtmp://${ip}:1935/live  key=stream`n" -ForegroundColor Yellow
