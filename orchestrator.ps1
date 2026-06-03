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

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile  = Join-Path $ScriptDir "projects.json"
$LogDir      = Join-Path $ScriptDir "logs"
$RefreshSecs = 4

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

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

# --- Process Helpers ---------------------------------------------------------

$script:ManagedPIDs = @{}

function Get-AllListeningPorts {
    <# Batch-fetch all listening TCP connections once. Returns hashtable: port(int) -> PID(int) #>
    $map = @{}

    # Method 1: Get-NetTCPConnection (fast)
    # IMPORTANT: LocalPort is UInt16 — cast to [int] so ContainsKey([int]$port) matches.
    try {
        $conns = Get-NetTCPConnection -State Listen -ErrorAction Stop
        if ($conns -and $conns.Count -gt 0) {
            foreach ($c in $conns) {
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
            if ("$line" -match 'TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)') {
                $p = [int]$Matches[1]
                $pid_ = [int]$Matches[2]
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
        $uptime = (Get-Date) - $proc.StartTime
        return @{
            PID          = $Pid_
            CPU_Seconds  = [math]::Round($proc.CPU, 1)
            Memory_MB    = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            UptimeStr    = ("{0:D2}h {1:D2}m" -f [int]$uptime.TotalHours, $uptime.Minutes)
            ProcessName  = $proc.ProcessName
        }
    } catch {
        return $null
    }
}

function Get-ProjectStatus {
    <# Returns status for a single project. $PortMap is the pre-fetched listening-ports table. #>
    param($Project, [hashtable]$PortMap)

    $port = $Project.port
    $pid_ = $null
    $status = "STOPPED"
    $managed = $false
    $metrics = $null
    $isSSH = [bool]$Project.ssh -and [bool]$Project.ssh.enabled

    if ($isSSH) {
        # Remote project: check via SSH status_command
        $sshTarget = "$($Project.ssh.user)@$($Project.ssh.host)"
        $statusCmd = $Project.ssh.status_command
        try {
            $result = ssh -o ConnectTimeout=2 -o BatchMode=yes $sshTarget $statusCmd 2>$null
            if ($LASTEXITCODE -eq 0 -and $result) {
                $status = "RUNNING"
                $pid_ = ($result -split "`n" | Select-Object -First 1).Trim()
            }
        } catch {}

        # Fallback: if SSH status check returned STOPPED, but a port is defined,
        # perform a lightweight TCP port check to see if the service is active.
        if ($status -eq "STOPPED" -and $port) {
            $targetHost = if ($Project.ssh.host) { $Project.ssh.host } else { $Project.external_ip }
            if ($targetHost) {
                try {
                    $tcpClient = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcpClient.BeginConnect($targetHost, [int]$port, $null, $null)
                    $success = $connect.AsyncWaitHandle.WaitOne(800) # 800ms timeout
                    if ($success) {
                        $tcpClient.EndConnect($connect)
                        $status = "RUNNING"
                        $pid_ = "remote"
                    }
                    $tcpClient.Close()
                } catch {}
            }
        }
    } else {
        # Local project
        # 1. Check managed PID
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

        # 2. Check port map (no extra network call)
        if (-not $pid_ -and $port -and $PortMap.ContainsKey([int]$port)) {
            $pid_ = $PortMap[[int]$port]
            $status = "RUNNING"
        }

        if ($pid_) {
            $metrics = Get-ProcessMetrics -Pid_ $pid_
        }
    }

    # Use external_ip if available, otherwise fall back to host
    $extIp = $Project.external_ip
    $displayHost = if ($extIp) { $extIp } elseif ($Project.host -eq "0.0.0.0") { "localhost" } else { $Project.host }
    $address = if ($port) { "${displayHost}:${port}" } else { "N/A" }
    $url = if ($port) { "http://${displayHost}:${port}" } else { $null }

    return [PSCustomObject]@{
        Id          = $Project.id
        Name        = $Project.name
        Description = $Project.description
        Status      = $status
        Address     = $address
        Url         = $url
        Port        = $port
        Path        = $Project.path
        Command     = if ($isSSH) { "[SSH] $($Project.ssh.start_command)" } else { $Project.command }
        HealthCheck = $Project.health_check
        ExternalIp  = if ($extIp) { $extIp } else { "-" }
        PID         = if ($pid_) { $pid_ } else { "-" }
        Uptime      = if ($metrics) { $metrics.UptimeStr } else { "-" }
        Memory      = if ($metrics) { "$($metrics.Memory_MB) MB" } else { "-" }
        CPU         = if ($metrics) { "$($metrics.CPU_Seconds)s" } else { "-" }
        ProcessName = if ($metrics) { $metrics.ProcessName } else { if ($isSSH) { "remote" } else { "-" } }
        Managed     = $managed
        NeedsAdmin  = [bool]$Project.requires_admin
        IsSSH       = $isSSH
    }
}

function Refresh-AllStatuses {
    <# Single batch refresh: one port scan, then per-project status. #>
    param($Projects)
    $portMap = Get-AllListeningPorts
    return @($Projects | ForEach-Object { Get-ProjectStatus -Project $_ -PortMap $portMap })
}

# --- Actions -----------------------------------------------------------------

function Start-Project {
    param($Project)

    $isSSH = [bool]$Project.ssh -and [bool]$Project.ssh.enabled

    if ($isSSH) {
        Start-SSHProject -Project $Project
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
        # Normalize forward slashes to backslashes for cmd.exe compatibility
        # (cmd.exe treats / as switch prefix, breaking paths like .venv/Scripts/python.exe)
        $cmdNormalized = $command.Replace('/', '\')

        # Use cmd.exe /c to launch any command reliably.
        # This handles .cmd (npm), .bat, .exe, .py, etc. natively because
        # cmd.exe resolves PATHEXT extensions automatically.
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

        # Verify it started
        Start-Sleep -Seconds 1
        $checkResult = ssh -o ConnectTimeout=3 -o BatchMode=yes $sshTarget $ssh.status_command 2>$null
        if ($LASTEXITCODE -eq 0 -and $checkResult) {
            Write-Host " OK (Remote PID $($checkResult.Trim()))" -ForegroundColor Green
        } else {
            # Try TCP check as verification fallback
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

    $port = $Project.port
    $targetPid = $null

    if ($script:ManagedPIDs.ContainsKey($Project.id)) {
        $targetPid = $script:ManagedPIDs[$Project.id]
    } elseif ($port) {
        $portMap = Get-AllListeningPorts
        if ($portMap.ContainsKey([int]$port)) { $targetPid = $portMap[[int]$port] }
    }

    if (-not $targetPid) {
        Write-Host "  No running process found for $($Project.name)." -ForegroundColor Yellow
        return
    }

    Write-Host "  Killing $($Project.name) (PID $targetPid)..." -ForegroundColor Yellow -NoNewline

    try {
        # Kill process tree
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

        # Verify it stopped
        Start-Sleep -Seconds 1
        $checkResult = ssh -o ConnectTimeout=3 -o BatchMode=yes $sshTarget $ssh.status_command 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $checkResult) {
            # Let's also check if the port is actually closed
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

function Kill-AllProjects {
    <# Kills every process on every configured port, including zombies. #>
    param($Projects)

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

        # Handle SSH projects separately
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

        $port = $proj.port
        $pidsToKill = @()

        # Collect managed PID
        if ($script:ManagedPIDs.ContainsKey($proj.id)) {
            $pidsToKill += $script:ManagedPIDs[$proj.id]
        }

        # Collect port PID (may be a zombie not in managed list)
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
                # Get full process tree
                $children = @()
                try {
                    $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                                Where-Object { $_.ParentProcessId -eq $pid_ } |
                                Select-Object -ExpandProperty ProcessId
                } catch {}

                # Kill children
                foreach ($childPid in $children) {
                    try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
                }

                # Kill parent
                Stop-Process -Id $pid_ -Force -ErrorAction Stop
                $killed++
                Write-Host " KILLED" -ForegroundColor Green
            } catch {
                # Maybe already dead
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

    # Second pass: scan for any remaining zombies on configured ports
    Write-Host ""
    Write-Host "  Scanning for remaining zombies..." -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 500
    $portMap2 = Get-AllListeningPorts
    $zombies = 0

    foreach ($proj in $Projects) {
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

function Write-Row {
    param($S, [int]$Index, [bool]$Selected, $ColW)

    $statusColor = if ($S.Status -eq "RUNNING") { "Green" } else { "Red" }
    $statusIcon  = if ($S.Status -eq "RUNNING") { "[*]" } else { "[ ]" }
    $adminTag    = if ($S.NeedsAdmin) { "*" } else { "" }

    $fgIdx    = if ($Selected) { "Yellow"   } else { "White" }
    $fgName   = if ($Selected) { "White"    } else { "White" }
    $fgAddr   = if ($S.Status -eq "RUNNING") { "Cyan" } else { "DarkGray" }
    $fgMeta   = if ($Selected) { "White" } else { "DarkGray" }

    $nameDisplay = $S.Name + $adminTag
    if ($nameDisplay.Length -gt ($ColW.Name - 2)) {
        $nameDisplay = $nameDisplay.Substring(0, $ColW.Name - 2)
    }

    $marker = if ($Selected) { ">" } else { " " }
    $params = @{}
    if ($Selected) { $params["BackgroundColor"] = "DarkCyan" }

    Write-Host -NoNewline "  |" -ForegroundColor DarkGray
    Write-Host -NoNewline "$marker" -ForegroundColor Yellow
    Write-Host -NoNewline ("$($Index.ToString().PadLeft(2))  ") @params -ForegroundColor $fgIdx
    Write-Host -NoNewline "|" -ForegroundColor DarkGray
    Write-Host -NoNewline (" $nameDisplay".PadRight($ColW.Name)) @params -ForegroundColor $fgName
    Write-Host -NoNewline "|" -ForegroundColor DarkGray

    $statusText = " $statusIcon $(($S.Status).PadRight(7).Substring(0,7))"
    if ($statusText.Length -gt $ColW.Status) { $statusText = $statusText.Substring(0, $ColW.Status) }
    Write-Host -NoNewline ($statusText.PadRight($ColW.Status)) @params -ForegroundColor $statusColor
    Write-Host -NoNewline "|" -ForegroundColor DarkGray

    $addrText = " $($S.Address)"
    if ($addrText.Length -gt $ColW.Addr) { $addrText = $addrText.Substring(0, $ColW.Addr) }
    Write-Host -NoNewline ($addrText.PadRight($ColW.Addr)) @params -ForegroundColor $fgAddr
    Write-Host -NoNewline "|" -ForegroundColor DarkGray

    $pidText = " $($S.PID)"
    if ($pidText.Length -gt $ColW.PID) { $pidText = $pidText.Substring(0, $ColW.PID) }
    Write-Host -NoNewline ($pidText.PadRight($ColW.PID)) @params -ForegroundColor $fgMeta
    Write-Host -NoNewline "|" -ForegroundColor DarkGray

    $upText = " $($S.Uptime)"
    if ($upText.Length -gt $ColW.Up) { $upText = $upText.Substring(0, $ColW.Up) }
    Write-Host -NoNewline ($upText.PadRight($ColW.Up)) @params -ForegroundColor $fgMeta
    Write-Host "|" -ForegroundColor DarkGray
}

function Show-Dashboard {
    param($Statuses, [int]$SelectedIndex = 0, [switch]$InPlace)

    $running = ($Statuses | Where-Object { $_.Status -eq "RUNNING" }).Count
    $stopped = ($Statuses | Where-Object { $_.Status -eq "STOPPED" }).Count
    $total   = $Statuses.Count
    $time    = (Get-Date).ToString("HH:mm:ss")

    [Console]::CursorVisible = $false
    if ($InPlace) {
        [Console]::SetCursorPosition(0, 0)
    } else {
        Clear-Host
    }

    # -- ASCII Art Header --
    Write-Host ""
    Write-Host '     __  __ _____ ____  _     ___ _   _ ' -ForegroundColor DarkCyan
    Write-Host '    |  \/  | ____|  _ \| |   |_ _| \ | |' -ForegroundColor DarkCyan
    Write-Host '    | |\/| |  _| | |_) | |    | ||  \| |' -ForegroundColor Cyan
    Write-Host '    | |  | | |___|  _ <| |___ | || |\  |' -ForegroundColor Cyan
    Write-Host '    |_|  |_|_____|_| \_\_____|___|_| \_|' -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host -NoNewline "    DEV SERVER MANAGER" -ForegroundColor White
    Write-Host -NoNewline "                                               " -ForegroundColor DarkGray
    Write-Host "v2.2" -ForegroundColor DarkGray
    Write-Host "    $("_" * 70)" -ForegroundColor DarkGray

    # -- Summary Bar --
    Write-Host ""
    Write-Host -NoNewline "    "
    Write-Host -NoNewline "[*] $running Running" -ForegroundColor Green
    Write-Host -NoNewline "   "
    Write-Host -NoNewline "[ ] $stopped Stopped" -ForegroundColor Red
    Write-Host -NoNewline "   "
    Write-Host -NoNewline "Total: $total" -ForegroundColor DarkGray
    Write-Host -NoNewline "    "
    Write-Host -NoNewline "$time" -ForegroundColor DarkGray
    Write-Host -NoNewline "  [" -ForegroundColor DarkGray
    $script:ProgressBarCol = [Console]::CursorLeft
    $script:ProgressBarRow = [Console]::CursorTop
    Write-Host -NoNewline (" " * 10) -ForegroundColor DarkGray
    Write-Host "]" -ForegroundColor DarkGray
    Write-Host ""

    $colW = @{ Num=5; Name=15; Status=12; Addr=21; PID=7; Up=10 }
    $sep = "  +" + ("-" * $colW.Num) + "+" + ("-" * $colW.Name) + "+" + ("-" * $colW.Status) + "+" + ("-" * $colW.Addr) + "+" + ("-" * $colW.PID) + "+" + ("-" * $colW.Up) + "+"

    Write-Host $sep -ForegroundColor DarkGray

    Write-Host -NoNewline "  |" -ForegroundColor DarkGray
    Write-Host -NoNewline (" #".PadRight($colW.Num)) -ForegroundColor Cyan
    Write-Host -NoNewline "|" -ForegroundColor DarkGray
    Write-Host -NoNewline (" PROJECT".PadRight($colW.Name)) -ForegroundColor Cyan
    Write-Host -NoNewline "|" -ForegroundColor DarkGray
    Write-Host -NoNewline (" STATUS".PadRight($colW.Status)) -ForegroundColor Cyan
    Write-Host -NoNewline "|" -ForegroundColor DarkGray
    Write-Host -NoNewline (" ADDRESS".PadRight($colW.Addr)) -ForegroundColor Cyan
    Write-Host -NoNewline "|" -ForegroundColor DarkGray
    Write-Host -NoNewline (" PID".PadRight($colW.PID)) -ForegroundColor Cyan
    Write-Host -NoNewline "|" -ForegroundColor DarkGray
    Write-Host (" UPTIME".PadRight($colW.Up)) -ForegroundColor Cyan -NoNewline
    Write-Host "|" -ForegroundColor DarkGray
    Write-Host $sep -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Statuses.Count; $i++) {
        Write-Row -S $Statuses[$i] -Index ($i + 1) -Selected ($i -eq $SelectedIndex) -ColW $colW
    }

    Write-Host $sep -ForegroundColor DarkGray

    $hasAdmin = $Statuses | Where-Object { $_.NeedsAdmin }
    if ($hasAdmin) {
        Write-Host "   * Requires administrator privileges" -ForegroundColor DarkYellow
    }

    $sel = $Statuses[$SelectedIndex]
    Write-Host ""
    Write-Host "  +---------------------------------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host -NoNewline "  |  Selected: " -ForegroundColor DarkGray
    Write-Host -NoNewline "$($sel.Name)" -ForegroundColor White
    $descPad = 63 - $sel.Name.Length
    if ($descPad -lt 1) { $descPad = 1 }
    Write-Host -NoNewline (" - $($sel.Description)").PadRight($descPad).Substring(0, $descPad) -ForegroundColor DarkGray
    Write-Host "|" -ForegroundColor DarkGray
    if ($sel.Url) {
        $urlDisplay = $sel.Url
        $urlPad = 73 - $urlDisplay.Length
        if ($urlPad -lt 1) { $urlPad = 1 }
        Write-Host -NoNewline "  |  " -ForegroundColor DarkGray
        Write-Host -NoNewline $urlDisplay -ForegroundColor Cyan
        Write-Host -NoNewline (" " * $urlPad) -ForegroundColor DarkGray
        Write-Host "|" -ForegroundColor DarkGray
    }
    Write-Host "  +---------------------------------------------------------------------------+" -ForegroundColor DarkGray

    Write-Host ""
    Write-Host -NoNewline "   " -ForegroundColor DarkGray
    Write-Host -NoNewline "[Up/Dn]" -ForegroundColor White
    Write-Host -NoNewline " Nav " -ForegroundColor Gray
    Write-Host -NoNewline "[Enter]" -ForegroundColor White
    Write-Host -NoNewline " Menu " -ForegroundColor Gray
    Write-Host -NoNewline "[I]" -ForegroundColor Cyan
    Write-Host -NoNewline " Info " -ForegroundColor Gray
    Write-Host -NoNewline "[O]" -ForegroundColor Cyan
    Write-Host -NoNewline " Open " -ForegroundColor Gray
    Write-Host -NoNewline "[S]" -ForegroundColor Green
    Write-Host -NoNewline " Start " -ForegroundColor Gray
    Write-Host -NoNewline "[K]" -ForegroundColor Red
    Write-Host -NoNewline " Kill " -ForegroundColor Gray
    Write-Host -NoNewline "[R]" -ForegroundColor Yellow
    Write-Host " Restart " -ForegroundColor Gray

    Write-Host -NoNewline "   " -ForegroundColor DarkGray
    Write-Host -NoNewline "[N]" -ForegroundColor Cyan
    Write-Host -NoNewline " New " -ForegroundColor Gray
    Write-Host -NoNewline "[D]" -ForegroundColor DarkYellow
    Write-Host -NoNewline " Delete " -ForegroundColor Gray
    Write-Host -NoNewline "[X]" -ForegroundColor Magenta
    Write-Host -NoNewline " Kill ALL " -ForegroundColor Gray
    Write-Host "[Q]" -ForegroundColor DarkRed -NoNewline
    Write-Host " Quit" -ForegroundColor Gray
    Write-Host ""

    # -- Wizard Art Overlay (right panel) --
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
    try {
        $savedRow = [Console]::CursorTop
        $wizCol = 80
        $wizRow = 1
        $bufWidth = [Console]::BufferWidth
        $maxWizLen = $bufWidth - $wizCol - 1
        if ($maxWizLen -gt 10) {
            $origFg = [Console]::ForegroundColor
            for ($w = 0; $w -lt $wizardArt.Count; $w++) {
                $targetRow = $wizRow + $w
                if ($targetRow -ge $savedRow) { break }
                $line = $wizardArt[$w]
                if ($line.Length -gt $maxWizLen) { $line = $line.Substring(0, $maxWizLen) }
                [Console]::SetCursorPosition($wizCol, $targetRow)
                # Color gradient matching MERLIN header: DarkCyan -> Cyan -> DarkCyan
                if ($w -lt 8) {
                    [Console]::ForegroundColor = [ConsoleColor]::DarkCyan
                } elseif ($w -lt 22) {
                    [Console]::ForegroundColor = [ConsoleColor]::Cyan
                } else {
                    [Console]::ForegroundColor = [ConsoleColor]::DarkCyan
                }
                [Console]::Write($line)
            }
            [Console]::ForegroundColor = $origFg
            [Console]::SetCursorPosition(0, $savedRow)
        }
    } catch {
        # Silently ignore wizard rendering errors to preserve dashboard
        try { [Console]::SetCursorPosition(0, $savedRow) } catch {}
    }
    [Console]::CursorVisible = $true
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
    Write-Host -NoNewline "   Uptime:        " -ForegroundColor DarkGray
    Write-Host "$($s.Uptime)" -ForegroundColor Gray
    Write-Host -NoNewline "   Memory:        " -ForegroundColor DarkGray
    Write-Host "$($s.Memory)" -ForegroundColor Gray
    Write-Host -NoNewline "   CPU Time:      " -ForegroundColor DarkGray
    Write-Host "$($s.CPU)" -ForegroundColor Gray
    Write-Host -NoNewline "   Managed:       " -ForegroundColor DarkGray
    $managedText = if ($s.Managed) { "Yes (started by orchestrator)" } else { "No (external)" }
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
    Write-Host "  -- Logs -----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    $logOut = Join-Path $LogDir "$($s.Id)_stdout.log"
    $logErr = Join-Path $LogDir "$($s.Id)_stderr.log"

    $outExists = Test-Path $logOut
    $errExists = Test-Path $logErr
    $outSize = if ($outExists) { "{0:N1} KB" -f ((Get-Item $logOut).Length / 1KB) } else { "-" }
    $errSize = if ($errExists) { "{0:N1} KB" -f ((Get-Item $logErr).Length / 1KB) } else { "-" }

    Write-Host -NoNewline "   stdout:        " -ForegroundColor DarkGray
    Write-Host "$logOut ($outSize)" -ForegroundColor Gray
    Write-Host -NoNewline "   stderr:        " -ForegroundColor DarkGray
    Write-Host "$logErr ($errSize)" -ForegroundColor Gray

    if ($outExists) {
        $preview = Get-Content $logOut -Tail 5 -ErrorAction SilentlyContinue
        if ($preview) {
            Write-Host ""
            Write-Host "   Last output:" -ForegroundColor DarkGray
            foreach ($line in $preview) {
                $displayLine = $line
                if ($displayLine.Length -gt 68) { $displayLine = $displayLine.Substring(0, 65) + "..." }
                Write-Host "   | $displayLine" -ForegroundColor DarkGray
            }
        }
    }

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
    Write-Host -NoNewline "   Status:   " -ForegroundColor DarkGray
    Write-Host "$statusIcon $($s.Status)" -ForegroundColor $statusColor
    Write-Host -NoNewline "   Address:  " -ForegroundColor DarkGray
    Write-Host "$($s.Address)" -ForegroundColor Cyan
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

    $logOut = Join-Path $LogDir "$($Project.id)_stdout.log"
    $logErr = Join-Path $LogDir "$($Project.id)_stderr.log"

    Clear-Host
    Write-Host ""
    Write-Host "  +======================================================================+" -ForegroundColor DarkCyan
    Write-Host "  |  LOGS: $($Project.name.PadRight(63))|" -ForegroundColor DarkCyan
    Write-Host "  +======================================================================+" -ForegroundColor DarkCyan

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
        $key = [Console]::ReadKey($true)
        $ch = [char]::ToUpper($key.KeyChar)

        if ($key.Key -eq "Escape" -or $ch -eq "B") { return }

        switch ($ch) {
            "S" {
                Write-Host ""
                Start-Project -Project $Project
                Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                $null = [Console]::ReadKey($true)
                $portMap = Get-AllListeningPorts
                $newStatus = Get-ProjectStatus -Project $Project -PortMap $portMap
                if ($Screen -eq "info") { Show-InfoPanel -Status $newStatus -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $newStatus -Project $Project }
            }
            "K" {
                Write-Host ""
                Write-Host -NoNewline "  Kill $($Project.name)? (y/N): " -ForegroundColor Red
                $confirm = [Console]::ReadKey($true)
                Write-Host $confirm.KeyChar
                if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                    Stop-Project -Project $Project
                } else { Write-Host "  Cancelled." -ForegroundColor DarkGray }
                Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                $null = [Console]::ReadKey($true)
                $portMap = Get-AllListeningPorts
                $newStatus = Get-ProjectStatus -Project $Project -PortMap $portMap
                if ($Screen -eq "info") { Show-InfoPanel -Status $newStatus -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $newStatus -Project $Project }
            }
            "R" {
                Write-Host ""
                Write-Host -NoNewline "  Restart $($Project.name)? (y/N): " -ForegroundColor Yellow
                $confirm = [Console]::ReadKey($true)
                Write-Host $confirm.KeyChar
                if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                    Restart-Project -Project $Project
                } else { Write-Host "  Cancelled." -ForegroundColor DarkGray }
                Write-Host ""; Write-Host "  Press any key..." -ForegroundColor DarkGray
                $null = [Console]::ReadKey($true)
                $portMap = Get-AllListeningPorts
                $newStatus = Get-ProjectStatus -Project $Project -PortMap $portMap
                if ($Screen -eq "info") { Show-InfoPanel -Status $newStatus -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $newStatus -Project $Project }
            }
            "L" {
                Show-Logs -Project $Project
                Write-Host "  Press any key to go back..." -ForegroundColor DarkGray
                $null = [Console]::ReadKey($true)
                if ($Screen -eq "info") { Show-InfoPanel -Status $Status -Project $Project }
                elseif ($Screen -eq "action") { Show-ActionMenu -Status $Status -Project $Project }
            }
            "I" {
                if ($Screen -ne "info") {
                    $portMap = Get-AllListeningPorts
                    $newStatus = Get-ProjectStatus -Project $Project -PortMap $portMap
                    Show-InfoPanel -Status $newStatus -Project $Project
                    Handle-SubScreen -Screen "info" -Project $Project -Status $newStatus
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

function Main {
    $config = Load-Config
    $projects = $config.projects

    if (-not $projects -or $projects.Count -eq 0) {
        Write-Host "  No projects configured in $ConfigFile" -ForegroundColor Red
        exit 1
    }

    $selectedIdx = 0
    $maxIdx = $projects.Count - 1

    # Initial fetch + render
    $statuses = Refresh-AllStatuses -Projects $projects
    Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx

    while ($true) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $keyPressed = $false

        while ($stopwatch.Elapsed.TotalSeconds -lt $RefreshSecs) {
            if ([Console]::KeyAvailable) {
                $keyPressed = $true
                break
            }
            # Animate progress bar
            $progress = [int][math]::Floor(($stopwatch.Elapsed.TotalSeconds / $RefreshSecs) * 10)
            if ($progress -gt 10) { $progress = 10 }
            try {
                [Console]::CursorVisible = $false
                [Console]::SetCursorPosition($script:ProgressBarCol, $script:ProgressBarRow)
                $origFg = [Console]::ForegroundColor
                [Console]::ForegroundColor = [ConsoleColor]::Cyan
                [Console]::Write(("*" * $progress) + (" " * (10 - $progress)))
                [Console]::ForegroundColor = $origFg
            } catch {}
            Start-Sleep -Milliseconds 80
        }
        $stopwatch.Stop()

        if (-not $keyPressed) {
            # Auto-refresh: fetch new data
            $statuses = Refresh-AllStatuses -Projects $projects
            Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            continue
        }

        $key = [Console]::ReadKey($true)
        $ch = [char]::ToUpper($key.KeyChar)

        switch ($key.Key) {
            "UpArrow" {
                $selectedIdx = if ($selectedIdx -gt 0) { $selectedIdx - 1 } else { $maxIdx }
                # Re-render with CACHED data (no network calls = instant)
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            }
            "DownArrow" {
                $selectedIdx = if ($selectedIdx -lt $maxIdx) { $selectedIdx + 1 } else { 0 }
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
            }
            "Enter" {
                $selProject = $projects[$selectedIdx]
                $selStatus  = $statuses[$selectedIdx]
                Show-ActionMenu -Status $selStatus -Project $selProject
                Handle-SubScreen -Screen "action" -Project $selProject -Status $selStatus
                $statuses = Refresh-AllStatuses -Projects $projects
                Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
            }
            default {
                $selProject = $projects[$selectedIdx]

                switch ($ch) {
                    "Q" {
                        Write-Host ""
                        Write-Host "  Goodbye!" -ForegroundColor Cyan
                        Write-Host ""
                        return
                    }
                    "A" {
                        $statuses = Refresh-AllStatuses -Projects $projects
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx -InPlace
                    }
                    "I" {
                        $portMap = Get-AllListeningPorts
                        $selStatus = Get-ProjectStatus -Project $selProject -PortMap $portMap
                        Show-InfoPanel -Status $selStatus -Project $selProject
                        Handle-SubScreen -Screen "info" -Project $selProject -Status $selStatus
                        $statuses = Refresh-AllStatuses -Projects $projects
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "S" {
                        Write-Host ""
                        Start-Project -Project $selProject
                        Start-Sleep -Milliseconds 800
                        $statuses = Refresh-AllStatuses -Projects $projects
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "K" {
                        Write-Host -NoNewline "  Kill $($selProject.name)? (y/N): " -ForegroundColor Red
                        $confirm = [Console]::ReadKey($true)
                        Write-Host $confirm.KeyChar
                        if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                            Stop-Project -Project $selProject
                        }
                        Start-Sleep -Milliseconds 500
                        $statuses = Refresh-AllStatuses -Projects $projects
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "R" {
                        Write-Host -NoNewline "  Restart $($selProject.name)? (y/N): " -ForegroundColor Yellow
                        $confirm = [Console]::ReadKey($true)
                        Write-Host $confirm.KeyChar
                        if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                            Restart-Project -Project $selProject
                        }
                        Start-Sleep -Milliseconds 500
                        $statuses = Refresh-AllStatuses -Projects $projects
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "L" {
                        Show-Logs -Project $selProject
                        Write-Host "  Press any key to go back..." -ForegroundColor DarkGray
                        $null = [Console]::ReadKey($true)
                        $statuses = Refresh-AllStatuses -Projects $projects
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
                        Write-Host "  KILL ALL servers? This will terminate EVERY process" -ForegroundColor Red
                        Write-Host "  on configured ports, including zombie processes." -ForegroundColor Red
                        Write-Host -NoNewline "  Type YES to confirm: " -ForegroundColor Red
                        $confirm = Read-Host
                        if ($confirm -eq "YES") {
                            Kill-AllProjects -Projects $projects
                            Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
                            $null = [Console]::ReadKey($true)
                        } else {
                            Write-Host "  Cancelled." -ForegroundColor DarkGray
                            Start-Sleep -Milliseconds 500
                        }
                        $statuses = Refresh-AllStatuses -Projects $projects
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
                        
                        $newPort = $null
                        if (-not [string]::IsNullOrWhiteSpace($newPortStr)) { $newPort = [int]$newPortStr }

                        $newProjects = @($config.projects) + [PSCustomObject]@{
                            id = $newId
                            name = $newName
                            description = $newDesc
                            path = $newPath
                            command = $newCmd
                            port = $newPort
                            host = "localhost"
                            color = "#ffffff"
                            requires_admin = $false
                        }
                        $config.projects = $newProjects
                        Save-Config -Config $config
                        $projects = $config.projects
                        Write-Host "  Project added successfully!" -ForegroundColor Green
                        Start-Sleep -Milliseconds 800
                        $maxIdx = $projects.Count - 1
                        $statuses = Refresh-AllStatuses -Projects $projects
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                    "D" {
                        Write-Host ""
                        Write-Host -NoNewline "  DELETE project '$($selProject.name)' from config? (y/N): " -ForegroundColor Red
                        $confirm = [Console]::ReadKey($true)
                        Write-Host $confirm.KeyChar
                        if ($confirm.KeyChar -eq "y" -or $confirm.KeyChar -eq "Y") {
                            # First stop if running
                            if ($statuses[$selectedIdx].Status -eq "RUNNING") {
                                Stop-Project -Project $selProject
                            }
                            # Remove from config
                            $newProjects = @($config.projects | Where-Object { $_.id -ne $selProject.id })
                            $config.projects = $newProjects
                            Save-Config -Config $config
                            $projects = $config.projects
                            $maxIdx = $projects.Count - 1
                            if ($selectedIdx -gt $maxIdx) { $selectedIdx = $maxIdx }
                            if ($selectedIdx -lt 0) { $selectedIdx = 0 }
                            Write-Host "  Project deleted." -ForegroundColor Green
                            Start-Sleep -Milliseconds 800
                        } else {
                            Write-Host "  Cancelled." -ForegroundColor DarkGray
                            Start-Sleep -Milliseconds 500
                        }
                        $statuses = Refresh-AllStatuses -Projects $projects
                        Show-Dashboard -Statuses $statuses -SelectedIndex $selectedIdx
                    }
                }
            }
        }
    }
}

# --- Entry Point -------------------------------------------------------------

$Host.UI.RawUI.WindowTitle = "Merlin - Server Manager"
Main
