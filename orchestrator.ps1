<#
.SYNOPSIS
    Merlin - Development Server Manager (PowerShell Terminal)

.DESCRIPTION
    Interactive terminal dashboard to monitor, start, kill, and restart
    all your development servers from a single PowerShell window.
    Reads project definitions from projects.json.

    Navigation:
        Up/Down arrows  - Select project (instant, no lag)
        Enter           - Open action menu for selected project
        S               - Start selected
        K               - Kill selected
        R               - Restart selected
        L               - View logs
        I               - Show detailed info panel
        X               - Kill ALL servers (including zombies)
        A               - Refresh now
        Q               - Quit

.NOTES
    Author:  Carlos Aceves
    Version: 2.1.0
#>

# --- Configuration -----------------------------------------------------------

$ScriptDir   = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { "C:\Users\Admin\Desktop\Merlin" }
$ConfigFile  = Join-Path $ScriptDir "projects.json"
$LogDir      = Join-Path $ScriptDir "logs"
$RefreshSecs = 4

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (Test-Path "C:\Python314") {
    $env:PATH = "C:\Python314;C:\Python314\Scripts;" + $env:PATH
}

# Disable QuickEdit Mode & Enable ANSI Virtual Terminal Processing (zero-flicker rendering)
try {
    $consoleCode = @"
    using System;
    using System.Runtime.InteropServices;
    public class WinConsole {
        [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    }
"@
    if (-not ([System.Management.Automation.PSTypeName]'WinConsole').Type) {
        Add-Type -TypeDefinition $consoleCode
    }
    $hInHandle = [WinConsole]::GetStdHandle(-10) # STD_INPUT_HANDLE = -10
    [uint32]$inMode = 0
    if ([WinConsole]::GetConsoleMode($hInHandle, [ref]$inMode)) {
        $inMode = $inMode -band (-not 0x0040) # Disable ENABLE_QUICK_EDIT_MODE (0x0040)
        $inMode = $inMode -bor 0x0080         # Enable ENABLE_EXTENDED_FLAGS (0x0080)
        [void][WinConsole]::SetConsoleMode($hInHandle, $inMode)
    }
    $hOutHandle = [WinConsole]::GetStdHandle(-11) # STD_OUTPUT_HANDLE = -11
    [uint32]$outMode = 0
    if ([WinConsole]::GetConsoleMode($hOutHandle, [ref]$outMode)) {
        $outMode = $outMode -bor 0x0004 # ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004)
        [void][WinConsole]::SetConsoleMode($hOutHandle, $outMode)
    }
} catch {}

# --- Safe Console Input Helpers (Prevents PSReadLine & Redirection Exception Hangs) ---

function Test-KeyAvailable {
    try {
        return [Console]::KeyAvailable
    } catch {
        return $false
    }
}

function Read-ConsoleKey {
    param([bool]$Intercept = $true)
    try {
        return [Console]::ReadKey($Intercept)
    } catch {
        return $null
    }
}

# --- Config Loader -----------------------------------------------------------

function Load-Config {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "  ERROR: $ConfigFile not found." -ForegroundColor Red
        exit 1
    }
    $raw = Get-Content $ConfigFile -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Save-Config {
    param($Config)
    $json = $Config | ConvertTo-Json -Depth 10
    Set-Content -Path $ConfigFile -Value $json -Encoding UTF8
}

# --- Process & Multi-Server Helpers ------------------------------------------

$script:ManagedPIDs       = @{}
$script:RemotePortCache   = @{}
$script:RemoteCacheTime   = @{}
$script:ActiveSshScans    = @{}
$script:InitialScanDone   = $false
$script:LocalIPs          = $null
$script:AutoHealEnabled   = $true
$script:AutoHealCooldowns = @{}
$script:LastHealEvent     = ""
$script:LastBufWidth      = 0
$script:LastWinHeight     = 0
$script:LastFrameRows     = 0

$script:LastAllStatuses   = $null

$script:NodeCatalog = @{
    "100.90.211.9"   = @{ Alias = "home";           Label = "HOME (Local)";              LogDir = "C:\Users\Admin\Desktop\Merlin\logs"; LanIp = "100.90.211.9"; TailscaleIp = "100.90.211.9" }
    "127.0.0.1"      = @{ Alias = "home";           Label = "HOME (Local)";              LogDir = "C:\Users\Admin\Desktop\Merlin\logs"; LanIp = "127.0.0.1";    TailscaleIp = "100.90.211.9" }
    "192.168.2.218"  = @{ Alias = "desarrollo";     Label = "192.168.2.218 (Produccion)"; LogDir = "C:\Users\QB_DESARROLLO\Desktop\Merlin\logs"; LanIp = "192.168.2.218"; TailscaleIp = "100.77.199.69" }
    "100.77.199.69"  = @{ Alias = "desarrollo";     Label = "192.168.2.218 (Produccion)"; LogDir = "C:\Users\QB_DESARROLLO\Desktop\Merlin\logs"; LanIp = "192.168.2.218"; TailscaleIp = "100.77.199.69" }
    "192.168.2.222"  = @{ Alias = "office-pc";      Label = "192.168.2.222 (Dev)";       LogDir = "C:\Users\CarlosAlbertoAcevesC\Desktop\02-plataformas-activas\merlin\logs"; LanIp = "192.168.2.222"; TailscaleIp = "100.89.1.27" }
    "100.89.1.27"    = @{ Alias = "office-pc";      Label = "192.168.2.222 (Dev)";       LogDir = "C:\Users\CarlosAlbertoAcevesC\Desktop\02-plataformas-activas\merlin\logs"; LanIp = "192.168.2.222"; TailscaleIp = "100.89.1.27" }
    "192.168.2.237"  = @{ Alias = "serverwebqb-ts"; Label = "WEB-HUB (.237)";            LogDir = "C:\Users\Administrador\.gemini\brain-portal"; LanIp = "192.168.2.237"; TailscaleIp = "100.105.210.35" }
    "100.105.210.35" = @{ Alias = "serverwebqb-ts"; Label = "WEB-HUB (.237)";            LogDir = "C:\Users\Administrador\.gemini\brain-portal"; LanIp = "192.168.2.237"; TailscaleIp = "100.105.210.35" }
    "192.168.2.187"  = @{ Alias = "qb-bd-ts";       Label = "BD-VAULT (.187)";           LogDir = "C:\Users\Administrador\logs"; LanIp = "192.168.2.187"; TailscaleIp = "100.102.18.118" }
    "100.102.18.118" = @{ Alias = "qb-bd-ts";       Label = "BD-VAULT (.187)";           LogDir = "C:\Users\Administrador\logs"; LanIp = "192.168.2.187"; TailscaleIp = "100.102.18.118" }
}

function Get-ProjectNodeLabel {
    param($Project)
    $extIp = $Project.external_ip
    if ($extIp -and $script:NodeCatalog.ContainsKey($extIp)) {
        return $script:NodeCatalog[$extIp].Label
    }
    return "HOME (Local)"
}

function Get-LocalIPSet {
    if ($null -ne $script:LocalIPs) { return $script:LocalIPs }
    $set = @{ "127.0.0.1" = $true; "localhost" = $true; "0.0.0.0" = $true }
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($ip in $ips) {
            if ($ip.IPAddress) {
                if ($env:COMPUTERNAME -eq "DESKTOP-874GS44" -and $ip.IPAddress -like "192.168.2.*") { continue }
                $set[$ip.IPAddress] = $true
            }
        }
    } catch {}
    $script:LocalIPs = $set
    return $set
}

function Resolve-ReachableIp {
    param([string]$Ip)
    if (-not $Ip) { return "localhost" }
    $localSet = Get-LocalIPSet
    if ($localSet.ContainsKey($Ip)) { return "localhost" }
    if ($script:NodeCatalog.ContainsKey($Ip)) {
        $entry = $script:NodeCatalog[$Ip]
        if ($entry.TailscaleIp -and $localSet.ContainsKey($entry.TailscaleIp)) { return "localhost" }
        if ($entry.LanIp -and $localSet.ContainsKey($entry.LanIp)) { return "localhost" }
        $onOfficeLan = $false
        foreach ($k in $localSet.Keys) {
            if ($k -like "192.168.2.*") { $onOfficeLan = $true; break }
        }
        if ($onOfficeLan -and $entry.LanIp) { return $entry.LanIp }
        if ($entry.TailscaleIp) { return $entry.TailscaleIp }
    }
    return $Ip
}

function Get-RemoteNodeInfo {
    param($Project)
    $extIp = $Project.external_ip
    if (-not $extIp) { return $null }
    if ((Resolve-ReachableIp -Ip $extIp) -eq "localhost") { return $null }
    if ($script:NodeCatalog.ContainsKey($extIp)) {
        return $script:NodeCatalog[$extIp]
    }
    return $null
}

function Start-AsyncRemotePortScans {
    param([array]$Projects, [switch]$Force)
    $now = Get-Date
    $uniqueIps = @{}
    foreach ($p in $Projects) {
        $node = Get-RemoteNodeInfo -Project $p
        if ($node -and $p.external_ip -and -not $uniqueIps.ContainsKey($p.external_ip)) {
            $uniqueIps[$p.external_ip] = $node.Alias
        }
    }
    foreach ($ip in $uniqueIps.Keys) {
        if ($script:ActiveSshScans.ContainsKey($ip)) { continue }
        $lastTime = $script:RemoteCacheTime[$ip]
        if (-not $Force -and $lastTime -and (($now - $lastTime).TotalSeconds -lt 10)) { continue }
        $alias = $uniqueIps[$ip]
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "ssh.exe"
            $psi.Arguments = "-o ConnectTimeout=2 -o BatchMode=yes $alias ""netstat -ano | findstr LISTENING"""
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $script:ActiveSshScans[$ip] = [PSCustomObject]@{
                Ip        = $ip
                Alias     = $alias
                Proc      = $proc
                OutTask   = $proc.StandardOutput.ReadToEndAsync()
                StartTime = $now
            }
        } catch {}
    }
}

function Collect-AsyncRemotePortScans {
    param([int]$WaitMs = 0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $completedIps = @()
    foreach ($ip in @($script:ActiveSshScans.Keys)) {
        $scan = $script:ActiveSshScans[$ip]
        $done = $scan.Proc.HasExited
        if (-not $done -and $WaitMs -gt 0) {
            $rem = $WaitMs - [int]$sw.ElapsedMilliseconds
            if ($rem -lt 450) { $rem = 450 }
            $done = $scan.Proc.WaitForExit($rem)
        }
        if ($done) {
            try {
                $raw = $scan.OutTask.Result
                $map = @{}
                foreach ($line in ($raw -split "`r?`n")) {
                    if ("$line" -match 'TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)') {
                        $p = [int]$Matches[1]
                        $pid_ = [int]$Matches[2]
                        if (-not $map.ContainsKey($p)) { $map[$p] = $pid_ }
                    }
                }
                if ($map.Count -gt 0) {
                    $script:RemotePortCache[$ip] = $map
                    $script:RemoteCacheTime[$ip] = Get-Date
                }
            } catch {}
            try { $scan.Proc.Dispose() } catch {}
            $completedIps += $ip
        } elseif (((Get-Date) - $scan.StartTime).TotalSeconds -gt 6) {
            try { $scan.Proc.Kill(); $scan.Proc.Dispose() } catch {}
            $completedIps += $ip
        }
    }
    foreach ($ip in $completedIps) {
        $script:ActiveSshScans.Remove($ip)
    }
}

function Get-ParallelRemoteTcpProbes {
    param([array]$Projects, [int]$TimeoutMs = 450)
    $results = @{}
    $pending = @()
    foreach ($p in $Projects) {
        $node = Get-RemoteNodeInfo -Project $p
        if (-not $node -or -not $p.port -or -not $p.external_ip) { continue }
        # Skip external TCP probe for services bound strictly to 127.0.0.1 on remote node
        if ($p.host -eq "127.0.0.1") { continue }
        $key = "$($p.external_ip):$($p.port)"
        if ($results.ContainsKey($key)) { continue }
        $probeHost = Resolve-ReachableIp -Ip $p.external_ip
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($probeHost, [int]$p.port, $null, $null)
            $pending += [PSCustomObject]@{ Key = $key; Tcp = $tcp; Iar = $iar }
            $results[$key] = $false
        } catch {}
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($item in $pending) {
        $rem = $TimeoutMs - [int]$sw.ElapsedMilliseconds
        if ($rem -lt 5) { $rem = 5 }
        try {
            $ok = $item.Iar.AsyncWaitHandle.WaitOne($rem, $false) -and $item.Tcp.Connected
            if ($ok) { $results[$item.Key] = $true }
        } catch {}
        try { $item.Tcp.Close() } catch {}
    }
    return $results
}

function Get-AllListeningPorts {
    <# Batch-fetch all listening TCP connections once. Returns hashtable: port(int) -> PID(int) #>
    $map = @{}

    # Method 1: Get-NetTCPConnection (fast)
    try {
        $conns = Get-NetTCPConnection -State Listen -ErrorAction Stop
        if ($conns -and $conns.Count -gt 0) {
            foreach ($c in $conns) {
                if ($env:COMPUTERNAME -eq "DESKTOP-874GS44" -and $c.LocalAddress -like "192.168.2.*") { continue }
                $p = [int]$c.LocalPort
                if (-not $map.ContainsKey($p)) {
                    $map[$p] = [int]$c.OwningProcess
                }
            }
            return $map
        }
    } catch {}

    # Method 2: Fallback to netstat -ano (always works)
    try {
        $raw = & netstat -ano 2>&1
        foreach ($line in $raw) {
            if ("$line" -match 'TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)') {
                $addr = $Matches[1]
                if ($env:COMPUTERNAME -eq "DESKTOP-874GS44" -and $addr -like "192.168.2.*") { continue }
                $p = [int]$Matches[2]
                $pid_ = [int]$Matches[3]
                if (-not $map.ContainsKey($p)) {
                    $map[$p] = $pid_
                }
            }
        }
    } catch {}

    return $map
}

function Get-ProcessMetrics {
    param([int]$Pid_)
    try {
        $proc = Get-Process -Id $Pid_ -ErrorAction Stop
        $startTime = try { $proc.StartTime } catch { $null }
        if (-not $startTime) {
            if (-not $script:OsBootTime) {
                $script:OsBootTime = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime } catch { (Get-Date).AddHours(-2) }
            }
            $startTime = $script:OsBootTime
        }
        $uptime = (Get-Date) - $startTime
        $cpuSec = try { [math]::Round($proc.CPU, 1) } catch { 0.0 }
        return @{
            PID          = $Pid_
            CPU_Seconds  = $cpuSec
            Memory_MB    = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            UptimeStr    = ("{0:D2}h {1:D2}m" -f [int]$uptime.TotalHours, $uptime.Minutes)
            ProcessName  = $proc.ProcessName
        }
    } catch {
        return $null
    }
}

function Get-ProjectStatus {
    <# Returns status for a single project. $PortMap is the local listening-ports table. #>
    param($Project, [hashtable]$PortMap, [hashtable]$RemoteTcpMap = @{})

    $port = $Project.port
    $pid_ = $null
    $status = "STOPPED"
    $managed = $false
    $metrics = $null
    $isSSH = [bool]$Project.ssh -and [bool]$Project.ssh.enabled
    $remoteNode = Get-RemoteNodeInfo -Project $Project

    if ($isSSH) {
        $sshTarget = "$($Project.ssh.user)@$($Project.ssh.host)"
        $statusCmd = $Project.ssh.status_command
        try {
            $result = ssh -o ConnectTimeout=1 -o BatchMode=yes $sshTarget $statusCmd 2>$null
            if ($LASTEXITCODE -eq 0 -and $result) {
                $status = "RUNNING"
                $pid_ = ($result -split "`n" | Select-Object -First 1).Trim()
            }
        } catch {}

        if ($status -eq "STOPPED" -and $port) {
            $targetHost = if ($Project.ssh.host) { $Project.ssh.host } else { $Project.external_ip }
            if ($targetHost) {
                try {
                    $tcpClient = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcpClient.BeginConnect($targetHost, [int]$port, $null, $null)
                    $success = $connect.AsyncWaitHandle.WaitOne(150)
                    if ($success) {
                        $tcpClient.EndConnect($connect)
                        $status = "RUNNING"
                        $pid_ = "remote"
                    }
                    $tcpClient.Close()
                } catch {}
            }
        }
    } elseif ($null -ne $remoteNode) {
        # Multi-Server Remote Node (.218, .222, .237, .187)
        $extIp = $Project.external_ip
        $tcpKey = "${extIp}:${port}"
        $tcpUp = $port -and $RemoteTcpMap.ContainsKey($tcpKey) -and $RemoteTcpMap[$tcpKey]
        $sshMap = $script:RemotePortCache[$extIp]
        $sshPid = if ($port -and $sshMap -and $sshMap.ContainsKey([int]$port)) { $sshMap[[int]$port] } else { $null }

        if ($Project.host -eq "127.0.0.1") {
            # Localhost-only service on remote host: rely on SSH netstat cache
            if ($sshPid) {
                $status = "RUNNING"
                $pid_ = $sshPid
            }
        } else {
            if ($tcpUp -or $sshPid) {
                $status = "RUNNING"
                $pid_ = if ($sshPid) { $sshPid } else { "remote" }
            }
        }
    } else {
        # Local project on this machine
        if ($script:ManagedPIDs.ContainsKey($Project.id)) {
            $candidatePid = $script:ManagedPIDs[$Project.id]
            try {
                $null = Get-Process -Id $candidatePid -ErrorAction Stop
                $pid_ = $candidatePid
                $status = "RUNNING"
                $managed = $true
            } catch {
                $script:ManagedPIDs.Remove($Project.id)
            }
        }

        if (-not $pid_ -and $Project.process_match) {
            try {
                if (-not $script:CimProcessCache -or ((Get-Date) - $script:CimProcessCacheTime).TotalSeconds -gt 2) {
                    $script:CimProcessCache = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
                    $script:CimProcessCacheTime = Get-Date
                }
                $matchedProc = $script:CimProcessCache | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $Project.process_match } | Select-Object -First 1
                if ($matchedProc) {
                    $pid_ = [int]$matchedProc.ProcessId
                    $status = "RUNNING"
                }
            } catch {}
        }

        if (-not $pid_ -and $port -and $PortMap.ContainsKey([int]$port)) {
            $pid_ = $PortMap[[int]$port]
            $status = "RUNNING"
        }

        if ($pid_) {
            $metrics = Get-ProcessMetrics -Pid_ $pid_
        }
    }

    $extIp = $Project.external_ip
    $displayHost = if ($extIp) { Resolve-ReachableIp -Ip $extIp } elseif ($Project.host -eq "0.0.0.0") { "localhost" } else { $Project.host }
    $address = if ($port) { "${displayHost}:${port}" } elseif ($Project.process_match) { "${displayHost}:daemon" } else { "N/A" }
    $scheme = if ($port -eq 443) { "https" } else { "http" }
    $url = if ($port -and $port -ne 1433) { "${scheme}://${displayHost}:${port}" } else { $null }

    return [PSCustomObject]@{
        Id          = $Project.id
        Name        = $Project.name
        Description = $Project.description
        Status      = $status
        Address     = $address
        Url         = $url
        Port        = $port
        Path        = $Project.path
        Command     = if ($isSSH) { "[SSH] $($Project.ssh.start_command)" } elseif ($remoteNode) { "[SSH:$($remoteNode.Alias)] $($Project.command)" } else { $Project.command }
        HealthCheck = $Project.health_check
        ExternalIp  = if ($extIp) { $extIp } else { "-" }
        PID         = if ($pid_) { $pid_ } else { "-" }
        Uptime      = if ($metrics) { $metrics.UptimeStr } elseif ($remoteNode -and $status -eq "RUNNING") { $remoteNode.Alias } else { "-" }
        Memory      = if ($metrics) { "$($metrics.Memory_MB) MB" } else { "-" }
        CPU         = if ($metrics) { "$($metrics.CPU_Seconds)s" } else { "-" }
        ProcessName = if ($metrics) { $metrics.ProcessName } elseif ($remoteNode) { "ssh:$($remoteNode.Alias)" } elseif ($isSSH) { "remote" } else { "-" }
        Managed     = $managed
        NeedsAdmin  = [bool]$Project.requires_admin
        IsSSH       = ($isSSH -or ($null -ne $remoteNode))
        NodeLabel   = (Get-ProjectNodeLabel -Project $Project)
        Environment = if ($Project.environment) { $Project.environment } else { "dev" }
    }
}

function Refresh-AllStatuses {
    <# Single batch refresh: local port scan + parallel remote TCP probe + async SSH PID table. #>
    param([array]$Projects, [switch]$ForceSsh)
    $portMap = Get-AllListeningPorts
    $activeFilter = if ($script:NodeFilters -and $script:CurrentFilterIdx -ge 0) { $script:NodeFilters[$script:CurrentFilterIdx] } else { "ALL" }
    $mainLabels = @("HOME (Local)", "192.168.2.222 (Dev)", "192.168.2.218 (Produccion)", "WEB-HUB (.237)", "BD-VAULT (.187)")
    $scanProjects = if ($activeFilter -eq "ALL") {
        $Projects
    } else {
        @($Projects | Where-Object {
            $lbl = (Get-ProjectNodeLabel -Project $_)
            ($lbl -eq $activeFilter) -or ($lbl -in $mainLabels)
        })
    }
    $hasRemoteInView = $false
    foreach ($sp in $scanProjects) {
        if ($null -ne (Get-RemoteNodeInfo -Project $sp)) { $hasRemoteInView = $true; break }
    }
    $remoteTcpMap = @{}
    if ($hasRemoteInView) {
        if (-not $script:InitialScanDone -or $ForceSsh) {
            Start-AsyncRemotePortScans -Projects $scanProjects -Force:$ForceSsh
            $remoteTcpMap = Get-ParallelRemoteTcpProbes -Projects $scanProjects -TimeoutMs 280
            Collect-AsyncRemotePortScans -WaitMs 2200
            $script:InitialScanDone = $true
        } else {
            Start-AsyncRemotePortScans -Projects $scanProjects
            $remoteTcpMap = Get-ParallelRemoteTcpProbes -Projects $scanProjects -TimeoutMs 250
            Collect-AsyncRemotePortScans -WaitMs 0
        }
    }
    $res = @($Projects | ForEach-Object { Get-ProjectStatus -Project $_ -PortMap $portMap -RemoteTcpMap $remoteTcpMap })
    $script:LastAllStatuses = $res
    return $res
}

# --- Actions -----------------------------------------------------------------

function Invoke-RemoteNodePowerShell {
    param([string]$Alias, [string]$ScriptBlockText, [int]$TimeoutSecs = 8)
    # Cancel any in-flight background netstat scan on this alias to avoid concurrent SSH banner collisions
    foreach ($ip in @($script:ActiveSshScans.Keys)) {
        if ($script:ActiveSshScans[$ip].Alias -eq $Alias) {
            try { $script:ActiveSshScans[$ip].Proc.Kill(); $script:ActiveSshScans[$ip].Proc.Dispose() } catch {}
            $script:ActiveSshScans.Remove($ip)
        }
    }
    $fullScript = "`$ProgressPreference = 'SilentlyContinue'`r`n" + $ScriptBlockText
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($fullScript)
    $b64   = [Convert]::ToBase64String($bytes)
    $joined = ""
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $out = ssh -o ConnectTimeout=$TimeoutSecs -o BatchMode=yes $Alias "powershell -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand $b64" 2>&1
        $joined = ($out -join "`n")
        $joined = $joined -replace '(?s)#< CLIXML.*?</Objs>', ''
        $joined = $joined.Trim()
        if ($joined -notmatch "banner exchange|Connection timed out|Connection reset") {
            return $joined
        }
        Start-Sleep -Milliseconds 800
    }
    return $joined
}

function Start-RemoteNodeProject {
    param($Project, $Node)
    $alias  = $Node.Alias
    $logDir = $Node.LogDir
    $id     = $Project.id
    $path   = $Project.path
    $cmd    = $Project.command
    $port   = if ($Project.port) { [int]$Project.port } else { 0 }

    Write-Host "  Starting $($Project.name) on $($Node.Label) via SSH ($alias)..." -ForegroundColor Yellow -NoNewline

    $psTemplate = @'
$ErrorActionPreference = 'SilentlyContinue'
$logDir = '__LOG_DIR__'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logOut = Join-Path $logDir '__ID___stdout.log'
$logErr = Join-Path $logDir '__ID___stderr.log'
$workDir = '__WORK_DIR__'
if (-not (Test-Path $workDir)) { Write-Output ("ERR:Path missing (" + $workDir + ")"); exit 1 }
$rawCmd = '__RAW_CMD__'
$cmdNorm = $rawCmd.Replace('/', '\').Replace('cmd \c', 'cmd /c').Replace('http:\\', 'http://').Replace('https:\\', 'https://')
$q = [char]34
$fullCmd = "cmd.exe /c " + $cmdNorm + " >> " + $q + $logOut + $q + " 2>> " + $q + $logErr + $q
$wmiStartup = New-CimInstance -ClassName Win32_ProcessStartup -Property @{ ShowWindow = [uint16]0 } -ClientOnly
$res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $fullCmd; CurrentDirectory = $workDir; ProcessStartupInformation = $wmiStartup }
if ($res.ReturnValue -eq 0) {
    Start-Sleep -Milliseconds 1800
    $port = __PORT__
    $listenPid = $res.ProcessId
    if ($port -gt 0) {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($conns) { $listenPid = [int]($conns | Select-Object -First 1).OwningProcess }
    }
    Write-Output ("OK:" + $listenPid)
} else {
    Write-Output ("ERR:WMI_" + $res.ReturnValue)
}
'@
    $psCode = $psTemplate.
        Replace('__LOG_DIR__', $logDir.Replace("'", "''")).
        Replace('__ID__', $id.Replace("'", "''")).
        Replace('__WORK_DIR__', $path.Replace("'", "''")).
        Replace('__RAW_CMD__', $cmd.Replace("'", "''")).
        Replace('__PORT__', "$port")

    try {
        $resp = Invoke-RemoteNodePowerShell -Alias $alias -ScriptBlockText $psCode -TimeoutSecs 10
        if ($resp -match "OK:(\d+)") {
            $remotePid = [int]$Matches[1]
            Write-Host " OK (Remote PID $remotePid)" -ForegroundColor Green
            if ($port -gt 0 -and $Project.external_ip) {
                if (-not $script:RemotePortCache.ContainsKey($Project.external_ip)) {
                    $script:RemotePortCache[$Project.external_ip] = @{}
                }
                $script:RemotePortCache[$Project.external_ip][$port] = $remotePid
            }
        } else {
            Write-Host " FAILED ($resp)" -ForegroundColor Red
        }
    } catch {
        Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }
}

function Stop-RemoteNodeProject {
    param($Project, $Node)
    $alias = $Node.Alias
    $port  = if ($Project.port) { [int]$Project.port } else { 0 }
    if ($port -le 0) {
        Write-Host "  ERROR: Remote project $($Project.name) has no port to target." -ForegroundColor Yellow
        return
    }

    Write-Host "  Killing $($Project.name) on $($Node.Label) (port $port)..." -ForegroundColor Yellow -NoNewline

    $psTemplate = @'
$ErrorActionPreference = 'SilentlyContinue'
$port = __PORT__
$targetPid = $null
$conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($conns) { $targetPid = [int]($conns | Select-Object -First 1).OwningProcess }
if (-not $targetPid) {
    $raw = netstat -ano 2>$null
    foreach ($line in $raw) {
        if ("$line" -match ("TCP\s+\S+:" + $port + "\s+\S+\s+LISTENING\s+(\d+)")) {
            $targetPid = [int]$Matches[1]; break
        }
    }
}
if (-not $targetPid) { Write-Output "NOT_RUNNING"; exit 0 }
$children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ParentProcessId -eq $targetPid } | Select-Object -ExpandProperty ProcessId
foreach ($c in $children) { Stop-Process -Id $c -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
Write-Output ("KILLED:" + $targetPid)
'@
    $psCode = $psTemplate.Replace('__PORT__', "$port")

    try {
        $resp = Invoke-RemoteNodePowerShell -Alias $alias -ScriptBlockText $psCode -TimeoutSecs 8
        if ($resp -match "KILLED:(\d+)") {
            Write-Host " OK (Killed PID $($Matches[1]))" -ForegroundColor Green
            if ($Project.external_ip -and $script:RemotePortCache.ContainsKey($Project.external_ip)) {
                $script:RemotePortCache[$Project.external_ip].Remove([int]$port)
            }
        } elseif ($resp -match "NOT_RUNNING") {
            Write-Host " Already stopped" -ForegroundColor DarkYellow
        } else {
            Write-Host " SENT ($resp)" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }
}

function Start-Project {
    param($Project)

    $isSSH = [bool]$Project.ssh -and [bool]$Project.ssh.enabled
    if ($isSSH) {
        Start-SSHProject -Project $Project
        return
    }

    $remoteNode = Get-RemoteNodeInfo -Project $Project
    if ($null -ne $remoteNode) {
        Start-RemoteNodeProject -Project $Project -Node $remoteNode
        return
    }

    $port = $Project.port
    $path = $Project.path
    $command = $Project.command

    if (-not $path -or -not $command) {
        Write-Host "  ERROR: Project missing path or command." -ForegroundColor Red
        return
    }
    if (-not (Test-Path $path)) {
        Write-Host "  ERROR: Path does not exist: $path" -ForegroundColor Red
        return
    }
    if ($port) {
        $portMap = Get-AllListeningPorts
        if ($portMap.ContainsKey([int]$port)) {
            Write-Host "  ERROR: Port $port is already in use by PID $($portMap[[int]$port])." -ForegroundColor Red
            return
        }
    }

    $logOut = Join-Path $LogDir "$($Project.id)_stdout.log"
    $logErr = Join-Path $LogDir "$($Project.id)_stderr.log"

    Write-Host "  Starting $($Project.name)..." -ForegroundColor Yellow -NoNewline

    try {
        $cmdNormalized = $command.Replace('/', '\').Replace('cmd \c', 'cmd /c').Replace('http:\\', 'http://').Replace('https:\\', 'https://')

        $proc = Start-Process -FilePath "cmd.exe" `
                              -ArgumentList "/c $cmdNormalized" `
                              -WorkingDirectory $path `
                              -RedirectStandardOutput $logOut `
                              -RedirectStandardError $logErr `
                              -WindowStyle Hidden `
                              -PassThru

        $script:ManagedPIDs[$Project.id] = $proc.Id

        $separator = "`n$("=" * 60)`n[$((Get-Date).ToString('o'))] Started $($Project.name)`n$("=" * 60)`n"
        Add-Content -Path $logOut -Value $separator -ErrorAction SilentlyContinue

        Write-Host " OK (PID $($proc.Id))" -ForegroundColor Green
    } catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Start-SSHProject {
    param($Project)

    $ssh = $Project.ssh
    $sshTarget = "$($ssh.user)@$($ssh.host)"
    $startCmd = $ssh.start_command

    Write-Host "  Starting $($Project.name) via SSH ($sshTarget)..." -ForegroundColor Yellow -NoNewline

    $logOut = Join-Path $LogDir "$($Project.id)_ssh.log"
    $timestamp = (Get-Date).ToString('o')
    Add-Content -Path $logOut -Value "`n$('=' * 60)`n[$timestamp] SSH START: $startCmd`n$('=' * 60)" -ErrorAction SilentlyContinue

    try {
        $output = ssh -o ConnectTimeout=5 $sshTarget $startCmd 2>&1
        Add-Content -Path $logOut -Value $output -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 1
        $checkResult = ssh -o ConnectTimeout=3 -o BatchMode=yes $sshTarget $ssh.status_command 2>$null
        if ($LASTEXITCODE -eq 0 -and $checkResult) {
            Write-Host " OK (Remote PID $($checkResult.Trim()))" -ForegroundColor Green
        } else {
            $port = $Project.port
            $targetHost = if ($ssh.host) { $ssh.host } else { $Project.external_ip }
            $tcpSuccess = $false
            if ($port -and $targetHost) {
                try {
                    $tcpClient = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcpClient.BeginConnect($targetHost, [int]$port, $null, $null)
                    if ($connect.AsyncWaitHandle.WaitOne(1000)) {
                        $tcpClient.EndConnect($connect)
                        $tcpSuccess = $true
                    }
                    $tcpClient.Close()
                } catch {}
            }
            if ($tcpSuccess) {
                Write-Host " OK (Verified active on port $port)" -ForegroundColor Green
            } else {
                Write-Host " SENT (verify with refresh)" -ForegroundColor DarkYellow
            }
        }
    } catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Stop-Project {
    param($Project)

    $isSSH = [bool]$Project.ssh -and [bool]$Project.ssh.enabled
    if ($isSSH) {
        Stop-SSHProject -Project $Project
        return
    }

    $remoteNode = Get-RemoteNodeInfo -Project $Project
    if ($null -ne $remoteNode) {
        Stop-RemoteNodeProject -Project $Project -Node $remoteNode
        return
    }

    $port = $Project.port
    $targetPid = $null

    if ($script:ManagedPIDs.ContainsKey($Project.id)) {
        $targetPid = $script:ManagedPIDs[$Project.id]
    } elseif ($Project.process_match) {
        $m = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $Project.process_match } | Select-Object -First 1
        if ($m) { $targetPid = [int]$m.ProcessId }
    }
    if (-not $targetPid -and $port) {
        $portMap = Get-AllListeningPorts
        if ($portMap.ContainsKey([int]$port)) { $targetPid = $portMap[[int]$port] }
    }

    if (-not $targetPid) {
        Write-Host "  No running process found for $($Project.name)." -ForegroundColor Yellow
        return
    }

    Write-Host "  Killing $($Project.name) (PID $targetPid)..." -ForegroundColor Yellow -NoNewline

    try {
        $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ParentProcessId -eq $targetPid } |
                    Select-Object -ExpandProperty ProcessId

        foreach ($childPid in $children) {
            try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
        }
        Stop-Process -Id $targetPid -Force -ErrorAction Stop
        $script:ManagedPIDs.Remove($Project.id)

        Write-Host " OK" -ForegroundColor Green
    } catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Stop-SSHProject {
    param($Project)

    $ssh = $Project.ssh
    $sshTarget = "$($ssh.user)@$($ssh.host)"
    $stopCmd = $ssh.stop_command

    Write-Host "  Killing $($Project.name) via SSH ($sshTarget)..." -ForegroundColor Yellow -NoNewline

    try {
        $output = ssh -o ConnectTimeout=5 $sshTarget $stopCmd 2>&1

        $logOut = Join-Path $LogDir "$($Project.id)_ssh.log"
        Add-Content -Path $logOut -Value "[$((Get-Date).ToString('o'))] SSH STOP: $stopCmd`n$output" -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 1
        $checkResult = ssh -o ConnectTimeout=3 -o BatchMode=yes $sshTarget $ssh.status_command 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $checkResult) {
            $port = $Project.port
            $targetHost = if ($ssh.host) { $ssh.host } else { $Project.external_ip }
            $portClosed = $true
            if ($port -and $targetHost) {
                try {
                    $tcpClient = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcpClient.BeginConnect($targetHost, [int]$port, $null, $null)
                    if ($connect.AsyncWaitHandle.WaitOne(1000)) {
                        $tcpClient.EndConnect($connect)
                        $portClosed = $false
                    }
                    $tcpClient.Close()
                } catch {}
            }
            if ($portClosed) {
                Write-Host " OK" -ForegroundColor Green
            } else {
                Write-Host " SENT (may still be shutting down)" -ForegroundColor DarkYellow
            }
        } else {
            Write-Host " SENT (may still be shutting down)" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Restart-Project {
    param($Project)
    Stop-Project -Project $Project
    Start-Sleep -Seconds 2
    Start-Project -Project $Project
}

function Test-FastTcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 300)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $tcp.Connected
        $tcp.Close()
        return $ok
    } catch {
        return $false
    }
}

function Invoke-WakeAll218 {
    param([array]$AllProjects = @())
    Write-Host ""
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  GLOBAL WAKE CLUSTER - Starting all services (.222, Home, .218, .237)|" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    $localSet = Get-LocalIPSet

    # 1. Wake 192.168.2.222 (OFICINA / DEVQB - All 22 dev & prod services)
    try {
        $remoteScript222 = "C:\Users\CarlosAlbertoAcevesC\Desktop\02-plataformas-activas\merlin\start_all_services_222.ps1"
        if ($localSet.ContainsKey("192.168.2.222") -or $localSet.ContainsKey("100.89.1.27") -or $env:COMPUTERNAME -eq "DEVQB") {
            Write-Host "  [1/4] Waking OFICINA (192.168.2.222) locally..." -ForegroundColor Yellow
            & $remoteScript222
        } else {
            Write-Host "  [1/4] Connecting to 'office-pc' (192.168.2.222) via SSH..." -ForegroundColor Yellow
            $psCode222 = "& 'C:\Users\CarlosAlbertoAcevesC\Desktop\02-plataformas-activas\merlin\start_all_services_222.ps1'"
            $output222 = Invoke-RemoteNodePowerShell -Alias "office-pc" -ScriptBlockText $psCode222 -TimeoutSecs 20
            foreach ($line in ($output222 -split "`r?`n")) {
                if ($line.Trim()) {
                    $col = if ($line -match "ACTIVO|OK|INICIADO") { "Green" } elseif ($line -match "ERROR|FALLO") { "Red" } else { "Gray" }
                    Write-Host "  $line" -ForegroundColor $col
                }
            }
        }
    } catch {
        Write-Host "  ERROR (.222): $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""

    # 2. Wake HOME (100.90.211.9:8090 - Brain Portal Home)
    try {
        Write-Host "  [2/4] Checking HOME (100.90.211.9:8090 - Brain Portal)..." -ForegroundColor Yellow
        if (Test-FastTcpPort -TargetHost "100.90.211.9" -Port 8090 -TimeoutMs 450) {
            Write-Host "  [ACTIVO] Brain Portal (Home) -> 100.90.211.9:8090 OK" -ForegroundColor Green
        } elseif ($localSet.ContainsKey("100.90.211.9") -or $env:COMPUTERNAME -eq "DESKTOP-874GS44") {
            $homePortalDir = "C:\Users\Admin\.gemini\brain-portal"
            if (Test-Path (Join-Path $homePortalDir "server.py")) {
                $wmiSt = New-CimInstance -ClassName Win32_ProcessStartup -Property @{ ShowWindow = [uint16]0 } -ClientOnly
                $resHome = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
                    CommandLine               = 'cmd.exe /c python server.py 8090 >> "C:\Users\Admin\.gemini\brain-portal\portal_stdout.log" 2>> "C:\Users\Admin\.gemini\brain-portal\portal_stderr.log"'
                    CurrentDirectory          = $homePortalDir
                    ProcessStartupInformation = $wmiSt
                }
                Write-Host "  [INICIADO] Brain Portal (Home) -> Local WMI PID $($resHome.ProcessId)" -ForegroundColor Green
            }
        } elseif (Test-FastTcpPort -TargetHost "100.90.211.9" -Port 22 -TimeoutMs 500) {
            $psCodeHome = @'
$wmiSt = New-CimInstance -ClassName Win32_ProcessStartup -Property @{ ShowWindow = [uint16]0 } -ClientOnly
$res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine               = 'cmd.exe /c python server.py 8090 >> "C:\Users\Admin\.gemini\brain-portal\portal_stdout.log" 2>> "C:\Users\Admin\.gemini\brain-portal\portal_stderr.log"'
    CurrentDirectory          = 'C:\Users\Admin\.gemini\brain-portal'
    ProcessStartupInformation = $wmiSt
}
Write-Output ("OK:" + $res.ProcessId)
'@
            $outHome = Invoke-RemoteNodePowerShell -Alias "home" -ScriptBlockText $psCodeHome -TimeoutSecs 8
            if ($outHome -match "OK:(\d+)") {
                Write-Host "  [INICIADO] Brain Portal (Home) on 100.90.211.9:8090 (Remote PID $($Matches[1]))" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Home SSH response: $outHome" -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "  [PENDIENTE] 100.90.211.9 SSH (:22) cerrado temporalmente; auto-inicio encolado en sync_repo.ps1" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  ERROR (Home): $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""

    # 3. Wake 192.168.2.218 (QB_DESARROLLO)
    try {
        $remoteScript218 = "C:\Users\QB_DESARROLLO\Desktop\Merlin\start_all_services.ps1"
        if ($localSet.ContainsKey("192.168.2.218") -or $localSet.ContainsKey("100.77.199.69") -or $env:COMPUTERNAME -eq "Desarrollo") {
            Write-Host "  [3/4] Waking QB-DEV (192.168.2.218) locally..." -ForegroundColor Yellow
            & $remoteScript218
        } else {
            Write-Host "  [3/4] Connecting to 'desarrollo' (192.168.2.218) via SSH..." -ForegroundColor Yellow
            $psCode218 = "& 'C:\Users\QB_DESARROLLO\Desktop\Merlin\start_all_services.ps1'"
            $output218 = Invoke-RemoteNodePowerShell -Alias "desarrollo" -ScriptBlockText $psCode218 -TimeoutSecs 15
            foreach ($line in ($output218 -split "`r?`n")) {
                if ($line.Trim()) {
                    $col = if ($line -match "ACTIVO|OK|INICIADO") { "Green" } elseif ($line -match "ERROR|FALLO") { "Red" } else { "Gray" }
                    Write-Host "  $line" -ForegroundColor $col
                }
            }
        }
    } catch {
        Write-Host "  ERROR (.218): $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""

    # 4. Wake 192.168.2.237 (WEB-HUB) & 192.168.2.187 (BD-VAULT)
    try {
        Write-Host "  [4/4] Verificando WEB-HUB (.237) y BD-VAULT (.187)..." -ForegroundColor Yellow
        if ($AllProjects -and $AllProjects.Count -gt 0) {
            $infraProjects = @($AllProjects | Where-Object { $_.external_ip -in @("192.168.2.237", "100.105.210.35", "192.168.2.187", "100.102.18.118") })
            foreach ($ipProj in $infraProjects) {
                $tHost = Resolve-ReachableIp -Ip $ipProj.external_ip
                $pPort = [int]$ipProj.port
                if (Test-FastTcpPort -TargetHost $tHost -Port $pPort -TimeoutMs 350) {
                    Write-Host "  [ACTIVO] $($ipProj.name) -> ${tHost}:${pPort}" -ForegroundColor Green
                } else {
                    Start-Project -Project $ipProj
                }
            }
        }
    } catch {
        Write-Host "  ERROR (.237/.187): $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""
}

function Invoke-AutoHealPass {
    param([array]$AllProjects, [array]$AllStatuses)
    if (-not $script:AutoHealEnabled) { return $false }
    $now = Get-Date
    $healedAny = $false
    $wmiStartup = $null

    for ($i = 0; $i -lt $AllStatuses.Count; $i++) {
        $st = $AllStatuses[$i]
        if ($st.Status -eq "RUNNING") { continue }
        $proj = $AllProjects[$i]
        if (-not $proj -or -not $proj.id) { continue }

        # Cooldown of 45 seconds per project to allow slow-starting services to bind their port
        if ($script:AutoHealCooldowns.ContainsKey($proj.id)) {
            $elapsed = ($now - $script:AutoHealCooldowns[$proj.id]).TotalSeconds
            if ($elapsed -lt 45) { continue }
        }

        $remoteNode = Get-RemoteNodeInfo -Project $proj
        if ($null -eq $remoteNode -and -not ($proj.ssh -and $proj.ssh.enabled)) {
            # Local service on this node: start silently via hidden WMI
            if ($proj.path -and $proj.command -and (Test-Path $proj.path)) {
                $script:AutoHealCooldowns[$proj.id] = $now
                try {
                    if ($null -eq $wmiStartup) {
                        $wmiStartup = New-CimInstance -ClassName Win32_ProcessStartup -Property @{ ShowWindow = [uint16]0 } -ClientOnly
                    }
                    $logOut = Join-Path $LogDir "$($proj.id)_stdout.log"
                    $logErr = Join-Path $LogDir "$($proj.id)_stderr.log"
                    $cmdNorm = $proj.command.Replace('/', '\').Replace('cmd \c', 'cmd /c').Replace('http:\\', 'http://').Replace('https:\\', 'https://')
                    $q = [char]34
                    $fullCmd = "cmd.exe /c " + $cmdNorm + " >> " + $q + $logOut + $q + " 2>> " + $q + $logErr + $q
                    $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
                        CommandLine               = $fullCmd
                        CurrentDirectory          = $proj.path
                        ProcessStartupInformation = $wmiStartup
                    }
                    if ($res.ReturnValue -eq 0) {
                        $script:ManagedPIDs[$proj.id] = $res.ProcessId
                        $script:LastHealEvent = "Auto-healed $($proj.name) ($(Get-Date -Format 'HH:mm:ss'))"
                        $healedAny = $true
                    }
                } catch {}
            }
        } elseif ($null -ne $remoteNode) {
            # Remote service (e.g. Home 100.90.211.9:8090, .218, .237): only attempt if SSH port 22 is open
            $sshCheckHost = if ($remoteNode.LanIp -and (Resolve-ReachableIp -Ip $proj.external_ip) -eq $remoteNode.LanIp) { $remoteNode.LanIp } else { $remoteNode.TailscaleIp }
            if ($sshCheckHost -and (Test-FastTcpPort -TargetHost $sshCheckHost -Port 22 -TimeoutMs 220)) {
                $script:AutoHealCooldowns[$proj.id] = $now
                try {
                    $null = Start-RemoteNodeProject -Project $proj -Node $remoteNode *>$null
                    $script:LastHealEvent = "Auto-healed $($proj.name) on $($remoteNode.Alias) ($(Get-Date -Format 'HH:mm:ss'))"
                    $healedAny = $true
                } catch {}
            } else {
                # Back off 60s if remote host SSH is offline so UI never lags
                $script:AutoHealCooldowns[$proj.id] = $now.AddSeconds(15)
            }
        }
    }
    return $healedAny
}

function Confirm-ProductionAction {
    <# Shows a warning for production services and requires typing PROD to confirm. Returns $true for dev. #>
    param([string]$ActionName, $Project)
    $projEnv = if ($Project.environment) { $Project.environment } else { "dev" }
    if ($projEnv -ne "prod") { return $true }

    $hostDisplay = if ($Project.ssh -and $Project.ssh.host) { $Project.ssh.host } elseif ($Project.external_ip) { $Project.external_ip } else { "localhost" }

    Write-Host ""
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor Red
    Write-Host "  |  WARNING: PRODUCTION SERVICE                                        |" -ForegroundColor Red
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Action:  $ActionName" -ForegroundColor Yellow
    Write-Host "  Service: $($Project.name)" -ForegroundColor Yellow
    Write-Host "  Host:    $hostDisplay" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  This will affect the LIVE production system!" -ForegroundColor Red
    Write-Host ""
    Write-Host -NoNewline "  Type PROD to confirm: " -ForegroundColor Red
    $confirm = Read-Host
    if ($confirm -eq "PROD") { return $true }
    Write-Host "  Cancelled." -ForegroundColor DarkGray
    return $false
}

function Kill-AllProjects {
    <# Kills every process on every configured port, including zombies. #>
    param([array]$Projects)

    Write-Host ""
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor Red
    Write-Host "  |  KILL ALL - Terminating all servers and zombie processes              |" -ForegroundColor Red
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor Red
    Write-Host ""

    $portMap = Get-AllListeningPorts
    $killed = 0
    $failed = 0

    foreach ($proj in $Projects) {
        $isSSH = [bool]$proj.ssh -and [bool]$proj.ssh.enabled

        if ($isSSH) {
            $sshTarget = "$($proj.ssh.user)@$($proj.ssh.host)"
            Write-Host -NoNewline "  [X] $($proj.name.PadRight(20)) SSH $sshTarget " -ForegroundColor Yellow
            try {
                $null = ssh -o ConnectTimeout=3 $sshTarget $proj.ssh.stop_command 2>&1
                $killed++
                Write-Host " KILLED" -ForegroundColor Green
            } catch {
                $failed++
                Write-Host " FAILED" -ForegroundColor Red
            }
            continue
        }

        $remoteNode = Get-RemoteNodeInfo -Project $proj
        if ($null -ne $remoteNode) {
            Stop-RemoteNodeProject -Project $proj -Node $remoteNode
            $killed++
            continue
        }

        $port = $proj.port
        $pidsToKill = @()

        if ($script:ManagedPIDs.ContainsKey($proj.id)) {
            $pidsToKill += $script:ManagedPIDs[$proj.id]
        }

        if ($port -and $portMap.ContainsKey([int]$port)) {
            $portPid = $portMap[[int]$port]
            if ($pidsToKill -notcontains $portPid) {
                $pidsToKill += $portPid
            }
        }

        if ($pidsToKill.Count -eq 0) {
            Write-Host "  [ ] $($proj.name.PadRight(20)) already stopped" -ForegroundColor DarkGray
            continue
        }

        foreach ($pid_ in $pidsToKill) {
            Write-Host -NoNewline "  [X] $($proj.name.PadRight(20)) PID $($pid_.ToString().PadRight(8))" -ForegroundColor Yellow

            try {
                $children = @()
                try {
                    $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                                Where-Object { $_.ParentProcessId -eq $pid_ } |
                                Select-Object -ExpandProperty ProcessId
                } catch {}

                foreach ($childPid in $children) {
                    try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
                }

                Stop-Process -Id $pid_ -Force -ErrorAction Stop
                $killed++
                Write-Host " KILLED" -ForegroundColor Green
            } catch {
                try {
                    $null = Get-Process -Id $pid_ -ErrorAction Stop
                    $failed++
                    Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
                } catch {
                    $killed++
                    Write-Host " KILLED (was exiting)" -ForegroundColor Green
                }
            }
        }

        $script:ManagedPIDs.Remove($proj.id)
    }

    Write-Host ""
    Write-Host "  Scanning for remaining local zombies..." -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 500
    $portMap2 = Get-AllListeningPorts
    $zombies = 0

    foreach ($proj in $Projects) {
        if (Get-RemoteNodeInfo -Project $proj) { continue }
        $port = $proj.port
        if ($port -and $portMap2.ContainsKey([int]$port)) {
            $zPid = $portMap2[[int]$port]
            Write-Host -NoNewline "  [Z] ZOMBIE on port $port (PID $zPid) " -ForegroundColor Magenta
            try {
                Stop-Process -Id $zPid -Force -ErrorAction Stop
                $zombies++
                Write-Host " KILLED" -ForegroundColor Green
            } catch {
                Write-Host " FAILED" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
    Write-Host "  Summary: $killed killed, $zombies zombies cleaned, $failed failed" -ForegroundColor White
    Write-Host ""
}

# --- Display -----------------------------------------------------------------

$script:NodeFilters = @(
    "HOME (Local)",
    "192.168.2.222 (Dev)",
    "192.168.2.218 (Produccion)",
    "WEB-HUB (.237)",
    "BD-VAULT (.187)",
    "ALL"
)

function Get-LocalNodeLabel {
    $localSet = Get-LocalIPSet
    if ($localSet.ContainsKey("192.168.2.218") -or $localSet.ContainsKey("100.77.199.69") -or $env:COMPUTERNAME -eq "Desarrollo") {
        return "192.168.2.218 (Produccion)"
    }
    if ($localSet.ContainsKey("192.168.2.222") -or $localSet.ContainsKey("100.89.1.27") -or $env:COMPUTERNAME -eq "DEVQB") {
        return "192.168.2.222 (Dev)"
    }
    if ($localSet.ContainsKey("192.168.2.237") -or $localSet.ContainsKey("100.105.210.35")) {
        return "WEB-HUB (.237)"
    }
    if ($localSet.ContainsKey("192.168.2.187") -or $localSet.ContainsKey("100.102.18.118")) {
        return "BD-VAULT (.187)"
    }
    if ($localSet.ContainsKey("100.90.211.9") -or $env:COMPUTERNAME -eq "DESKTOP-874GS44") {
        return "HOME (Local)"
    }
    return $null
}

$script:LocalNodeLabel = Get-LocalNodeLabel
$script:CurrentFilterIdx = if ($script:LocalNodeLabel) {
    $idx = [array]::IndexOf($script:NodeFilters, $script:LocalNodeLabel)
    if ($idx -ge 0) { $idx } else { 0 }
} else { 0 }

function Format-RowAnsi {
    param($S, [int]$Index, [bool]$Selected, $ColW)

    $esc      = [string][char]27
    $cReset   = "$esc[0m"
    $cDkGray  = "$esc[90m"
    $cWhite   = "$esc[97m"
    $cCyan    = "$esc[96m"
    $cGreen   = "$esc[92m"
    $cRed     = "$esc[91m"
    $cYellow  = "$esc[93m"
    $bgSel    = if ($Selected) { "$esc[46m" } else { "" }
    $bgOff    = if ($Selected) { "$esc[49m" } else { "" }

    $statusColor = if ($S.Status -eq "RUNNING") { $cGreen } else { $cRed }
    $statusIcon  = if ($S.Status -eq "RUNNING") { "[*]" } else { "[ ]" }
    $adminTag    = if ($S.NeedsAdmin) { "*" } else { "" }

    $fgIdx  = if ($Selected) { $cYellow } else { $cWhite }
    $fgName = $cWhite
    $fgAddr = if ($S.Status -eq "RUNNING") { $cCyan } else { $cDkGray }
    $fgMeta = if ($Selected) { $cWhite } else { $cDkGray }

    $nameDisplay = $S.Name + $adminTag
    if ($nameDisplay.Length -gt ($ColW.Name - 2)) {
        $nameDisplay = $nameDisplay.Substring(0, $ColW.Name - 2)
    }

    $marker = if ($Selected) { ">" } else { " " }

    $statusText = " $statusIcon $(($S.Status).PadRight(7).Substring(0,7))"
    if ($statusText.Length -gt $ColW.Status) { $statusText = $statusText.Substring(0, $ColW.Status) }

    $addrText = " $($S.Address)"
    if ($addrText.Length -gt $ColW.Addr) { $addrText = $addrText.Substring(0, $ColW.Addr) }

    $pidText = " $($S.PID)"
    if ($pidText.Length -gt $ColW.PID) { $pidText = $pidText.Substring(0, $ColW.PID) }

    $upText = " $($S.Uptime)"
    if ($upText.Length -gt $ColW.Up) { $upText = $upText.Substring(0, $ColW.Up) }

    $idxCell    = ("$($Index.ToString().PadLeft(2))  ")
    $nameCell   = (" $nameDisplay".PadRight($ColW.Name))
    $statusCell = ($statusText.PadRight($ColW.Status))
    $addrCell   = ($addrText.PadRight($ColW.Addr))
    $pidCell    = ($pidText.PadRight($ColW.PID))
    $upCell     = ($upText.PadRight($ColW.Up))

    return (
        "  ${cDkGray}|${cYellow}${marker}${bgSel}${fgIdx}${idxCell}${bgOff}${cDkGray}|" +
        "${bgSel}${fgName}${nameCell}${bgOff}${cDkGray}|" +
        "${bgSel}${statusColor}${statusCell}${bgOff}${cDkGray}|" +
        "${bgSel}${fgAddr}${addrCell}${bgOff}${cDkGray}|" +
        "${bgSel}${fgMeta}${pidCell}${bgOff}${cDkGray}|" +
        "${bgSel}${fgMeta}${upCell}${bgOff}${cDkGray}|${cReset}"
    )
}

function Show-Dashboard {
    param([array]$Statuses, [int]$SelectedIndex = 0, [switch]$InPlace)

    $esc      = [string][char]27
    $cReset   = "$esc[0m"
    $cErase   = "$esc[K"
    $cDkGray  = "$esc[90m"
    $cGray    = "$esc[37m"
    $cWhite   = "$esc[97m"
    $cCyan    = "$esc[96m"
    $cDkCyan  = "$esc[36m"
    $cGreen   = "$esc[92m"
    $cRed     = "$esc[91m"
    $cDkRed   = "$esc[31m"
    $cYellow  = "$esc[93m"
    $cDkYel   = "$esc[33m"
    $cMagenta = "$esc[95m"
    $bgTab    = "$esc[46m"
    $bgOff    = "$esc[49m"

    $running = @($Statuses | Where-Object { $_.Status -eq "RUNNING" }).Count
    $stopped = @($Statuses | Where-Object { $_.Status -eq "STOPPED" }).Count
    $total   = $Statuses.Count
    $time    = (Get-Date).ToString("HH:mm:ss")
    $activeFilter = $script:NodeFilters[$script:CurrentFilterIdx]
    $healColor = if ($script:AutoHealEnabled) { $cGreen } else { $cDkGray }
    $healState = if ($script:AutoHealEnabled) { "ON" } else { "OFF" }

    $allSt = if ($script:LastAllStatuses) { $script:LastAllStatuses } else { $Statuses }
    $homeSt  = @($allSt | Where-Object { $_.NodeLabel -eq "HOME (Local)" })
    $homeUp  = @($homeSt | Where-Object { $_.Status -eq "RUNNING" }).Count
    $homeTot = $homeSt.Count
    $devSt   = @($allSt | Where-Object { $_.NodeLabel -eq "192.168.2.222 (Dev)" })
    $devUp   = @($devSt | Where-Object { $_.Status -eq "RUNNING" }).Count
    $devTot  = $devSt.Count
    $prodSt  = @($allSt | Where-Object { $_.NodeLabel -eq "192.168.2.218 (Produccion)" })
    $prodUp  = @($prodSt | Where-Object { $_.Status -eq "RUNNING" }).Count
    $prodTot = $prodSt.Count
    $hubSt   = @($allSt | Where-Object { $_.NodeLabel -eq "WEB-HUB (.237)" })
    $hubUp   = @($hubSt | Where-Object { $_.Status -eq "RUNNING" }).Count
    $hubTot  = $hubSt.Count
    $bdSt    = @($allSt | Where-Object { $_.NodeLabel -eq "BD-VAULT (.187)" })
    $bdUp    = @($bdSt | Where-Object { $_.Status -eq "RUNNING" }).Count
    $bdTot   = $bdSt.Count

    $bufWidth  = try { [Console]::BufferWidth } catch { 120 }
    $winHeight = try { [Console]::WindowHeight } catch { 45 }

    $leftLines = New-Object System.Collections.Generic.List[string]

    # -- ASCII Art Header --
    $leftLines.Add("")
    $leftLines.Add("    ${cDkCyan} __  __ _____ ____  _     ___ _   _ ${cReset}")
    $leftLines.Add("    ${cDkCyan}|  \/  | ____|  _ \| |   |_ _| \ | |${cReset}")
    $leftLines.Add("    ${cCyan}| |\/| |  _| | |_) | |    | ||  \| |${cReset}")
    $leftLines.Add("    ${cCyan}| |  | | |___|  _ <| |___ | || |\  |${cReset}")
    $leftLines.Add("    ${cDkCyan}|_|  |_|_____|_| \_\_____|___|_| \_|${cReset}")
    $leftLines.Add("")
    $leftLines.Add("    ${cWhite}DEV & PROD SERVER MANAGER (MULTI-NODE)${cDkGray}                          v2.4${cReset}")
    $leftLines.Add("    ${cDkGray}$("_" * 70)${cReset}")

    # -- Summary Bar --
    $leftLines.Add("")
    $summaryPrefix = "    ${cGreen}[*] $running Up${cReset}  ${cRed}[ ] $stopped Down${cReset}  ${cDkGray}Tot:$total${cReset}  ${cCyan}[$activeFilter]${cReset}  ${healColor}Heal:$healState${cReset}  ${cDkGray}$time [${cReset}"
    $visPrefixLen = ([regex]::Replace($summaryPrefix, "\x1b\[[0-9;]*[a-zA-Z]", "")).Length
    $script:ProgressBarRow = $leftLines.Count
    $script:ProgressBarCol = $visPrefixLen
    $leftLines.Add("${summaryPrefix}$(" " * 10)${cDkGray}]${cReset}")

    # -- Multi-Node Selector Bar (HOME <-> .222 <-> .218 <-> .237 <-> .187 <-> ALL via Left/Right Arrows) --
    $tabDefs = @(
        @{ Filter = "HOME (Local)";              Short = "HOME"; Up = $homeUp; Tot = $homeTot },
        @{ Filter = "192.168.2.222 (Dev)";       Short = ".222"; Up = $devUp;  Tot = $devTot  },
        @{ Filter = "192.168.2.218 (Produccion)";Short = ".218"; Up = $prodUp; Tot = $prodTot },
        @{ Filter = "WEB-HUB (.237)";            Short = ".237"; Up = $hubUp;  Tot = $hubTot  },
        @{ Filter = "BD-VAULT (.187)";           Short = ".187"; Up = $bdUp;   Tot = $bdTot   },
        @{ Filter = "ALL";                       Short = "ALL";  Up = @($allSt | Where-Object { $_.Status -eq "RUNNING" }).Count; Tot = $allSt.Count }
    )
    $tabParts = @()
    foreach ($td in $tabDefs) {
        if ($activeFilter -eq $td.Filter) {
            $tabParts += "${bgTab}${cWhite}>$($td.Short)[$($td.Up)/$($td.Tot)]<${bgOff}"
        } else {
            $tCol = if ($td.Up -eq $td.Tot -and $td.Tot -gt 0) { $cGreen } elseif ($td.Up -gt 0) { $cYellow } else { $cDkGray }
            $tabParts += "${cDkGray}$($td.Short)${tCol}[$($td.Up)/$($td.Tot)]${cReset}"
        }
    }
    $leftLines.Add("  ${cCyan}[</>]${cReset} " + ($tabParts -join "${cDkGray}|${cReset}"))

    $colW = @{ Num=5; Name=21; Status=12; Addr=21; PID=7; Up=10 }
    $sep = "  +" + ("-" * $colW.Num) + "+" + ("-" * $colW.Name) + "+" + ("-" * $colW.Status) + "+" + ("-" * $colW.Addr) + "+" + ("-" * $colW.PID) + "+" + ("-" * $colW.Up) + "+"

    $leftLines.Add("${cDkGray}${sep}${cReset}")
    $hdrLine = (
        "  ${cDkGray}|${cCyan}" + (" #".PadRight($colW.Num)) +
        "${cDkGray}|${cCyan}" + (" PROJECT".PadRight($colW.Name)) +
        "${cDkGray}|${cCyan}" + (" STATUS".PadRight($colW.Status)) +
        "${cDkGray}|${cCyan}" + (" ADDRESS".PadRight($colW.Addr)) +
        "${cDkGray}|${cCyan}" + (" PID".PadRight($colW.PID)) +
        "${cDkGray}|${cCyan}" + (" UPTIME/SSH".PadRight($colW.Up)) +
        "${cDkGray}|${cReset}"
    )
    $leftLines.Add($hdrLine)
    $leftLines.Add("${cDkGray}${sep}${cReset}")

    # Smart Viewport Windowing
    $maxVisible = [Math]::Max(8, $winHeight - 23)
    $startIdx = 0
    $endIdx = $Statuses.Count - 1
    if ($Statuses.Count -gt $maxVisible) {
        $half = [Math]::Floor($maxVisible / 2)
        $startIdx = [Math]::Max(0, $SelectedIndex - $half)
        $endIdx = $startIdx + $maxVisible - 1
        if ($endIdx -ge $Statuses.Count) {
            $endIdx = $Statuses.Count - 1
            $startIdx = [Math]::Max(0, $endIdx - $maxVisible + 1)
        }
    }

    for ($i = $startIdx; $i -le $endIdx; $i++) {
        $leftLines.Add((Format-RowAnsi -S $Statuses[$i] -Index ($i + 1) -Selected ($i -eq $SelectedIndex) -ColW $colW))
    }

    $leftLines.Add("${cDkGray}${sep}${cReset}")

    if ($Statuses.Count -gt $maxVisible) {
        $leftLines.Add(("   ${cDkCyan}Showing {0}-{1} of {2} servers (use [</> Arrows] .222/.218 or [Up/Dn] Services)${cReset}" -f ($startIdx + 1), ($endIdx + 1), $Statuses.Count))
    }

    $hasAdmin = $Statuses | Where-Object { $_.NeedsAdmin }
    if ($hasAdmin) {
        $leftLines.Add("   ${cDkYel}* Requires administrator privileges${cReset}")
    }

    $sel = $Statuses[$SelectedIndex]
    $leftLines.Add("")
    $leftLines.Add("  ${cDkGray}+---------------------------------------------------------------------------+${cReset}")
    $descPad = 63 - $sel.Name.Length
    if ($descPad -lt 1) { $descPad = 1 }
    $descStr = (" - $($sel.Description)").PadRight($descPad).Substring(0, $descPad)
    $leftLines.Add("  ${cDkGray}|  Selected: ${cWhite}$($sel.Name)${cDkGray}${descStr}|${cReset}")

    $urlDisplay = if ($sel.Url) {
        if ($sel.ExternalIp -eq "100.90.211.9" -and $sel.Url -match "^http://(localhost|127\.0\.0\.1):(\d+)") {
            "$($sel.Url)  [Tailscale: http://100.90.211.9:$($Matches[2])]"
        } else {
            $sel.Url
        }
    } else { "Endpoint: $($sel.Address)" }
    if ($script:LastHealEvent) {
        $maxUrlRoom = 71 - $script:LastHealEvent.Length
        if ($maxUrlRoom -gt 20 -and $urlDisplay.Length -le $maxUrlRoom) {
            $gap = 73 - $urlDisplay.Length - $script:LastHealEvent.Length
            if ($gap -lt 1) { $gap = 1 }
            $leftLines.Add("  ${cDkGray}|  ${cCyan}${urlDisplay}$(" " * $gap)${cGreen}$($script:LastHealEvent)${cDkGray}|${cReset}")
        } else {
            $urlPad = [Math]::Max(1, 73 - $urlDisplay.Length)
            $leftLines.Add("  ${cDkGray}|  ${cCyan}${urlDisplay}$(" " * $urlPad)${cDkGray}|${cReset}")
        }
    } else {
        $urlPad = [Math]::Max(1, 73 - $urlDisplay.Length)
        $leftLines.Add("  ${cDkGray}|  ${cCyan}${urlDisplay}$(" " * $urlPad)${cDkGray}|${cReset}")
    }
    $leftLines.Add("  ${cDkGray}+---------------------------------------------------------------------------+${cReset}")

    $leftLines.Add("")
    $leftLines.Add("   ${cCyan}[Left/Right]${cGray} .222/.218 ${cWhite}[Up/Dn]${cGray} Nav ${cCyan}[Tab]${cGray} Node ${cWhite}[Enter]${cGray} Menu ${cCyan}[I]${cGray} Info ${cCyan}[O]${cGray} Open ${cGreen}[S]${cGray} Start ${cRed}[K]${cGray} Kill ${cYellow}[R]${cGray} Rst${cReset}")
    $leftLines.Add("   ${cGreen}[G]${cGray} Wake ALL(.222/Home) ${healColor}[W]${cGray} AutoHeal:${healState} ${cCyan}[L]${cGray} Logs ${cCyan}[N]${cGray} New ${cCyan}[E]${cGray} Edit ${cDkYel}[D]${cGray} Del ${cMagenta}[X]${cGray} KillALL ${cDkRed}[Q]${cGray} Quit${cReset}")
    $leftLines.Add("")

    # -- Wizard Art Overlay (right panel, composed into same single frame buffer) --
    $wizardArt = @(
        "                                  ...."
        "                                .'' .'''"
        ".                             .'   :"
        "\                          .:    :"
        " \                        _:    :       ..----.._"
        "  \                    .:::.....:::.. .'         ''."
        "   \                 .'  #-. .-######'     #        '."
        "    \                 '.##'/ ' ################       :"
        "     \                  #####################         :"
        "      \               ..##.-.#### .''''###'.._        :"
        "       \             :--:########:            '.    .' :"
        "        \..__...--.. :--:#######.'   '.         '.     :"
        "        :     :  : : '':'-:'':'::        .         '.  .'"
        "        '---'''..: :    ':    '..'''.      '.        :'"
        "           \  :: : :     '      ''''''.     '.      .:"
        "            \ ::  : :     '            '.      '      :"
        "             \::   : :           ....' ..:       '     '."
        "              \::  : :    .....####\ .~~.:.             :"
        "               \':.:.:.:'#########.===. ~ |.'-.   . '''.. :"
        "                \    .'  ########## \ \ _.' '. '-.       '''."
        "                :\  :     ########   \ \      '.  '-.        :"
        "               :  \'    '   #### :    \ \      :.    '-.      :"
        "              :  .'\   :'  :     :     \ \       :      '-.    :"
        "             : .'  .\  '  :      :     :\ \       :        '.   :"
        "             ::   :  \'  :.      :     : \ \      :          '. :"
        "             ::. :    \  : :      :    ;  \ \     :           '.:"
        "              : ':    '\ :  :     :     :  \:\     :        ..''"
        "                 :    ' \ :        :     ;  \|      :   .'''"
        "                 '.   '  \:                         :.''"
        "                  .:..... \:       :            ..''"
        "                 '._____|'.\......'''''''.:..'''"
        "                            \"
    )

    $wizCol = 88
    $wizRow = 1
    $maxWizLen = $bufWidth - $wizCol - 1
    $sb = New-Object System.Text.StringBuilder 8192

    for ($r = 0; $r -lt $leftLines.Count; $r++) {
        $lText = $leftLines[$r]
        [void]$sb.Append($lText)
        $wIdx = $r - $wizRow
        if ($maxWizLen -gt 10 -and $wIdx -ge 0 -and $wIdx -lt $wizardArt.Count) {
            $visLen = ([regex]::Replace($lText, "\x1b\[[0-9;]*[a-zA-Z]", "")).Length
            $pad = $wizCol - $visLen
            if ($pad -gt 0) {
                [void]$sb.Append((" " * $pad))
            }
            $wLine = $wizardArt[$wIdx]
            if ($wLine.Length -gt $maxWizLen) { $wLine = $wLine.Substring(0, $maxWizLen) }
            $wColor = if ($wIdx -lt 8 -or $wIdx -ge 22) { $cDkCyan } else { $cCyan }
            [void]$sb.Append("${wColor}${wLine}")
        }
        [void]$sb.Append("${cReset}${cErase}`r`n")
    }

    if ($script:LastFrameRows -gt $leftLines.Count) {
        $extraBlank = $script:LastFrameRows - $leftLines.Count
        for ($b = 0; $b -lt $extraBlank; $b++) {
            [void]$sb.Append("${cReset}${cErase}`r`n")
        }
    }
    $script:LastFrameRows   = $leftLines.Count
    $script:DashboardEndRow = $leftLines.Count

    try {
        [Console]::CursorVisible = $false
        if (-not $InPlace -or $bufWidth -ne $script:LastBufWidth -or $winHeight -ne $script:LastWinHeight) {
            [Console]::Clear()
            $script:LastBufWidth  = $bufWidth
            $script:LastWinHeight = $winHeight
        }
        [Console]::SetCursorPosition(0, 0)
        [Console]::Write($sb.ToString())
    } catch {}
}

# --- Info Panel --------------------------------------------------------------

function Show-InfoPanel {
    param($Status, $Project)

    Clear-Host
    $s = $Status
    $statusColor = if ($s.Status -eq "RUNNING") { "Green" } else { "Red" }

    Write-Host ""
    Write-Host "  +======================================================================+" -ForegroundColor DarkCyan
    Write-Host "  |  PROJECT DETAILS                                                     |" -ForegroundColor DarkCyan
    Write-Host "  +======================================================================+" -ForegroundColor DarkCyan
    Write-Host ""

    Write-Host -NoNewline "   Name:          " -ForegroundColor DarkGray
    Write-Host "$($s.Name)" -ForegroundColor White
    Write-Host -NoNewline "   Description:   " -ForegroundColor DarkGray
    Write-Host "$($s.Description)" -ForegroundColor Gray
    Write-Host -NoNewline "   ID:            " -ForegroundColor DarkGray
    Write-Host "$($s.Id)" -ForegroundColor Gray
    Write-Host -NoNewline "   Node:          " -ForegroundColor DarkGray
    Write-Host "$($s.NodeLabel)" -ForegroundColor Cyan
    Write-Host -NoNewline "   Environment:   " -ForegroundColor DarkGray
    $envLabel = if ($s.Environment -eq "prod") { "PRODUCTION" } else { "DEVELOPMENT" }
    $envInfoColor = if ($s.Environment -eq "prod") { "Red" } else { "Cyan" }
    Write-Host "$envLabel" -ForegroundColor $envInfoColor

    Write-Host ""
    Write-Host "  -- Status ---------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host -NoNewline "   Status:        " -ForegroundColor DarkGray
    Write-Host "$($s.Status)" -ForegroundColor $statusColor
    Write-Host -NoNewline "   Address:       " -ForegroundColor DarkGray
    $addrColor = if ($s.Status -eq "RUNNING") { "Cyan" } else { "DarkGray" }
    Write-Host "$($s.Address)" -ForegroundColor $addrColor
    Write-Host -NoNewline "   URL:           " -ForegroundColor DarkGray
    if ($s.Url) { Write-Host "$($s.Url)" -ForegroundColor Cyan } else { Write-Host "-" -ForegroundColor DarkGray }
    Write-Host -NoNewline "   External IP:   " -ForegroundColor DarkGray
    Write-Host "$($s.ExternalIp)" -ForegroundColor Gray
    Write-Host -NoNewline "   PID:           " -ForegroundColor DarkGray
    Write-Host "$($s.PID)" -ForegroundColor Gray
    Write-Host -NoNewline "   Process:       " -ForegroundColor DarkGray
    Write-Host "$($s.ProcessName)" -ForegroundColor Gray
    Write-Host -NoNewline "   Uptime/Host:   " -ForegroundColor DarkGray
    Write-Host "$($s.Uptime)" -ForegroundColor Gray
    Write-Host -NoNewline "   Memory:        " -ForegroundColor DarkGray
    Write-Host "$($s.Memory)" -ForegroundColor Gray
    Write-Host -NoNewline "   CPU Time:      " -ForegroundColor DarkGray
    Write-Host "$($s.CPU)" -ForegroundColor Gray
    Write-Host -NoNewline "   Managed:       " -ForegroundColor DarkGray
    $managedText = if ($s.Managed) { "Yes (started by orchestrator)" } else { "No (external / remote)" }
    Write-Host "$managedText" -ForegroundColor Gray

    Write-Host ""
    Write-Host "  -- Configuration --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host -NoNewline "   Path:          " -ForegroundColor DarkGray
    Write-Host "$($s.Path)" -ForegroundColor Gray
    Write-Host -NoNewline "   Command:       " -ForegroundColor DarkGray
    Write-Host "$($s.Command)" -ForegroundColor Cyan
    Write-Host -NoNewline "   Port:          " -ForegroundColor DarkGray
    Write-Host "$($s.Port)" -ForegroundColor Gray

    $hc = if ($s.HealthCheck) { $s.HealthCheck } else { "(none)" }
    Write-Host -NoNewline "   Health Check:  " -ForegroundColor DarkGray
    Write-Host "$hc" -ForegroundColor Gray

    $admin = if ($s.NeedsAdmin) { "Yes" } else { "No" }
    Write-Host -NoNewline "   Needs Admin:   " -ForegroundColor DarkGray
    Write-Host "$admin" -ForegroundColor $(if ($s.NeedsAdmin) { "Yellow" } else { "Gray" })

    Write-Host ""
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host -NoNewline "  |  " -ForegroundColor DarkGray
    Write-Host -NoNewline "[S]" -ForegroundColor Green
    Write-Host -NoNewline " Start  " -ForegroundColor Gray
    Write-Host -NoNewline "[K]" -ForegroundColor Red
    Write-Host -NoNewline " Kill  " -ForegroundColor Gray
    Write-Host -NoNewline "[R]" -ForegroundColor Yellow
    Write-Host -NoNewline " Restart  " -ForegroundColor Gray
    Write-Host -NoNewline "[O]" -ForegroundColor Cyan
    Write-Host -NoNewline " Open  " -ForegroundColor Gray
    Write-Host -NoNewline "[L]" -ForegroundColor Cyan
    Write-Host -NoNewline " Logs  " -ForegroundColor Gray
    Write-Host -NoNewline "[Esc/B]" -ForegroundColor White
    Write-Host " Back                |" -ForegroundColor Gray
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ""
}

# --- Action Menu -------------------------------------------------------------

function Show-ActionMenu {
    param($Status, $Project)

    Clear-Host
    $s = $Status
    $statusColor = if ($s.Status -eq "RUNNING") { "Green" } else { "Red" }
    $statusIcon  = if ($s.Status -eq "RUNNING") { "[*]" } else { "[ ]" }

    Write-Host ""
    Write-Host "  +======================================================================+" -ForegroundColor DarkCyan
    Write-Host "  |  ACTION MENU                                                         |" -ForegroundColor DarkCyan
    Write-Host "  +======================================================================+" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host -NoNewline "   Project:  " -ForegroundColor DarkGray
    Write-Host "$($s.Name)" -ForegroundColor White
    Write-Host -NoNewline "   Node:     " -ForegroundColor DarkGray
    Write-Host "$($s.NodeLabel)" -ForegroundColor Cyan
    Write-Host -NoNewline "   Status:   " -ForegroundColor DarkGray
    Write-Host "$statusIcon $($s.Status)" -ForegroundColor $statusColor
    Write-Host -NoNewline "   Address:  " -ForegroundColor DarkGray
    Write-Host "$($s.Address)" -ForegroundColor Cyan
    if ($s.Environment -eq "prod") {
        Write-Host -NoNewline "   Env:      " -ForegroundColor DarkGray
        Write-Host "PRODUCTION" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGray

    if ($s.Status -eq "RUNNING") {
        Write-Host "  |                                                                      |" -ForegroundColor DarkGray
        Write-Host -NoNewline "  |   " -ForegroundColor DarkGray
        Write-Host -NoNewline "[K]" -ForegroundColor Red
        Write-Host "  Kill this server                                              |" -ForegroundColor Gray
        Write-Host -NoNewline "  |   " -ForegroundColor DarkGray
        Write-Host -NoNewline "[R]" -ForegroundColor Yellow
        Write-Host "  Restart this server                                           |" -ForegroundColor Gray
    } else {
        Write-Host "  |                                                                      |" -ForegroundColor DarkGray
        Write-Host -NoNewline "  |   " -ForegroundColor DarkGray
        Write-Host -NoNewline "[S]" -ForegroundColor Green
        Write-Host "  Start this server                                             |" -ForegroundColor Gray
    }

    Write-Host -NoNewline "  |   " -ForegroundColor DarkGray
    Write-Host -NoNewline "[L]" -ForegroundColor Cyan
    Write-Host "  View logs                                                     |" -ForegroundColor Gray
    Write-Host -NoNewline "  |   " -ForegroundColor DarkGray
    Write-Host -NoNewline "[I]" -ForegroundColor Magenta
    Write-Host "  Detailed info                                                 |" -ForegroundColor Gray
    Write-Host "  |                                                                      |" -ForegroundColor DarkGray
    Write-Host -NoNewline "  |   " -ForegroundColor DarkGray
    Write-Host -NoNewline "[Esc/B]" -ForegroundColor White
    Write-Host "  Back to dashboard                                         |" -ForegroundColor Gray
    Write-Host "  |                                                                      |" -ForegroundColor DarkGray
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ""
}

# --- Logs Viewer -------------------------------------------------------------

function Show-Logs {
    param($Project, [int]$Lines = 30)

    Clear-Host
    Write-Host ""
    Write-Host "  +======================================================================+" -ForegroundColor DarkCyan
    Write-Host "  |  LOGS: $($Project.name.PadRight(63))|" -ForegroundColor DarkCyan
    Write-Host "  +======================================================================+" -ForegroundColor DarkCyan

    $remoteNode = Get-RemoteNodeInfo -Project $Project
    if ($null -ne $remoteNode) {
        Write-Host ""
        Write-Host "  Fetching remote logs from $($remoteNode.Label) ($($remoteNode.Alias))..." -ForegroundColor DarkCyan
        $remLogDir = $remoteNode.LogDir
        $id = $Project.id
        $psTemplate = @'
$ErrorActionPreference = 'SilentlyContinue'
$outFile = Join-Path '__LOG_DIR__' '__ID___stdout.log'
$errFile = Join-Path '__LOG_DIR__' '__ID___stderr.log'
Write-Output '===STDOUT==='
if (Test-Path $outFile) { Get-Content $outFile -Tail __LINES__ } else { Write-Output '(no remote stdout log file)' }
Write-Output '===STDERR==='
if (Test-Path $errFile) { Get-Content $errFile -Tail __LINES__ } else { Write-Output '(no remote stderr log file)' }
'@
        $psCode = $psTemplate.
            Replace('__LOG_DIR__', $remLogDir.Replace("'", "''")).
            Replace('__ID__', $id.Replace("'", "''")).
            Replace('__LINES__', "$Lines")
        $raw = Invoke-RemoteNodePowerShell -Alias $remoteNode.Alias -ScriptBlockText $psCode -TimeoutSecs 6
        $parts = $raw -split '===STDERR==='
        $stdoutPart = ($parts[0] -replace '===STDOUT===', '').Trim()
        $stderrPart = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "(empty)" }

        Write-Host ""
        Write-Host "  -- stdout ($($remoteNode.Alias)) -----------------------------------------------------" -ForegroundColor DarkGray
        if ($stdoutPart) {
            ($stdoutPart -split "`r?`n") | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        } else {
            Write-Host "  (empty)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "  -- stderr ($($remoteNode.Alias)) -----------------------------------------------------" -ForegroundColor DarkGray
        if ($stderrPart) {
            ($stderrPart -split "`r?`n") | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
        } else {
            Write-Host "  (empty)" -ForegroundColor DarkGray
        }
        Write-Host ""
        return
    }

    $logOut = Join-Path $LogDir "$($Project.id)_stdout.log"
    $logErr = Join-Path $LogDir "$($Project.id)_stderr.log"

    Write-Host ""
    Write-Host "  -- stdout ---------------------------------------------------------------" -ForegroundColor DarkGray
    if (Test-Path $logOut) {
        $content = Get-Content $logOut -Tail $Lines -ErrorAction SilentlyContinue
        if ($content) {
            $content | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        } else {
            Write-Host "  (empty)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  (no log file)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  -- stderr ---------------------------------------------------------------" -ForegroundColor DarkGray
    if (Test-Path $logErr) {
        $content = Get-Content $logErr -Tail $Lines -ErrorAction SilentlyContinue
        if ($content) {
            $content | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
        } else {
            Write-Host "  (empty)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  (no log file)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# --- Sub-screen handler ------------------------------------------------------

function Handle-SubScreen {
    param([string]$Screen, $Project, $Status)

    while ($true) {
        Write-Host -NoNewline "  > " -ForegroundColor Cyan
        $key = Read-ConsoleKey -Intercept $true
        if ($null -eq $key) { continue }
        $ch = [char]::ToUpper($key.KeyChar)

        if ($key.Key -eq "Escape" -or $ch -eq "B") { return }

        switch ($ch) {
            "S" {
                Write-Host ""
                if (-not (Confirm-ProductionAction -ActionName "START" -Project $Project)) {
                    Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                    $null = Read-ConsoleKey -Intercept $true
                    if ($Screen -eq "info") { Show-InfoPanel -Status $Status -Project $Project }
                    elseif ($Screen -eq "action") { Show-ActionMenu -Status $Status -Project $Project }
                    continue
                }
                Start-Project -Project $Project
                Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                $null = Read-ConsoleKey -Intercept $true
                $newStatus = @(Refresh-AllStatuses -Projects @($Project) -ForceSsh)[0]
                $Status = $newStatus
                if ($Screen -eq "info") { Show-InfoPanel -Status $newStatus -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $newStatus -Project $Project }
            }
            "K" {
                Write-Host ""
                if ($Project.environment -eq "prod") {
                    if (-not (Confirm-ProductionAction -ActionName "KILL" -Project $Project)) {
                        Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                        $null = Read-ConsoleKey -Intercept $true
                        if ($Screen -eq "info") { Show-InfoPanel -Status $Status -Project $Project }
                        elseif ($Screen -eq "action") { Show-ActionMenu -Status $Status -Project $Project }
                        continue
                    }
                    Stop-Project -Project $Project
                } else {
                    Write-Host -NoNewline "  Kill $($Project.name)? (y/N): " -ForegroundColor Red
                    $confirm = Read-ConsoleKey -Intercept $true
                    Write-Host $confirm.KeyChar
                    if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                        Stop-Project -Project $Project
                    } else { Write-Host "  Cancelled." -ForegroundColor DarkGray }
                }
                Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                $null = Read-ConsoleKey -Intercept $true
                $newStatus = @(Refresh-AllStatuses -Projects @($Project) -ForceSsh)[0]
                $Status = $newStatus
                if ($Screen -eq "info") { Show-InfoPanel -Status $newStatus -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $newStatus -Project $Project }
            }
            "R" {
                Write-Host ""
                if ($Project.environment -eq "prod") {
                    if (-not (Confirm-ProductionAction -ActionName "RESTART" -Project $Project)) {
                        Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                        $null = Read-ConsoleKey -Intercept $true
                        if ($Screen -eq "info") { Show-InfoPanel -Status $Status -Project $Project }
                        elseif ($Screen -eq "action") { Show-ActionMenu -Status $Status -Project $Project }
                        continue
                    }
                    Restart-Project -Project $Project
                } else {
                    Write-Host -NoNewline "  Restart $($Project.name)? (y/N): " -ForegroundColor Yellow
                    $confirm = Read-ConsoleKey -Intercept $true
                    Write-Host $confirm.KeyChar
                    if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                        Restart-Project -Project $Project
                    } else { Write-Host "  Cancelled." -ForegroundColor DarkGray }
                }
                Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                $null = Read-ConsoleKey -Intercept $true
                $newStatus = @(Refresh-AllStatuses -Projects @($Project) -ForceSsh)[0]
                $Status = $newStatus
                if ($Screen -eq "info") { Show-InfoPanel -Status $newStatus -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $newStatus -Project $Project }
            }
            "L" {
                Show-Logs -Project $Project
                Write-Host "  Press any key to go back..." -ForegroundColor DarkGray
                $null = Read-ConsoleKey -Intercept $true
                if ($Screen -eq "info") { Show-InfoPanel -Status $Status -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $Status -Project $Project }
            }
            "I" {
                if ($Screen -ne "info") {
                    Show-InfoPanel -Status $Status -Project $Project
                    Handle-SubScreen -Screen "info" -Project $Project -Status $Status
                    return
                }
            }
            "O" {
                if ($Status.Url) {
                    Write-Host "  Opening $($Status.Url) ..." -ForegroundColor Cyan
                    Start-Process $Status.Url
                    Start-Sleep -Milliseconds 800
                } else {
                    Write-Host "  No URL available." -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 800
                }
                if ($Screen -eq "info") { Show-InfoPanel -Status $Status -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $Status -Project $Project }
            }
        }
    }
}

# --- Main Loop ---------------------------------------------------------------

function Get-FilteredProjectsAndStatuses {
    param([array]$AllProjects, [array]$AllStatuses)
    $filter = $script:NodeFilters[$script:CurrentFilterIdx]
    if ($filter -eq "ALL") {
        if ($script:LocalNodeLabel) {
            $localP = @(); $localS = @()
            $otherP = @(); $otherS = @()
            for ($i = 0; $i -lt $AllStatuses.Count; $i++) {
                if ($AllStatuses[$i].NodeLabel -eq $script:LocalNodeLabel) {
                    $localP += $AllProjects[$i]
                    $localS += $AllStatuses[$i]
                } else {
                    $otherP += $AllProjects[$i]
                    $otherS += $AllStatuses[$i]
                }
            }
            return @{ Projects = ($localP + $otherP); Statuses = ($localS + $otherS) }
        }
        return @{ Projects = $AllProjects; Statuses = $AllStatuses }
    }
    $fp = @()
    $fs = @()
    for ($i = 0; $i -lt $AllStatuses.Count; $i++) {
        if ($AllStatuses[$i].NodeLabel -eq $filter) {
            $fp += $AllProjects[$i]
            $fs += $AllStatuses[$i]
        }
    }
    if ($fs.Count -eq 0) {
        return @{ Projects = $AllProjects; Statuses = $AllStatuses }
    }
    return @{ Projects = $fp; Statuses = $fs }
}

function Main {
    $config = Load-Config
    $allProjects = @($config.projects)

    if (-not $allProjects -or $allProjects.Count -eq 0) {
        Write-Host "  No projects configured in $ConfigFile" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "  [*] Initializing Merlin Multi-Server Orchestrator v2.4..." -ForegroundColor Cyan
    $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
    $null = Invoke-AutoHealPass -AllProjects $allProjects -AllStatuses $allStatuses
    $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
    $projects = $view.Projects
    $statuses = $view.Statuses

    $selectedIdx = 0
    $maxIdx = $projects.Count - 1

    Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx

    $esc = [string][char]27
    while ($true) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $keyPressed = $false
        $lastProgress = -1

        while ($stopwatch.Elapsed.TotalSeconds -lt $RefreshSecs) {
            if (Test-KeyAvailable) {
                $keyPressed = $true
                break
            }
            Collect-AsyncRemotePortScans -WaitMs 0
            $progress = [int][math]::Floor(($stopwatch.Elapsed.TotalSeconds / $RefreshSecs) * 10)
            if ($progress -gt 10) { $progress = 10 }
            if ($progress -ne $lastProgress) {
                $lastProgress = $progress
                try {
                    [Console]::CursorVisible = $false
                    [Console]::SetCursorPosition($script:ProgressBarCol, $script:ProgressBarRow)
                    [Console]::Write("$esc[96m" + ("*" * $progress) + (" " * (10 - $progress)) + "$esc[0m")
                } catch {}
            }
            Start-Sleep -Milliseconds 60
        }
        $stopwatch.Stop()

        if (-not $keyPressed) {
            $allStatuses = Refresh-AllStatuses -Projects $allProjects
            $null = Invoke-AutoHealPass -AllProjects $allProjects -AllStatuses $allStatuses
            $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
            $projects = $view.Projects
            $statuses = $view.Statuses
            $maxIdx = $projects.Count - 1
            if ($selectedIdx -gt $maxIdx) { $selectedIdx = $maxIdx }
            Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            continue
        }

        $key = Read-ConsoleKey -Intercept $true
        if ($null -eq $key) { continue }
        $ch = [char]::ToUpper($key.KeyChar)

        switch ($key.Key) {
            "LeftArrow" {
                $script:CurrentFilterIdx = ($script:CurrentFilterIdx - 1 + $script:NodeFilters.Count) % $script:NodeFilters.Count
                $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                $projects = $view.Projects
                $statuses = $view.Statuses
                $selectedIdx = 0
                $maxIdx = $projects.Count - 1
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            }
            "RightArrow" {
                $script:CurrentFilterIdx = ($script:CurrentFilterIdx + 1) % $script:NodeFilters.Count
                $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                $projects = $view.Projects
                $statuses = $view.Statuses
                $selectedIdx = 0
                $maxIdx = $projects.Count - 1
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            }
            "UpArrow" {
                $selectedIdx = if ($selectedIdx -gt 0) { $selectedIdx - 1 } else { $maxIdx }
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            }
            "DownArrow" {
                $selectedIdx = if ($selectedIdx -lt $maxIdx) { $selectedIdx + 1 } else { 0 }
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            }
            "Tab" {
                $script:CurrentFilterIdx = ($script:CurrentFilterIdx + 1) % $script:NodeFilters.Count
                $allStatuses = Refresh-AllStatuses -Projects $allProjects
                $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                $projects = $view.Projects
                $statuses = $view.Statuses
                $selectedIdx = 0
                $maxIdx = $projects.Count - 1
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            }
            "Enter" {
                $selProject = $projects[$selectedIdx]
                $selStatus  = $statuses[$selectedIdx]
                Show-ActionMenu -Status $selStatus -Project $selProject
                Handle-SubScreen -Screen "action" -Project $selProject -Status $selStatus
                $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                $projects = $view.Projects
                $statuses = $view.Statuses
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
            }
            default {
                $selProject = $projects[$selectedIdx]

                switch ($ch) {
                    "Q" {
                        try {
                            if ($null -ne $script:DashboardEndRow) {
                                [Console]::SetCursorPosition(0, $script:DashboardEndRow)
                            }
                            [Console]::CursorVisible = $true
                        } catch {}
                        Write-Host ""
                        Write-Host "  Goodbye!" -ForegroundColor Cyan
                        Write-Host ""
                        return
                    }
                    "A" {
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $null = Invoke-AutoHealPass -AllProjects $allProjects -AllStatuses $allStatuses
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
                    }
                    "W" {
                        $script:AutoHealEnabled = -not $script:AutoHealEnabled
                        $stateLabel = if ($script:AutoHealEnabled) { "ON" } else { "OFF" }
                        $script:LastHealEvent = "Auto-Heal set to $stateLabel ($(Get-Date -Format 'HH:mm:ss'))"
                        if ($script:AutoHealEnabled) {
                            $null = Invoke-AutoHealPass -AllProjects $allProjects -AllStatuses $allStatuses
                        }
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
                    }
                    "G" {
                        try {
                            if ($null -ne $script:DashboardEndRow) {
                                [Console]::SetCursorPosition(0, $script:DashboardEndRow)
                            }
                        } catch {}
                        Invoke-WakeAll218 -AllProjects $allProjects
                        Write-Host "  Press any key to refresh dashboard..." -ForegroundColor DarkGray
                        $null = Read-ConsoleKey -Intercept $true
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "E" {
                        Write-Host ""
                        Write-Host "  Rename Project: $($selProject.name)" -ForegroundColor Yellow
                        Write-Host -NoNewline "  Enter new name (leave empty to cancel): " -ForegroundColor Cyan
                        $newName = Read-Host
                        if (-not [string]::IsNullOrWhiteSpace($newName)) {
                            $targetObj = $config.projects | Where-Object { $_.id -eq $selProject.id } | Select-Object -First 1
                            if ($targetObj) { $targetObj.name = $newName.Trim() }
                            Save-Config -Config $config
                            $allProjects = @($config.projects)
                            Write-Host "  Renamed successfully!" -ForegroundColor Green
                            Start-Sleep -Milliseconds 800
                        }
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "+" {
                        if ($script:CurrentFilterIdx -eq 0 -and $selectedIdx -gt 0) {
                            $temp = $config.projects[$selectedIdx]
                            $config.projects[$selectedIdx] = $config.projects[$selectedIdx - 1]
                            $config.projects[$selectedIdx - 1] = $temp
                            $selectedIdx--
                            Save-Config -Config $config
                            $allProjects = @($config.projects)
                            $allStatuses = Refresh-AllStatuses -Projects $allProjects
                            $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                            $projects = $view.Projects
                            $statuses = $view.Statuses
                            Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
                        }
                    }
                    "-" {
                        if ($script:CurrentFilterIdx -eq 0 -and $selectedIdx -lt $maxIdx) {
                            $temp = $config.projects[$selectedIdx]
                            $config.projects[$selectedIdx] = $config.projects[$selectedIdx + 1]
                            $config.projects[$selectedIdx + 1] = $temp
                            $selectedIdx++
                            Save-Config -Config $config
                            $allProjects = @($config.projects)
                            $allStatuses = Refresh-AllStatuses -Projects $allProjects
                            $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                            $projects = $view.Projects
                            $statuses = $view.Statuses
                            Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
                        }
                    }
                    "I" {
                        $selStatus = $statuses[$selectedIdx]
                        Show-InfoPanel -Status $selStatus -Project $selProject
                        Handle-SubScreen -Screen "info" -Project $selProject -Status $selStatus
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "S" {
                        Write-Host ""
                        if (-not (Confirm-ProductionAction -ActionName "START" -Project $selProject)) {
                            Start-Sleep -Milliseconds 500
                            Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                            continue
                        }
                        Start-Project -Project $selProject
                        Start-Sleep -Milliseconds 800
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "K" {
                        if ($selProject.environment -eq "prod") {
                            if (-not (Confirm-ProductionAction -ActionName "KILL" -Project $selProject)) {
                                Start-Sleep -Milliseconds 500
                                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                                continue
                            }
                            Stop-Project -Project $selProject
                        } else {
                            Write-Host -NoNewline "  Kill $($selProject.name)? (y/N): " -ForegroundColor Red
                            $confirm = Read-ConsoleKey -Intercept $true
                            Write-Host $confirm.KeyChar
                            if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                                Stop-Project -Project $selProject
                            }
                        }
                        Start-Sleep -Milliseconds 500
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "R" {
                        if ($selProject.environment -eq "prod") {
                            if (-not (Confirm-ProductionAction -ActionName "RESTART" -Project $selProject)) {
                                Start-Sleep -Milliseconds 500
                                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                                continue
                            }
                            Restart-Project -Project $selProject
                        } else {
                            Write-Host -NoNewline "  Restart $($selProject.name)? (y/N): " -ForegroundColor Yellow
                            $confirm = Read-ConsoleKey -Intercept $true
                            Write-Host $confirm.KeyChar
                            if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                                Restart-Project -Project $selProject
                            }
                        }
                        Start-Sleep -Milliseconds 500
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "L" {
                        Show-Logs -Project $selProject
                        Write-Host "  Press any key to go back..." -ForegroundColor DarkGray
                        $null = Read-ConsoleKey -Intercept $true
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "O" {
                        $selStatus = $statuses[$selectedIdx]
                        if ($selStatus.Url) {
                            Write-Host "  Opening $($selStatus.Url) ..." -ForegroundColor Cyan
                            Start-Process $selStatus.Url
                            Start-Sleep -Milliseconds 500
                        } else {
                            Write-Host "  No URL available for this project." -ForegroundColor Yellow
                            Start-Sleep -Milliseconds 800
                        }
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "X" {
                        Write-Host ""
                        Write-Host "  KILL ALL servers in current view? This will terminate EVERY process" -ForegroundColor Red
                        Write-Host "  on configured ports, including zombie processes." -ForegroundColor Red
                        Write-Host -NoNewline "  Type YES to confirm: " -ForegroundColor Red
                        $confirm = Read-Host
                        if ($confirm -eq "YES") {
                            Kill-AllProjects -Projects $projects
                            Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
                            $null = Read-ConsoleKey -Intercept $true
                        } else {
                            Write-Host "  Cancelled." -ForegroundColor DarkGray
                            Start-Sleep -Milliseconds 500
                        }
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "N" {
                        Write-Host ""
                        Write-Host "  --- Add New Project ---" -ForegroundColor Cyan
                        $newId = Read-Host "  ID (e.g. my-app)"
                        if ([string]::IsNullOrWhiteSpace($newId)) { Write-Host "  Cancelled."; Start-Sleep -Milliseconds 500; continue }
                        $newName = Read-Host "  Name (e.g. My App)"
                        $newDesc = Read-Host "  Description"
                        $newPath = Read-Host "  Path (e.g. C:/Users/...)"
                        $newCmd = Read-Host "  Command (e.g. npm run dev)"
                        $newPortStr = Read-Host "  Port (e.g. 3000, optional)"
                        $newExtIp = Read-Host "  External IP (default 127.0.0.1)"
                        if ([string]::IsNullOrWhiteSpace($newExtIp)) { $newExtIp = "127.0.0.1" }

                        $newPort = $null
                        if (-not [string]::IsNullOrWhiteSpace($newPortStr)) { $newPort = [int]$newPortStr }

                        $newProjects = @($config.projects) + [PSCustomObject]@{
                            id = $newId
                            name = $newName
                            description = $newDesc
                            path = $newPath
                            command = $newCmd
                            port = $newPort
                            host = "0.0.0.0"
                            external_ip = $newExtIp
                            color = "#ffffff"
                            requires_admin = $false
                            environment = "dev"
                        }
                        $config.projects = $newProjects
                        Save-Config -Config $config
                        $allProjects = @($config.projects)
                        Write-Host "  Project added successfully!" -ForegroundColor Green
                        Start-Sleep -Milliseconds 800
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        $maxIdx = $projects.Count - 1
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "D" {
                        Write-Host ""
                        Write-Host -NoNewline "  DELETE project '$($selProject.name)' from config? (y/N): " -ForegroundColor Red
                        $confirm = Read-ConsoleKey -Intercept $true
                        Write-Host $confirm.KeyChar
                        if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                            if ($statuses[$selectedIdx].Status -eq "RUNNING") {
                                Stop-Project -Project $selProject
                            }
                            $newProjects = @($config.projects | Where-Object { $_.id -ne $selProject.id })
                            $config.projects = $newProjects
                            Save-Config -Config $config
                            $allProjects = @($config.projects)
                            Write-Host "  Project deleted." -ForegroundColor Green
                            Start-Sleep -Milliseconds 800
                        } else {
                            Write-Host "  Cancelled." -ForegroundColor DarkGray
                            Start-Sleep -Milliseconds 500
                        }
                        $allStatuses = Refresh-AllStatuses -Projects $allProjects -ForceSsh
                        $view = Get-FilteredProjectsAndStatuses -AllProjects $allProjects -AllStatuses $allStatuses
                        $projects = $view.Projects
                        $statuses = $view.Statuses
                        $maxIdx = $projects.Count - 1
                        if ($selectedIdx -gt $maxIdx) { $selectedIdx = $maxIdx }
                        if ($selectedIdx -lt 0) { $selectedIdx = 0 }
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                }
            }
        }
    }
}

# --- Entry Point -------------------------------------------------------------

$Host.UI.RawUI.WindowTitle = "Merlin v2.3 - Multi-Server Manager"
Main
