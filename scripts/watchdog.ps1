<#
.SYNOPSIS  StreamOps Watchdog — monitors services and auto-restarts on failure
#>
param([int]$IntervalSeconds = 15)

$BaseDir = $env:STREAMING_BASE ?? "C:\streaming-backend"
$LogFile = "$BaseDir\logs\watchdog.log"

function Write-Log($msg) {
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [WATCHDOG] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

$WatchedServices = @("mediamtx", "stream-api", "stream-clipper", "fb-relay")
Write-Log "Watchdog started. Monitoring: $($WatchedServices -join ', ')"

while ($true) {
    foreach ($svc in $WatchedServices) {
        try {
            $status = (Get-Service $svc -ErrorAction Stop).Status
            if ($status -ne "Running") {
                Write-Log "Service '$svc' is $status — restarting..."
                Start-Service $svc -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                $newStatus = (Get-Service $svc -ErrorAction SilentlyContinue).Status
                Write-Log "Service '$svc' restart result: $newStatus"
            }
        }
        catch {
            Write-Log "Could not query service '$svc': $_"
        }
    }
    Start-Sleep -Seconds $IntervalSeconds
}
