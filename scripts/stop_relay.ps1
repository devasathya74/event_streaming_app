<#
.SYNOPSIS  StreamOps — Stop all services gracefully
#>
Write-Host "`nStopping StreamOps services..." -ForegroundColor Yellow
foreach ($svc in @("fb-relay", "stream-clipper", "stream-api", "mediamtx")) {
    Stop-Service $svc -Force -ErrorAction SilentlyContinue
    $s = (Get-Service $svc -ErrorAction SilentlyContinue).Status
    Write-Host "  ■ $svc → $s" -ForegroundColor Gray
}
Write-Host "`nAll services stopped.`n" -ForegroundColor Cyan
