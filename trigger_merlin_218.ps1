# ==============================================================================
# Lanzador y Monitor Maestro Diario (Home -> Remotos .222 y .218)
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$logDir = "C:\Users\Admin\Desktop\Merlin\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "daily_sync_0730.log"

$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -Path $logFile -Value "================================================================" -Force
Add-Content -Path $logFile -Value "[$ts] INICIO DE RUTINA DE SERVICIOS MERLIN (DESDE HOME)" -Force
Add-Content -Path $logFile -Value "================================================================" -Force

# --- FASE 1: ASEGURAR SERVICIOS EN OFICINA (192.168.2.222) ---
Add-Content -Path $logFile -Value "[$ts] [FASE 1] Verificando y asegurando servicios en office-pc (.222)..." -Force
try {
    $out222 = ssh -o BatchMode=yes -o ConnectTimeout=5 office-pc "powershell -ExecutionPolicy Bypass -File C:\Users\CarlosAlbertoAcevesC\Desktop\02-plataformas-activas\dory-lat\start_all_services_after_boot.ps1" 2>&1
    Add-Content -Path $logFile -Value ($out222 -join "`r`n") -Force
} catch {
    Add-Content -Path $logFile -Value "[$ts] [FASE 1] Error en office-pc: $($_.Exception.Message)" -Force
}

# --- FASE 2: ORQUESTADOR MERLIN REMOTO EN DESARROLLO (192.168.2.218) ---
$targetHost = "desarrollo"
$remoteScript = "C:\Users\QB_DESARROLLO\Desktop\03-Orquestador-y-Proyectos-Home\Merlin\start_all_services.ps1"
Add-Content -Path $logFile -Value "[$ts] [FASE 2] Conectando con Merlin en 192.168.2.218 via SSH ($targetHost)..." -Force

try {
    $sshOutput = ssh -o BatchMode=yes -o ConnectTimeout=5 $targetHost "powershell -ExecutionPolicy Bypass -File `"$remoteScript`"" 2>&1
    Add-Content -Path $logFile -Value "[$ts] [FASE 2] Respuesta remota de Merlin (.218):" -Force
    Add-Content -Path $logFile -Value ($sshOutput -join "`r`n") -Force
} catch {
    Add-Content -Path $logFile -Value "[$ts] [FASE 2] Error de conexion SSH: $($_.Exception.Message)" -Force
}

Add-Content -Path $logFile -Value "[$ts] FIN DE RUTINA DE SERVICIOS MERLIN" -Force
Add-Content -Path $logFile -Value "" -Force
