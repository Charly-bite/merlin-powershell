<#
.SYNOPSIS
    Visor y Control Inalambrico Permanente (scrcpy) para POCO M8 Pro 5G de Mr. Dev.
    Selecciona automaticamente la ruta mas rapida (LAN Wi-Fi 192.168.2.103:5555 o Tailscale 100.126.87.126:5555)
    y reconecta automaticamente si el telefono cambia de red.
#>
param(
    [switch]$Once,
    [switch]$KeepAlive,
    [int]$MaxSize = 1440,
    [int]$MaxFps = 60,
    [string]$BitRate = "8M"
)

$ErrorActionPreference = "SilentlyContinue"
try {
    $win32 = Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);' -Name "Win32ConsoleMin" -Namespace "Merlin" -PassThru
    $null = $win32::ShowWindow($win32::GetConsoleWindow(), 6)
} catch {}
$ScrcpyDir = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v4.1"
$AdbExe    = if (Test-Path "$ScrcpyDir\adb.exe") { "$ScrcpyDir\adb.exe" } else { "adb" }
$ScrcpyExe = if (Test-Path "$ScrcpyDir\scrcpy.exe") { "$ScrcpyDir\scrcpy.exe" } else { "scrcpy" }

$Targets = @(
    @{ Name = "LAN Wi-Fi Oficina"; Endpoint = "192.168.2.103:5555"; Host = "192.168.2.103"; Port = 5555 },
    @{ Name = "Tailscale VPN";     Endpoint = "100.126.87.126:5555"; Host = "100.126.87.126"; Port = 5555 }
)

function Resolve-PocoEndpoint {
    $devs = (& $AdbExe devices) -join "`n"
    foreach ($t in $Targets) {
        if ($devs -match "$([regex]::Escape($t.Endpoint))\s+device") {
            return $t
        }
    }
    foreach ($t in $Targets) {
        & $AdbExe connect $t.Endpoint | Out-Null
        $devs = (& $AdbExe devices) -join "`n"
        if ($devs -match "$([regex]::Escape($t.Endpoint))\s+device") {
            return $t
        }
    }
    return $null
}

do {
    $active = Resolve-PocoEndpoint
    if ($null -eq $active) {
        if (-not $KeepAlive) { break }
        Start-Sleep -Seconds 5
        continue
    }

    & $ScrcpyExe `
        -s $active.Endpoint `
        --window-title="POCO M8 Pro 5G // Mr. Dev ($($active.Name) - $($active.Endpoint))" `
        --video-bit-rate=$BitRate `
        --max-fps=$MaxFps `
        --max-size=$MaxSize `
        --stay-awake `
        --no-audio

    if (-not $KeepAlive) { break }
    Start-Sleep -Seconds 5
} while ($true)
