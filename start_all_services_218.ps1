# ==============================================================================
# Merlin - Auto-Start All Services on 192.168.2.218 (WMI Detached + Fast Batch)
# Reads projects.json, verifies listening ports, and starts any offline .218 service.
# ==============================================================================

$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ScriptDir = "C:\Users\QB_DESARROLLO\Desktop\Merlin"
$ConfigFile = Join-Path $ScriptDir "projects.json"
$LogDir = Join-Path $ScriptDir "logs"
$DailyLog = Join-Path $LogDir "autostart_daily.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -Path $DailyLog -Value "`r`n======================================================================"
Add-Content -Path $DailyLog -Value "[$ts] INICIANDO RUTINA DE SERVICIOS MERLIN (.218)"
Add-Content -Path $DailyLog -Value "======================================================================"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "[!] Archivo no encontrado: $ConfigFile" -ForegroundColor Red
    Add-Content -Path $DailyLog -Value "[$ts] ERROR: projects.json no encontrado."
    exit 1
}

$rawJson = Get-Content $ConfigFile -Raw -Encoding UTF8
$config = $rawJson | ConvertFrom-Json
# Filter only projects belonging to 192.168.2.218
$projects = @($config.projects | Where-Object { $_.external_ip -eq "192.168.2.218" })

function Get-PortMap {
    $map = @{}
    try {
        $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            $p = [int]$c.LocalPort
            if (-not $map.ContainsKey($p)) {
                $map[$p] = [int]$c.OwningProcess
            }
        }
    } catch {}
    if ($map.Count -eq 0) {
        $raw = netstat -ano 2>$null
        foreach ($line in $raw) {
            if ("$line" -match 'TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)') {
                $p = [int]$Matches[1]
                $pid_ = [int]$Matches[2]
                if (-not $map.ContainsKey($p)) { $map[$p] = $pid_ }
            }
        }
    }
    return $map
}

$portMap = Get-PortMap

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     MERLIN 192.168.2.218 - LEVANTAMIENTO AUTOMATICO DE SERVICIOS" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$startedList = @()
$alreadyUp = 0
$failed = 0
$wmiStartup = New-CimInstance -ClassName Win32_ProcessStartup -Property @{ ShowWindow = [uint16]0 } -ClientOnly

foreach ($proj in $projects) {
    if ($proj.ssh -and $proj.ssh.enabled) { continue }

    $id = $proj.id
    $name = $proj.name
    $port = if ($proj.port) { [int]$proj.port } else { 0 }
    $path = $proj.path
    $command = $proj.command

    if (-not $path -or -not $command) { continue }

    if ($port -gt 0 -and $portMap.ContainsKey($port)) {
        $ownerPid = $portMap[$port]
        $msg = "[ACTIVO] $name -> Puerto $port (PID: $ownerPid)"
        Write-Host "  $msg" -ForegroundColor Green
        Add-Content -Path $DailyLog -Value "[$ts] $msg"
        $alreadyUp++
    } else {
        if (-not (Test-Path $path)) {
            $errMsg = "[ERROR] $name -> Ruta no existe: $path"
            Write-Host "  $errMsg" -ForegroundColor Red
            Add-Content -Path $DailyLog -Value "[$ts] $errMsg"
            $failed++
            continue
        }

        $logOut = Join-Path $LogDir "$($id)_stdout.log"
        $logErr = Join-Path $LogDir "$($id)_stderr.log"

        try {
            $sep = "`r`n============================================================`r`n[$ts] Merlin Auto-Start Routine`r`n============================================================`r`n"
            Add-Content -Path $logOut -Value $sep -ErrorAction SilentlyContinue

            $cmdNorm = $command.Replace('/', '\').Replace('cmd \c', 'cmd /c').Replace('http:\\', 'http://').Replace('https:\\', 'https://')
            $q = [char]34
            $fullCmd = "cmd.exe /c " + $cmdNorm + " >> " + $q + $logOut + $q + " 2>> " + $q + $logErr + $q
            $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
                CommandLine               = $fullCmd
                CurrentDirectory          = $path
                ProcessStartupInformation = $wmiStartup
            }

            if ($res.ReturnValue -eq 0) {
                $startedList += [PSCustomObject]@{ Name = $name; Port = $port; WmiPid = $res.ProcessId }
            } else {
                Write-Host "  [FALLO] $name -> WMI ReturnValue $($res.ReturnValue)" -ForegroundColor Red
                Add-Content -Path $DailyLog -Value "[$ts] [FALLO] $name -> WMI $($res.ReturnValue)"
                $failed++
            }
        } catch {
            Write-Host "  [FALLO] $name -> $($_.Exception.Message)" -ForegroundColor Red
            Add-Content -Path $DailyLog -Value "[$ts] [FALLO] $name -> $($_.Exception.Message)"
            $failed++
        }
    }
}

if ($startedList.Count -gt 0) {
    Write-Host "  [*] Esperando 2.5s para verificacion de puertos..." -ForegroundColor DarkCyan
    Start-Sleep -Milliseconds 2500
    $newMap = Get-PortMap
    foreach ($item in $startedList) {
        if ($item.Port -gt 0 -and $newMap.ContainsKey($item.Port)) {
            $realPid = $newMap[$item.Port]
            Write-Host "  [INICIADO] $($item.Name) -> Puerto $($item.Port) OK (PID: $realPid)" -ForegroundColor Green
            Add-Content -Path $DailyLog -Value "[$ts] [INICIADO] $($item.Name) -> Puerto $($item.Port) (PID $realPid)"
        } else {
            Write-Host "  [LANZADO] $($item.Name) -> Puerto $($item.Port) (Wrapper PID: $($item.WmiPid))" -ForegroundColor Yellow
            Add-Content -Path $DailyLog -Value "[$ts] [LANZADO] $($item.Name) -> PID $($item.WmiPid)"
        }
    }
}

$started = $startedList.Count
Write-Host "`r`n=== RESUMEN ===" -ForegroundColor Cyan
Write-Host "  Ya activos: $alreadyUp | Iniciados: $started | Fallos: $failed" -ForegroundColor Cyan
Add-Content -Path $DailyLog -Value "[$ts] RESUMEN: Ya activos: $alreadyUp | Iniciados: $started | Fallos: $failed"
