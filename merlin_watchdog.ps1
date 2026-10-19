<#
.SYNOPSIS
    Merlin Cluster 24/7 Headless Watchdog (Auto-Heal for .222, Home 100.90.211.9:8090, and .218)
.DESCRIPTION
    Runs completely hidden in the background via conhost.exe --headless every 5 minutes.
    Ensures all services on 192.168.2.222 (OFICINA / DEVQB), 100.90.211.9:8090 (Brain Portal Home),
    and 192.168.2.218 (DESARROLLO) remain running automatically.
#>
$ErrorActionPreference = 'SilentlyContinue'
$merlinDir = $PSScriptRoot
$logFile = Join-Path $merlinDir "merlin_watchdog.log"

function Write-WatchdogLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logFile -Value "[$ts] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
}

# Rotate log if > 1 MB
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    $lines = Get-Content $logFile -Tail 500 -ErrorAction SilentlyContinue
    $lines | Set-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
}

# 1. Ensure all 192.168.2.222 services are running (idempotent - only starts stopped ports)
$script222 = Join-Path $merlinDir "start_all_services_222.ps1"
if (Test-Path $script222) {
    $out222 = & $script222 2>&1
    $started222 = $out222 | Where-Object { $_ -match '\[START\]' }
    if ($started222) {
        foreach ($line in $started222) {
            Write-WatchdogLog "222 Auto-Heal: $($line.ToString().Trim())"
        }
    }
}

# 2. Ensure Home (100.90.211.9:8090 - Brain Portal) is running
$localIPs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
$isLocalHome = ($localIPs -contains "100.90.211.9") -or ($env:COMPUTERNAME -eq "DESKTOP-874GS44")

function Test-TcpPortQuick {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 900)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) {
            $client.EndConnect($iar)
            return $true
        }
    } catch {} finally {
        $client.Close()
        $client.Dispose()
    }
    return $false
}

$home8090Up = Test-TcpPortQuick -TargetHost "100.90.211.9" -Port 8090 -TimeoutMs 1000
if (-not $home8090Up) {
    if ($isLocalHome) {
        $portalDir = "C:\Users\Admin\Desktop\agentes\portal"
        if (-not (Test-Path $portalDir)) { $portalDir = "C:\Users\CarlosAlbertoAcevesC\Desktop\agentes\portal" }
        if (Test-Path $portalDir) {
            $si = ([wmiclass]"Win32_ProcessStartup").CreateInstance()
            $si.ShowWindow = [uint16]0
            $cmdLine = 'cmd.exe /c "python -m uvicorn main:app --host 0.0.0.0 --port 8090"'
            $null = ([wmiclass]"Win32_Process").Create($cmdLine, $portalDir, $si)
            Write-WatchdogLog "Home Auto-Heal (Local): Started Brain Portal on :8090"
        }
    } else {
        # Remote wake via SSH if port 22 is open on 100.90.211.9
        if (Test-TcpPortQuick -TargetHost "100.90.211.9" -Port 22 -TimeoutMs 1000) {
            $remoteCmd = "powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command `"if (-not (Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue)) { `$si = ([wmiclass]'Win32_ProcessStartup').CreateInstance(); `$si.ShowWindow = [uint16]0; ([wmiclass]'Win32_Process').Create('cmd.exe /c python -m uvicorn main:app --host 0.0.0.0 --port 8090', 'C:\Users\Admin\Desktop\agentes\portal', `$si) | Out-Null }`""
            $null = & ssh -o ConnectTimeout=3 -o BatchMode=yes Admin@100.90.211.9 $remoteCmd 2>&1
            Write-WatchdogLog "Home Auto-Heal (SSH): Triggered Brain Portal on 100.90.211.9:8090"
        }
    }
}

# 3. Ensure 192.168.2.218 critical services remain up (check :3000 Agent Swarm / :8090 Brain Portal)
if (-not (Test-TcpPortQuick -TargetHost "192.168.2.218" -Port 3000 -TimeoutMs 900) -or -not (Test-TcpPortQuick -TargetHost "192.168.2.218" -Port 8090 -TimeoutMs 900)) {
    if (Test-TcpPortQuick -TargetHost "192.168.2.218" -Port 22 -TimeoutMs 900) {
        $null = & ssh -o ConnectTimeout=4 -o BatchMode=yes "QB_DESARROLLO@192.168.2.218" "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\QB_DESARROLLO\Desktop\start_all_services.ps1" 2>&1
        Write-WatchdogLog "218 Auto-Heal (SSH): Triggered start_all_services.ps1 on 192.168.2.218"
    }
}
