#!/usr/bin/env python3
"""
Merlin v2.4 Mobile & Network Command Center (Port 9000).
Designed for Mr. Dev's POCO M8 Pro 5G (100.126.87.126) over Tailscale VPN.
Provides 1-tap management of all services (.222, .218, Home, .237, .187, Poco),
live Tailscale/LAN network radar, log viewer, and remote command execution.
"""

import base64
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_FILE = SCRIPT_DIR / "projects.json"
LOG_DIR = SCRIPT_DIR / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
NTFY_TOPIC = os.environ.get("MERLIN_NTFY_TOPIC", "mrdev-merlin-soc")
NTFY_URL = f"https://ntfy.sh/{NTFY_TOPIC}"


def send_ntfy_alert(
    title: str,
    message: str,
    priority: str = "high",
    tags: str = "zap,merlin",
    click_url: str = "http://100.77.199.69:9000",
) -> bool:
    """Envia notificacion push a la app ntfy (io.heckel.ntfy) sin tocar ADB :5555."""
    try:
        req = urllib.request.Request(
            NTFY_URL,
            data=message.encode("utf-8"),
            method="POST",
            headers={
                "Title": title,
                "Priority": priority,
                "Tags": tags,
                "Click": click_url,
            },
        )
        with urllib.request.urlopen(req, timeout=6) as resp:
            return 200 <= resp.status < 300
    except Exception as e:
        print(f"[ntfy] Error enviando alerta: {e}")
        return False


TAILSCALE_MAP = {
    "192.168.2.222": "100.89.1.27",
    "192.168.2.218": "100.77.199.69",
    "192.168.2.237": "100.105.210.35",
    "192.168.2.187": "100.102.18.118",
    "100.90.211.9": "100.90.211.9",
    "100.126.87.126": "100.126.87.126",
}

NODE_META = {
    "192.168.2.222": {"alias": "office-pc", "label": ".222 (Oficina)", "ts_ip": "100.89.1.27", "lan_ip": "192.168.2.222", "log_dir": r"C:\Users\CarlosAlbertoAcevesC\Desktop\02-plataformas-activas\merlin\logs"},
    "100.89.1.27":   {"alias": "office-pc", "label": ".222 (Oficina)", "ts_ip": "100.89.1.27", "lan_ip": "192.168.2.222", "log_dir": r"C:\Users\CarlosAlbertoAcevesC\Desktop\02-plataformas-activas\merlin\logs"},
    "192.168.2.218": {"alias": "desarrollo", "label": ".218 (Prod)", "ts_ip": "100.77.199.69", "lan_ip": "192.168.2.218", "log_dir": r"C:\Users\QB_DESARROLLO\Desktop\03-Orquestador-y-Proyectos-Home\Merlin\logs"},
    "100.77.199.69": {"alias": "desarrollo", "label": ".218 (Prod)", "ts_ip": "100.77.199.69", "lan_ip": "192.168.2.218", "log_dir": r"C:\Users\QB_DESARROLLO\Desktop\03-Orquestador-y-Proyectos-Home\Merlin\logs"},
    "192.168.2.237": {"alias": "serverwebqb-ts", "label": "WEB-HUB (.237)", "ts_ip": "100.105.210.35", "lan_ip": "192.168.2.237", "log_dir": r"C:\Users\Administrador\.gemini\brain-portal"},
    "100.105.210.35": {"alias": "serverwebqb-ts", "label": "WEB-HUB (.237)", "ts_ip": "100.105.210.35", "lan_ip": "192.168.2.237", "log_dir": r"C:\Users\Administrador\.gemini\brain-portal"},
    "192.168.2.187": {"alias": "qb-bd-ts", "label": "BD-VAULT (.187)", "ts_ip": "100.102.18.118", "lan_ip": "192.168.2.187", "log_dir": r"C:\Users\Administrador\logs"},
    "100.102.18.118": {"alias": "qb-bd-ts", "label": "BD-VAULT (.187)", "ts_ip": "100.102.18.118", "lan_ip": "192.168.2.187", "log_dir": r"C:\Users\Administrador\logs"},
    "100.90.211.9":  {"alias": "home", "label": "HOME (.9)", "ts_ip": "100.90.211.9", "lan_ip": "100.90.211.9", "log_dir": r"C:\Users\Admin\Desktop\Merlin\logs"},
    "127.0.0.1":     {"alias": "home", "label": "HOME (.9)", "ts_ip": "100.90.211.9", "lan_ip": "192.168.2.218", "log_dir": r"C:\Users\Admin\Desktop\Merlin\logs"},
    "100.126.87.126": {"alias": "poco", "label": "POCO (.126)", "ts_ip": "100.126.87.126", "lan_ip": "192.168.2.103", "log_dir": r"C:\Users\QB_DESARROLLO\Desktop\03-Orquestador-y-Proyectos-Home\Merlin\logs"},
}

TAILSCALE_NODES = [
    {"id": "poco", "name": "POCO M8 Pro 5G", "role": "Mobile Command & AGY Auditor", "ts_ip": "100.126.87.126", "lan_ip": "192.168.2.103", "probe_port": 5555, "os": "Android 16"},
    {"id": "office-pc", "name": "Oficina (DEVQB)", "role": "Estacion Principal & AI GPU", "ts_ip": "100.89.1.27", "lan_ip": "192.168.2.222", "probe_port": 3000, "os": "Windows 11"},
    {"id": "desarrollo", "name": "Servidor Desarrollo (.218)", "role": "23 Servicios Prod + Proyectos Home", "ts_ip": "100.77.199.69", "lan_ip": "192.168.2.218", "probe_port": 80, "os": "Windows 11"},
    {"id": "home", "name": "Home (DESKTOP-874GS44)", "role": "Estacion Casa + Exit Node", "ts_ip": "100.90.211.9", "lan_ip": "192.168.100.8", "probe_port": 8090, "os": "Windows 11"},
    {"id": "serverwebqb-ts", "name": "ServerWebQB (.237)", "role": "Hub Central Memoria & Web Prod", "ts_ip": "100.105.210.35", "lan_ip": "192.168.2.237", "probe_port": 8090, "os": "Windows Server"},
    {"id": "qb-bd-ts", "name": "QB-WFS-BD (.187)", "role": "SQL Server & Boveda Respaldo", "ts_ip": "100.102.18.118", "lan_ip": "192.168.2.187", "probe_port": 1433, "os": "Windows Server"},
]


def get_local_ips():
    ips = {"127.0.0.1", "localhost", "0.0.0.0"}
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ips.add(info[4][0])
    except Exception:
        pass
    return ips


LOCAL_IPS = get_local_ips()


def is_local_ip(ip_str: str) -> bool:
    if not ip_str or ip_str in LOCAL_IPS:
        return True
    meta = NODE_META.get(ip_str)
    if meta and (meta["lan_ip"] in LOCAL_IPS or meta["ts_ip"] in LOCAL_IPS):
        return True
    return False


_POCO_PING_CACHE = {"ts": 0.0, "ok": True, "ms": 3}


def check_poco_icmp() -> tuple[bool, int]:
    now = time.time()
    if now - _POCO_PING_CACHE["ts"] < 15.0:
        return _POCO_PING_CACHE["ok"], _POCO_PING_CACHE["ms"]
    t0 = time.perf_counter()
    # 1. Consultar adb devices local (127.0.0.1:5037) sin abrir sockets nuevos hacia el celular
    try:
        adb_exe = find_adb_exe()
        r = subprocess.run([adb_exe, "devices"], capture_output=True, text=True, timeout=1.5)
        out = r.stdout or ""
        if ("192.168.2.103:5555\tdevice" in out) or ("100.126.87.126:5555\tdevice" in out):
            ms = max(1, int((time.perf_counter() - t0) * 1000))
            _POCO_PING_CACHE.update({"ts": now, "ok": True, "ms": ms})
            return True, ms
    except Exception:
        pass
    # 2. Consultar tailscale status local o tabla ARP sin tocar puerto 5555
    try:
        r = subprocess.run(["tailscale", "status"], capture_output=True, text=True, timeout=1.5)
        for line in (r.stdout or "").splitlines():
            if "100.126.87.126" in line and "offline" not in line.lower():
                ms = max(1, int((time.perf_counter() - t0) * 1000))
                _POCO_PING_CACHE.update({"ts": now, "ok": True, "ms": ms})
                return True, ms
    except Exception:
        pass
    try:
        r = subprocess.run(["arp", "-a", "192.168.2.103"], capture_output=True, text=True, timeout=1.0)
        if "192.168.2.103" in (r.stdout or "") and ("din" in (r.stdout or "").lower() or "dyn" in (r.stdout or "").lower()):
            ms = max(1, int((time.perf_counter() - t0) * 1000))
            _POCO_PING_CACHE.update({"ts": now, "ok": True, "ms": ms})
            return True, ms
    except Exception:
        pass
    _POCO_PING_CACHE.update({"ts": now, "ok": False, "ms": 0})
    return False, 0


def check_tcp(host: str, port: int, timeout: float = 0.25) -> tuple[bool, int]:
    if not port:
        return False, 0
    if int(port) == 5555:
        # Evita abrir sockets TCP crudos contra adbd:5555 que disparan notificaciones de conexion/desconexion en Android
        return check_poco_icmp()
    t0 = time.perf_counter()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            ms = int((time.perf_counter() - t0) * 1000)
            return True, max(1, ms)
    except Exception:
        return False, 0


def load_projects():
    try:
        raw = CONFIG_FILE.read_text(encoding="utf-8-sig")
        return json.loads(raw).get("projects", [])
    except Exception:
        return []


def infer_category(proj: dict, is_home_migrated: bool) -> str:
    if is_home_migrated:
        return "HOME"
    desc = (proj.get("name", "") + " " + proj.get("description", "")).upper()
    if any(k in desc for k in ("SEC", "IDS", "WAZUH", "SPLUNK", "SIEM", "UAC", "C2", "AUDIT")):
        return "SEC"
    if any(k in desc for k in ("AI", "VOICE", "BRAIN", "QWEN", "CHAT", "VIDEO")):
        return "AI"
    if any(k in desc for k in ("NET", "ROUTER", "SOC", "MERLIN", "MONITOR")):
        return "OPS"
    return "CORE"


def probe_project(proj: dict, use_tailscale_urls: bool) -> dict:
    ext_ip = proj.get("external_ip") or "127.0.0.1"
    host_ip = proj.get("host") or ""
    port = int(proj.get("port") or 0)
    local = is_local_ip(ext_ip)

    candidates: list[str] = []
    if local:
        for c in ("127.0.0.1", ext_ip, host_ip):
            if c and c != "0.0.0.0" and c not in candidates:
                candidates.append(c)
    else:
        on_office_lan = any(ip.startswith("192.168.2.") for ip in LOCAL_IPS)
        primary_remote = ext_ip if (on_office_lan and ext_ip.startswith("192.168.2.")) else TAILSCALE_MAP.get(ext_ip, ext_ip)
        if primary_remote and primary_remote not in ("0.0.0.0", "127.0.0.1"):
            candidates.append(primary_remote)

    up, latency_ms = False, 0
    probe_timeout = 0.15 if local else 0.60
    proc_match = proj.get("process_match") or ""
    if port > 0:
        for c in candidates:
            up, latency_ms = check_tcp(c, port, timeout=probe_timeout)
            if up:
                break
        if not up and ext_ip == "100.90.211.9" and port == 22:
            up, latency_ms = check_tcp("127.0.0.1", 2223, timeout=0.15)
    elif proc_match:
        # Daemon without TCP port (e.g. clipboard-bridge-home)
        if local:
            up, latency_ms = True, 1
        else:
            up, latency_ms = check_tcp(TAILSCALE_MAP.get(ext_ip, ext_ip), 8085, timeout=0.25)

    meta = NODE_META.get(ext_ip, {"alias": "local", "label": "HOME (.9)", "ts_ip": ext_ip, "lan_ip": ext_ip})
    path_str = proj.get("path") or ""
    is_home_migrated = "Proyectos_Home" in path_str
    cat = infer_category(proj, is_home_migrated)

    lan_ip = "127.0.0.1" if (local and ext_ip == "100.90.211.9") else (meta.get("lan_ip") or ext_ip)
    if lan_ip in ("127.0.0.1", "localhost", "0.0.0.0") and not (local and ext_ip == "100.90.211.9"):
        lan_ip = "192.168.2.218" if ("192.168.2.218" in LOCAL_IPS or "100.77.199.69" in LOCAL_IPS) else ("192.168.2.222" if "192.168.2.222" in LOCAL_IPS else "100.90.211.9")
    ts_ip = meta.get("ts_ip") or TAILSCALE_MAP.get(lan_ip, lan_ip)

    url_host = ts_ip if use_tailscale_urls else lan_ip
    scheme = "https" if port == 443 else "http"
    lan_url = f"{scheme}://{lan_ip}:{port}" if (port and port not in (1433, 5555)) else f"{lan_ip}:{port}"
    ts_url = f"{scheme}://{ts_ip}:{port}" if (port and port not in (1433, 5555)) else f"{ts_ip}:{port}"
    url = ts_url if use_tailscale_urls else lan_url

    return {
        "id": proj.get("id"),
        "name": proj.get("name"),
        "description": proj.get("description", ""),
        "category": cat,
        "port": port,
        "pid": port if up else 0,
        "alive": up,
        "healthy": up,
        "external_ip": ext_ip,
        "lan_ip": lan_ip,
        "ts_ip": ts_ip,
        "active_ip": url_host,
        "lan_url": lan_url,
        "ts_url": ts_url,
        "node_label": meta["label"],
        "node_alias": meta["alias"],
        "is_home_migrated": is_home_migrated,
        "status": "RUNNING" if up else "STOPPED",
        "latency_ms": latency_ms,
        "url": url,
        "color": proj.get("color", "#38bdf8"),
        "environment": proj.get("environment", "dev"),
    }


def invoke_home_bridge(cmd_str: str, timeout: float = 15.0) -> str:
    # 1. Try direct SSH on 100.90.211.9:22 if open
    if check_tcp("100.90.211.9", 22, timeout=0.35)[0]:
        encoded = base64.b64encode(cmd_str.encode("utf-16le")).decode("ascii")
        res = subprocess.run(["ssh", "-o", "ConnectTimeout=4", "-o", "BatchMode=yes", "home", f"powershell -NoProfile -EncodedCommand {encoded}"], capture_output=True, text=True, timeout=timeout)
        return (res.stdout or "") + (res.stderr or "")
    # 2. Try local reverse tunnel 127.0.0.1:2223 on this node (.218 or .222)
    if check_tcp("127.0.0.1", 2223, timeout=0.25)[0]:
        with socket.create_connection(("127.0.0.1", 2223), timeout=timeout) as sock:
            payload = base64.b64encode(cmd_str.encode("utf-8")).decode("ascii") + "\n"
            sock.sendall(payload.encode("ascii"))
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
            return base64.b64decode(buf.strip()).decode("utf-8", errors="replace")
    # 3. Fallback: forward through office-pc:2223 if office-pc is online
    b64_inner = base64.b64encode(cmd_str.encode("utf-8")).decode("ascii")
    ps_cmd = (
        f"$c=New-Object System.Net.Sockets.TcpClient('127.0.0.1',2223);"
        f"$s=$c.GetStream();$w=New-Object System.IO.StreamWriter($s);$w.AutoFlush=$true;"
        f"$r=New-Object System.IO.StreamReader($s);$w.WriteLine('{b64_inner}');"
        f"$resp=$r.ReadLine();$c.Close();[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($resp))"
    )
    res = subprocess.run(["ssh", "-o", "ConnectTimeout=4", "-o", "BatchMode=yes", "office-pc", f'powershell -NoProfile -Command "{ps_cmd}"'], capture_output=True, text=True, timeout=timeout)
    return (res.stdout or "") + (res.stderr or "")


def find_adb_exe() -> str:
    local_adb = Path(r"C:\Users\QB_DESARROLLO\Desktop\03-Orquestador-y-Proyectos-Home\Proyectos_Home\AgyAndroidAuditor\platform-tools\adb.exe")
    if local_adb.exists():
        return str(local_adb)
    winget_adb = Path.home() / r"AppData\Local\Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v4.1\adb.exe"
    if winget_adb.exists():
        return str(winget_adb)
    return "adb"


def _proxy_exec_to_node(hub_ips: tuple[str, ...], alias: str, ps_script: str, timeout: int = 15) -> str | None:
    payload = json.dumps({"target": alias, "cmd": ps_script}).encode("utf-8")
    for hub_ip in hub_ips:
        try:
            req = urllib.request.Request(
                f"http://{hub_ip}:9000/api/exec",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8", errors="replace"))
                if data.get("ok"):
                    return str(data.get("output", ""))
        except Exception:
            continue
    return None


def run_node_ps(alias: str, ps_script: str, timeout: int = 12) -> str:
    on_222 = "192.168.2.222" in LOCAL_IPS or "100.89.1.27" in LOCAL_IPS
    on_218 = "192.168.2.218" in LOCAL_IPS or "100.77.199.69" in LOCAL_IPS
    on_home = "100.90.211.9" in LOCAL_IPS or "192.168.11.60" in LOCAL_IPS

    is_local = (
        (alias == "office-pc" and on_222)
        or (alias == "desarrollo" and on_218)
        or (alias == "home" and on_home)
    )
    if is_local:
        encoded = base64.b64encode(ps_script.encode("utf-16le")).decode("ascii")
        res = subprocess.run(["powershell", "-NoProfile", "-EncodedCommand", encoded], capture_output=True, text=True, timeout=timeout)
        return (res.stdout or "") + (res.stderr or "")

    # Direct HTTP :9000 orchestration if target node runs Merlin Web API
    if alias == "home" and not on_home:
        proxied = _proxy_exec_to_node(("100.90.211.9",), "home", ps_script, timeout=timeout + 2)
        if proxied is not None:
            return proxied
        return invoke_home_bridge(ps_script, timeout=timeout)

    if alias == "office-pc" and not on_222:
        proxied = _proxy_exec_to_node(("192.168.2.222", "100.89.1.27"), "office-pc", ps_script, timeout=timeout + 2)
        if proxied is not None:
            return proxied

    if alias == "desarrollo" and not on_218:
        proxied = _proxy_exec_to_node(("192.168.2.218", "100.77.199.69"), "desarrollo", ps_script, timeout=timeout + 2)
        if proxied is not None:
            return proxied

    if not on_222 and not on_home and alias in ("serverwebqb-ts", "qb-bd-ts"):
        proxied = _proxy_exec_to_node(("192.168.2.222", "100.89.1.27", "100.90.211.9"), alias, ps_script, timeout=timeout + 3)
        if proxied is not None:
            return proxied

    if alias == "poco":
        adb_exe = find_adb_exe()
        for target_poco in ("100.126.87.126:5555", "192.168.2.103:5555"):
            subprocess.run([adb_exe, "connect", target_poco], capture_output=True, timeout=3)
            res = subprocess.run([adb_exe, "-s", target_poco, "shell", ps_script], capture_output=True, text=True, timeout=timeout)
            out = ((res.stdout or "") + (res.stderr or "")).strip()
            if res.returncode == 0 and "not found" not in out.lower():
                return out
        return out

    encoded = base64.b64encode(ps_script.encode("utf-16le")).decode("ascii")
    res = subprocess.run(["ssh", "-o", "ConnectTimeout=4", "-o", "BatchMode=yes", alias, f"powershell -NoProfile -EncodedCommand {encoded}"], capture_output=True, text=True, timeout=timeout)
    return (res.stdout or "") + (res.stderr or "")



def control_project(proj_id: str, action: str) -> dict:
    projects = load_projects()
    proj = next((p for p in projects if p.get("id") == proj_id), None)
    if not proj:
        return {"ok": False, "error": f"Proyecto '{proj_id}' no encontrado"}

    ext_ip = proj.get("external_ip") or "127.0.0.1"
    meta = NODE_META.get(ext_ip, {"alias": "desarrollo", "log_dir": str(LOG_DIR)})
    alias = meta["alias"]
    port = int(proj.get("port") or 0)
    path_str = proj.get("path") or ""
    cmd_str = proj.get("command") or ""
    log_dir = meta["log_dir"]

    if alias == "poco":
        adb_exe = find_adb_exe()
        subprocess.run([adb_exe, "connect", "100.126.87.126:5555"], capture_output=True, timeout=4)
        if action in ("start", "restart"):
            sh = (
                "apk=$(pm path com.mrdev.agyauditor | sed 's/package://'); "
                "CLASSPATH=$apk nohup app_process /system/bin com.mrdev.agyauditor.engine.AgyExecDaemon 8768 >/data/local/tmp/daemon8768.log 2>&1 & "
                "monkey -p com.mrdev.agyauditor -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1"
            )
            subprocess.run([adb_exe, "-s", "100.126.87.126:5555", "shell", sh], capture_output=True, timeout=8)
            return {"ok": True, "message": "AGY Android Auditor & Daemon :8768 iniciados en POCO M8 Pro 5G"}
        elif action == "logs":
            res = subprocess.run([adb_exe, "-s", "100.126.87.126:5555", "shell", "tail -n 40 /data/local/tmp/daemon8768.log 2>/dev/null; ps -A | grep -E 'agyauditor|tailscale'"], capture_output=True, text=True, timeout=8)
            return {"ok": True, "logs": res.stdout or "(sin logs)"}

    if action == "logs":
        ps = f"""
        $out = Join-Path '{log_dir}' '{proj_id}_stdout.log'
        $err = Join-Path '{log_dir}' '{proj_id}_stderr.log'
        Write-Output '=== STDOUT ==='
        if (Test-Path $out) {{ Get-Content $out -Tail 35 }} else {{ Write-Output '(vacio)' }}
        Write-Output '=== STDERR ==='
        if (Test-Path $err) {{ Get-Content $err -Tail 25 }} else {{ Write-Output '(vacio)' }}
        """
        return {"ok": True, "logs": run_node_ps(alias, ps, timeout=8)}

    proc_match = proj.get("process_match") or ""
    stop_ps = ""
    if port > 0:
        stop_ps += f"""
        $conns = Get-NetTCPConnection -LocalPort {port} -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) {{
            if ($c.OwningProcess -gt 4) {{ Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue }}
        }}
        """
    if proc_match:
        stop_ps += f"""
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {{ $_.ProcessId -ne $PID -and $_.CommandLine -match '{proc_match.replace("'", "''")}' }} | ForEach-Object {{
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }}
        """
    start_ps = f"""
    $logOut = Join-Path '{log_dir}' '{proj_id}_stdout.log'
    $logErr = Join-Path '{log_dir}' '{proj_id}_stderr.log'
    $wmiSt = New-CimInstance -ClassName Win32_ProcessStartup -Property @{{ ShowWindow = [uint16]0 }} -ClientOnly
    $fullCmd = 'C:\\Windows\\System32\\conhost.exe --headless cmd.exe /c {cmd_str.replace("'", "''")} >> "' + $logOut + '" 2>> "' + $logErr + '"'
    $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{{
        CommandLine = $fullCmd
        CurrentDirectory = '{path_str.replace("'", "''")}'
        ProcessStartupInformation = $wmiSt
    }}
    Write-Output ("PID:" + $res.ProcessId)
    """

    if action == "stop":
        out = run_node_ps(alias, stop_ps, timeout=8)
        return {"ok": True, "message": f"Detenido {proj.get('name')} (Puerto {port})", "detail": out}
    elif action == "start":
        out = run_node_ps(alias, start_ps, timeout=10)
        return {"ok": True, "message": f"Iniciado {proj.get('name')} en {alias}", "detail": out}
    elif action == "restart":
        out = run_node_ps(alias, stop_ps + "\nStart-Sleep -Milliseconds 600\n" + start_ps, timeout=12)
        return {"ok": True, "message": f"Reiniciado {proj.get('name')} en {alias}", "detail": out}

    return {"ok": False, "error": f"Accion desconocida: {action}"}


INDEX_HTML = r"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>MERLIN v2.4 // Mobile & Network Command Center</title>
<style>
  :root {
    --bg: #0a0e14;
    --surface: #111722;
    --card: #151e2d;
    --border: #233248;
    --cyan: #38bdf8;
    --blue: #0284c7;
    --green: #10b981;
    --red: #f43f5e;
    --amber: #f59e0b;
    --text: #f8fafc;
    --muted: #94a3b8;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
    padding-bottom: 80px;
  }
  header {
    position: sticky; top: 0; z-index: 50;
    background: rgba(10, 14, 20, 0.94);
    backdrop-filter: blur(10px);
    border-bottom: 1px solid var(--border);
    padding: 12px 14px;
  }
  .top-row { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .brand { display: flex; align-items: center; gap: 8px; font-weight: 800; font-size: 16px; letter-spacing: 0.5px; color: var(--cyan); }
  .badge-pill {
    font-size: 11px; padding: 4px 8px; border-radius: 6px;
    background: #0c253b; border: 1px solid var(--blue); color: var(--cyan); font-weight: 700;
  }
  .stats-bar {
    display: flex; gap: 8px; margin-top: 10px; overflow-x: auto; padding-bottom: 4px;
  }
  .stat-chip {
    flex: 1; min-width: 90px; background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 7px 10px; text-align: center;
  }
  .stat-chip .num { font-size: 17px; font-weight: 800; }
  .stat-chip .lbl { font-size: 10px; color: var(--muted); text-transform: uppercase; }
  .nav-tabs {
    display: flex; gap: 6px; margin-top: 10px; overflow-x: auto; padding-bottom: 2px;
  }
  .tab-btn {
    background: var(--surface); color: var(--muted); border: 1px solid var(--border);
    padding: 7px 12px; border-radius: 8px; font-size: 12px; font-weight: 700;
    white-space: nowrap; cursor: pointer;
  }
  .tab-btn.active {
    background: var(--blue); color: #fff; border-color: var(--cyan);
  }
  main { padding: 12px 14px; max-width: 1100px; margin: 0 auto; }
  .search-bar {
    display: flex; gap: 8px; margin-bottom: 12px;
  }
  .search-bar input {
    flex: 1; background: var(--surface); border: 1px solid var(--border);
    color: var(--text); padding: 10px 12px; border-radius: 8px; font-size: 13px;
  }
  .btn-wake {
    background: rgba(16, 185, 129, 0.15); border: 1px solid var(--green);
    color: var(--green); padding: 0 12px; border-radius: 8px; font-weight: 700; font-size: 12px; cursor: pointer;
  }
  .grid {
    display: grid; grid-template-columns: repeat(auto-fill, minmax(310px, 1fr)); gap: 10px;
  }
  .card {
    background: var(--card); border: 1px solid var(--border); border-radius: 10px;
    padding: 12px; display: flex; flex-direction: column; gap: 8px;
  }
  .card.running { border-left: 4px solid var(--green); }
  .card.stopped { border-left: 4px solid var(--red); opacity: 0.9; }
  .card-hdr { display: flex; justify-content: space-between; align-items: flex-start; gap: 8px; }
  .card-title { font-size: 14px; font-weight: 700; color: #fff; }
  .card-sub { font-size: 11px; color: var(--muted); margin-top: 2px; }
  .status-badge {
    font-size: 10px; font-weight: 800; padding: 3px 7px; border-radius: 5px; white-space: nowrap;
  }
  .status-badge.up { background: rgba(16, 185, 129, 0.16); color: var(--green); border: 1px solid var(--green); }
  .status-badge.down { background: rgba(244, 63, 94, 0.16); color: var(--red); border: 1px solid var(--red); }
  .meta-row {
    display: flex; justify-content: space-between; align-items: center;
    font-size: 11px; color: var(--cyan); background: var(--surface);
    padding: 6px 8px; border-radius: 6px; font-family: monospace;
  }
  .actions { display: flex; gap: 6px; margin-top: 2px; }
  .act-btn {
    flex: 1; padding: 8px 6px; border-radius: 6px; border: 1px solid var(--border);
    background: var(--surface); color: var(--text); font-size: 11px; font-weight: 700;
    cursor: pointer; text-align: center; text-decoration: none;
  }
  .act-btn.open { background: rgba(56, 189, 248, 0.14); border-color: var(--cyan); color: var(--cyan); }
  .act-btn.start { background: rgba(16, 185, 129, 0.14); border-color: var(--green); color: var(--green); }
  .act-btn.stop { background: rgba(244, 63, 94, 0.14); border-color: var(--red); color: var(--red); }
  .act-btn.rst { background: rgba(245, 158, 11, 0.14); border-color: var(--amber); color: var(--amber); }
  .section-title { font-size: 13px; font-weight: 800; color: var(--cyan); margin: 14px 0 8px; text-transform: uppercase; letter-spacing: 0.6px; }
  .term-box {
    background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 12px;
  }
  .term-controls { display: flex; gap: 6px; margin-bottom: 8px; flex-wrap: wrap; }
  .term-controls select, .term-controls input {
    background: var(--bg); border: 1px solid var(--border); color: #fff; padding: 9px; border-radius: 6px; font-size: 12px;
  }
  .term-controls input { flex: 1; min-width: 180px; font-family: monospace; }
  pre.console {
    background: #05080c; border: 1px solid var(--border); border-radius: 6px;
    padding: 10px; font-size: 11px; color: #38bdf8; max-height: 280px; overflow: auto; white-space: pre-wrap;
  }
  .modal {
    position: fixed; inset: 0; background: rgba(0,0,0,0.8); z-index: 100;
    display: none; align-items: center; justify-content: center; padding: 16px;
  }
  .modal.open { display: flex; }
  .modal-card {
    background: var(--card); border: 1px solid var(--cyan); border-radius: 12px;
    width: 100%; max-width: 720px; padding: 14px; display: flex; flex-direction: column; gap: 10px;
  }
</style>
</head>
<body>
<header>
  <div class="top-row">
    <div class="brand"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg> MERLIN v2.5 // MOBILE SOC</div>
    <div style="display:flex;gap:8px;align-items:center">
      <button class="badge-pill" id="modeToggleBtn" onclick="toggleIpMode()" title="Alternar entre IPs LAN (192.168.2.x) y Tailscale (100.x.y.z) [Atajo: Tecla T]" style="cursor:pointer">[T] Modo: LAN IP</button>
      <div class="badge-pill" id="clockBadge">TAILSCALE MESH</div>
    </div>
  </div>
  <div class="stats-bar">
    <div class="stat-chip"><div class="num" style="color:var(--green)" id="stUp">--</div><div class="lbl">Running</div></div>
    <div class="stat-chip"><div class="num" style="color:var(--red)" id="stDown">--</div><div class="lbl">Stopped</div></div>
    <div class="stat-chip"><div class="num" style="color:var(--cyan)" id="stTotal">--</div><div class="lbl">Total</div></div>
    <div class="stat-chip"><div class="num" style="color:var(--amber)" id="stNodes">6/6</div><div class="lbl">Tailscale</div></div>
  </div>
  <div class="nav-tabs" id="filterTabs">
    <button class="tab-btn active" onclick="setFilter('ALL', this)">Todos (Mesh)</button>
    <button class="tab-btn" onclick="setFilter('HA_MESH', this)" style="border-color:#10b981;color:#10b981">⚡ HA Mesh</button>
    <button class="tab-btn" onclick="setFilter('HOME (.9)', this)">HOME (.9)</button>
    <button class="tab-btn" onclick="setFilter('POCO (.126)', this)">📱 POCO (.126)</button>
    <button class="tab-btn" onclick="setFilter('.222 (Oficina)', this)">.222 (Oficina)</button>
    <button class="tab-btn" onclick="setFilter('.218 (Prod)', this)">.218 (Prod)</button>
    <button class="tab-btn" onclick="setFilter('WEB-HUB (.237)', this)">.237 (Web Hub)</button>
    <button class="tab-btn" onclick="setFilter('BD-VAULT (.187)', this)">.187 (BD/WFS)</button>
    <button class="tab-btn" onclick="setFilter('HOME_218', this)">HOME-&gt;.218</button>
    <button class="tab-btn" onclick="setFilter('NETWORK', this)">Red &amp; Nodos</button>
    <button class="tab-btn" onclick="setFilter('TERMINAL', this)">Terminal Remota</button>
  </div>
</header>

<main>
  <div id="servicesSection">
    <div class="search-bar">
      <input type="text" id="searchInput" placeholder="Buscar servicio, puerto o nodo..." oninput="renderServices()">
      <button class="btn-wake" id="searchBarModeBtn" onclick="toggleIpMode()" style="border-color:#c084fc;color:#c084fc;background:rgba(192,132,252,0.14)">[T] LAN / Tailscale</button>
      <button class="btn-wake" onclick="wakeAll218()"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:-1px"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg> Levantar .218</button>
      <button class="btn-wake" style="border-color:var(--cyan);color:var(--cyan);background:rgba(56,189,248,0.15)" onclick="testNtfy()"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-1px"><path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg> Test ntfy</button>
    </div>
    <div class="grid" id="servicesGrid"></div>
  </div>

  <div id="networkSection" style="display:none">
    <div class="section-title">Nodos Tailscale VPN (Casa, Oficina y Celular Poco)</div>
    <div class="grid" id="nodesGrid"></div>
    <div class="section-title">Accesos Rápidos de Administración de Red y Seguridad</div>
    <div class="grid" id="quickPortalsGrid"></div>
  </div>

  <div id="terminalSection" style="display:none">
    <div class="section-title">Ejecución Remota Multi-Nodo (SSH / ADB / Bridge :2223)</div>
    <div class="term-box">
      <div class="term-controls">
        <select id="termNode">
          <option value="desarrollo">Desarrollo (.218 / 100.77.199.69)</option>
          <option value="office-pc">Oficina DEVQB (.222 / 100.89.1.27)</option>
          <option value="home">Home Casa (100.90.211.9 :2223)</option>
          <option value="poco">Celular POCO M8 Pro 5G (100.126.87.126)</option>
          <option value="serverwebqb-ts">ServerWebQB Hub (.237 / 100.105.210.35)</option>
        </select>
        <input type="text" id="termCmd" placeholder="Ej. Get-NetTCPConnection -State Listen | Select -First 10" onkeydown="if(event.key==='Enter')runRemoteCmd()">
        <button class="tab-btn active" onclick="runRemoteCmd()">Ejecutar</button>
      </div>
      <pre class="console" id="termOutput">Selecciona un nodo y escribe un comando para administrarlo desde tu Poco...</pre>
    </div>
  </div>
</main>

<div class="modal" id="logModal" onclick="if(event.target===this)closeModal()">
  <div class="modal-card">
    <div class="top-row">
      <div class="brand" id="modalTitle">Logs</div>
      <button class="tab-btn" onclick="closeModal()">Cerrar</button>
    </div>
    <pre class="console" id="modalContent">Cargando...</pre>
  </div>
</div>

<script>
let allProjects = [];
let allNodes = [];
let currentFilter = 'ALL';
const urlParams = new URLSearchParams(window.location.search);
let tailscaleMode = (
  urlParams.get('mode') === 'tail' ||
  urlParams.get('mode') === 'ts' ||
  urlParams.get('tail') === '1' ||
  window.location.hostname.startsWith('100.')
);

function updateModeButtons() {
  const topBtn = document.getElementById('modeToggleBtn');
  const barBtn = document.getElementById('searchBarModeBtn');
  if (topBtn) {
    topBtn.textContent = tailscaleMode ? '[T] Modo: Tailscale (100.x)' : '[T] Modo: LAN IP (192.168.2.x)';
    topBtn.style.borderColor = tailscaleMode ? '#c084fc' : 'var(--cyan)';
    topBtn.style.color = tailscaleMode ? '#c084fc' : 'var(--cyan)';
    topBtn.style.background = tailscaleMode ? 'rgba(192,132,252,0.18)' : '#0c253b';
  }
  if (barBtn) {
    barBtn.textContent = tailscaleMode ? '[T] Tailscale: ON' : '[T] LAN IP: ON';
    barBtn.style.borderColor = tailscaleMode ? '#c084fc' : 'var(--cyan)';
    barBtn.style.color = tailscaleMode ? '#c084fc' : 'var(--cyan)';
    barBtn.style.background = tailscaleMode ? 'rgba(192,132,252,0.18)' : 'rgba(56,189,248,0.15)';
  }
}

function toggleIpMode() {
  tailscaleMode = !tailscaleMode;
  updateModeButtons();
  renderServices();
  renderNetwork();
}

document.addEventListener('keydown', (ev) => {
  const tag = (ev.target && ev.target.tagName) ? ev.target.tagName.toUpperCase() : '';
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
  if (ev.key === 't' || ev.key === 'T') {
    ev.preventDefault();
    toggleIpMode();
  }
});

async function fetchStatus() {
  try {
    updateModeButtons();
    const modeParam = tailscaleMode ? 'tail' : 'lan';
    const r = await fetch('/api/status?mode=' + modeParam);
    const data = await r.json();
    allProjects = data.projects || [];
    allNodes = data.nodes || [];
    document.getElementById('stUp').textContent = data.running;
    document.getElementById('stDown').textContent = data.stopped;
    document.getElementById('stTotal').textContent = data.total;
    const nodesUp = allNodes.filter(n => n.online).length;
    document.getElementById('stNodes').textContent = `${nodesUp}/${allNodes.length}`;
    document.getElementById('clockBadge').textContent = data.time;
    renderServices();
    renderNetwork();
  } catch (e) {}
}

function setFilter(f, btn) {
  currentFilter = f;
  document.querySelectorAll('#filterTabs .tab-btn').forEach(b => b.classList.remove('active'));
  if (btn) btn.classList.add('active');
  document.getElementById('servicesSection').style.display = (f === 'NETWORK' || f === 'TERMINAL') ? 'none' : 'block';
  document.getElementById('networkSection').style.display = (f === 'NETWORK') ? 'block' : 'none';
  document.getElementById('terminalSection').style.display = (f === 'TERMINAL') ? 'block' : 'none';
  renderServices();
}

function renderServices() {
  const q = (document.getElementById('searchInput').value || '').toLowerCase();
  const filtered = allProjects.filter(p => {
    if (currentFilter === 'HA_MESH') {
      if (!p.ha_group) return false;
    } else if (currentFilter === 'HOME_218') {
      if (!p.is_home_migrated && p.node_label !== 'HOME (.9)' && p.node_label !== 'POCO (.126)') return false;
    } else if (currentFilter !== 'ALL' && currentFilter !== 'NETWORK' && currentFilter !== 'TERMINAL') {
      if (p.node_label !== currentFilter) return false;
    }
    if (q) {
      return (p.name + ' ' + p.description + ' ' + p.port + ' ' + p.node_label + ' ' + (p.ha_group || '') + ' ' + (p.lan_ip || '') + ' ' + (p.ts_ip || '')).toLowerCase().includes(q);
    }
    return true;
  });

  const grid = document.getElementById('servicesGrid');
  grid.innerHTML = filtered.map(p => {
    const isUp = p.status === 'RUNNING';
    const lanIp = p.lan_ip || p.external_ip || '192.168.2.218';
    const tsIp = p.ts_ip || p.external_ip || '100.77.199.69';
    const primaryHost = tailscaleMode ? tsIp : lanIp;
    const secondaryHost = tailscaleMode ? lanIp : tsIp;
    const primaryTag = tailscaleMode ? 'TS' : 'LAN';
    const secondaryTag = tailscaleMode ? 'LAN' : 'TS';
    const activeUrl = tailscaleMode ? (p.ts_url || p.url) : (p.lan_url || p.url);
    const haBadge = p.ha_group
      ? `<span class="status-badge up" style="background:rgba(56,189,248,0.16);color:#38bdf8;border-color:#38bdf8;margin-left:4px" title="Cluster Alta Disponibilidad ${p.ha_group}: ${p.ha_up_count}/${p.ha_total_count} nodos activos (${(p.ha_nodes || []).join(', ')})">⚡ HA ${p.ha_up_count}/${p.ha_total_count}</span>`
      : '';
    const openUrlTarget = (!isUp && p.ha_failover_url) ? p.ha_failover_url : activeUrl;
    const openLabel = (!isUp && p.ha_failover_url) ? `Failover (${p.ha_failover_node})` : `Abrir ${primaryTag}`;
    const openBtn = (p.port && p.port !== 1433 && p.port !== 5555 && openUrlTarget)
      ? `<a class="act-btn open" href="${openUrlTarget}" target="_blank" title="${openUrlTarget}"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-1px"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg> ${openLabel}</a>`
      : '';
    return `
      <div class="card ${isUp ? 'running' : 'stopped'}">
        <div class="card-hdr">
          <div>
            <div class="card-title">${p.name}</div>
            <div class="card-sub">${p.description}</div>
          </div>
          <div style="display:flex;align-items:center">
            ${haBadge}
            <span class="status-badge ${isUp ? 'up' : 'down'}" style="margin-left:4px">${isUp ? 'ONLINE ' + p.latency_ms + 'ms' : 'OFFLINE'}</span>
          </div>
        </div>
        <div class="meta-row">
          <span>${p.node_label}</span>
          <span style="font-weight:700;color:${tailscaleMode ? '#c084fc' : 'var(--cyan)'}">${primaryTag}: ${primaryHost}:${p.port}</span>
        </div>
        <div class="meta-row" style="padding:4px 8px;font-size:10px;color:var(--muted);background:rgba(15,23,42,0.55)">
          <span>URL: ${activeUrl}</span>
          <span>${secondaryTag}: ${secondaryHost}:${p.port}</span>
        </div>
        <div class="actions">
          ${openBtn}
          <button class="act-btn start" onclick="doAction('${p.id}','start')"><svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><polygon points="5 3 19 12 5 21 5 3"/></svg> Start</button>
          <button class="act-btn rst" onclick="doAction('${p.id}','restart')"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-1px"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg> Rst</button>
          <button class="act-btn stop" onclick="doAction('${p.id}','stop')"><svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><rect x="4" y="4" width="16" height="16" rx="2"/></svg> Stop</button>
          <button class="act-btn" onclick="showLogs('${p.id}','${p.name}')"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-1px"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg> Logs</button>
        </div>
      </div>
    `;
  }).join('');
}

function renderNetwork() {
  const ng = document.getElementById('nodesGrid');
  ng.innerHTML = allNodes.map(n => `
    <div class="card ${n.online ? 'running' : 'stopped'}">
      <div class="card-hdr">
        <div>
          <div class="card-title">${n.name}</div>
          <div class="card-sub">${n.role}</div>
        </div>
        <span class="status-badge ${n.online ? 'up' : 'down'}">${n.online ? 'TAILSCALE OK (' + n.latency_ms + 'ms)' : 'OFFLINE'}</span>
      </div>
      <div class="meta-row">
        <span>TS: ${n.ts_ip}</span>
        <span>LAN: ${n.lan_ip}</span>
      </div>
    </div>
  `).join('');

  const portals = [
    { name: "POCO Scrcpy Studio (:8780)", desc: "Capturas Exclusivas en Home (Datos/Wi-Fi) & Stream", lan_url: "http://127.0.0.1:8780/", ts_url: "http://100.90.211.9:8780/" },
    { name: "QB-Network SOC", desc: "Monitoreo Fortigate, VLANs, Trafico & SOC", lan_url: "http://192.168.2.222:5080", ts_url: "http://100.89.1.27:5080" },
    { name: "Selective Router PAC", desc: "Control de Rutas, Nodos y Proxy PAC", lan_url: "http://192.168.2.222:8085", ts_url: "http://100.89.1.27:8085" },
    { name: "OW-IDS Server (.218)", desc: "OpenWazuh IDS & Telemetria de Eventos", lan_url: "http://192.168.2.218:8081", ts_url: "http://100.77.199.69:8081" },
    { name: "SplunkSim SIEM (.218)", desc: "Simulador SIEM & Blue Team SOC Lab", lan_url: "http://192.168.2.218:5015", ts_url: "http://100.77.199.69:5015" },
    { name: "Desencript C2 / IDS", desc: "Consola C2 y Monitoreo IDS Remoto", lan_url: "http://192.168.2.222:8002", ts_url: "http://100.89.1.27:8002" },
    { name: "Brain Hub Central (.237)", desc: "Memoria Unificada & Boveda Cifrada", lan_url: "http://192.168.2.237:8090", ts_url: "http://100.105.210.35:8090" },
    { name: "TaskHub Home (.218)", desc: "Gestor Unificado Classroom & Moodle", lan_url: "http://192.168.2.218:3011", ts_url: "http://100.77.199.69:3011" },
    { name: "BecaFinder Home (.218)", desc: "Buscador Academico de Becas UDG", lan_url: "http://192.168.2.218:3012", ts_url: "http://100.77.199.69:3012" },
  ];
  document.getElementById('quickPortalsGrid').innerHTML = portals.map(p => {
    const activeUrl = tailscaleMode ? p.ts_url : p.lan_url;
    const modeLabel = tailscaleMode ? 'Tailscale' : 'LAN';
    return `
    <div class="card running">
      <div class="card-hdr">
        <div>
          <div class="card-title">${p.name}</div>
          <div class="card-sub">${p.desc}</div>
        </div>
      </div>
      <div class="actions">
        <a class="act-btn open" href="${activeUrl}" target="_blank"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-1px"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg> Abrir en ${modeLabel} (${activeUrl.replace('http://','')})</a>
      </div>
    </div>
  `}).join('');
}

async function doAction(id, action) {
  const r = await fetch('/api/action', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({id, action})
  });
  const res = await r.json();
  setTimeout(fetchStatus, 900);
}

async function wakeAll218() {
  document.getElementById('clockBadge').textContent = 'WAKING .218...';
  await fetch('/api/wake218', {method: 'POST'});
  setTimeout(fetchStatus, 1500);
}

async function testNtfy() {
  document.getElementById('clockBadge').textContent = 'ENVIANDO NTFY...';
  await fetch('/api/ntfy/test', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({source: 'Web-SOC-9000'})});
  setTimeout(fetchStatus, 800);
}

async function showLogs(id, name) {
  document.getElementById('modalTitle').textContent = 'Logs // ' + name;
  document.getElementById('modalContent').textContent = 'Consultando logs remotos...';
  document.getElementById('logModal').classList.add('open');
  const r = await fetch('/api/action', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({id, action: 'logs'})
  });
  const res = await r.json();
  document.getElementById('modalContent').textContent = res.logs || res.message || JSON.stringify(res, null, 2);
}

function closeModal() {
  document.getElementById('logModal').classList.remove('open');
}

async function runRemoteCmd() {
  const node = document.getElementById('termNode').value;
  const cmd = document.getElementById('termCmd').value;
  if (!cmd.trim()) return;
  const outEl = document.getElementById('termOutput');
  outEl.textContent = `[${node}] Ejecutando: ${cmd} ...\n`;
  const r = await fetch('/api/exec', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({node, command: cmd})
  });
  const res = await r.json();
  outEl.textContent = res.output || res.error || '(sin salida)';
}

fetchStatus();
setInterval(fetchStatus, 4000);
</script>
</body>
</html>
"""

TARGET_ALIAS_MAP = {
    "218": "desarrollo",
    "desarrollo": "desarrollo",
    "222": "office-pc",
    "office-pc": "office-pc",
    "home": "home",
    "9": "home",
    "237": "serverwebqb-ts",
    "serverwebqb-ts": "serverwebqb-ts",
    "187": "qb-bd-ts",
    "qb-bd-ts": "qb-bd-ts",
    "poco": "poco",
}


HA_FAILOVER_GROUPS = {
    "HA-MERLIN-9000": ["merlin-soc-home", "merlin-soc-222", "merlin-soc-218", "merlin-soc-237"],
    "HA-BRAIN-8090": ["brain-portal-home", "brain-portal-218", "brain-portal-hub"],
    "HA-PORYGON-5090": ["porygon-xdr-home", "porygon-xdr-222"],
    "HA-ROUTEROS-8085": ["routeros-home", "selective-router"],
    "HA-TASKHUB": ["taskhub-222", "taskhub-home-218"],
    "HA-BECAFINDER": ["becafinder-222", "becafinder-home-218"],
    "HA-OW-IDS": ["desencript-c2", "ow-ids-218"],
    "HA-OLLAMA-LLM": ["ollama-222", "ollama-218"],
    "HA-QB-WEB": ["qb-web-prod", "qb-web-dev", "qb-web-222"],
    "HA-QB-PORTAL": ["qb-panel-dev", "portal-empleados"],
    "HA-POCO-MOBILE": ["poco-scrcpy-home", "poco-agy-auditor", "poco-adb-bridge"],
}


def enrich_ha_clusters(probed: list[dict]) -> list[dict]:
    by_id = {p["id"]: p for p in probed if p.get("id")}
    id_to_group = {}
    for grp, members in HA_FAILOVER_GROUPS.items():
        for mid in members:
            id_to_group[mid] = grp

    for p in probed:
        pid = p.get("id")
        grp = id_to_group.get(pid)
        if not grp:
            continue
        members = [by_id[m] for m in HA_FAILOVER_GROUPS[grp] if m in by_id]
        up_members = [m for m in members if m.get("status") == "RUNNING"]
        p["ha_group"] = grp
        p["ha_up_count"] = len(up_members)
        p["ha_total_count"] = len(members)
        p["ha_nodes"] = [m.get("node_label", "") for m in members]
        if p.get("status") != "RUNNING" and up_members:
            best_peer = sorted(up_members, key=lambda x: x.get("latency_ms") or 999)[0]
            p["ha_failover_url"] = best_peer.get("ts_url") or best_peer.get("url")
            p["ha_failover_node"] = best_peer.get("node_label")
    return probed


class MerlinWebHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _send_json(self, data: dict, status: int = 200):
        raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            raw = INDEX_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return

        if parsed.path in ("/api/status", "/api/health"):
            qs = parse_qs(parsed.query)
            mode_arg = (qs.get("mode", [""])[0] or "").lower()
            host_hdr = self.headers.get("Host", "")
            client_ip = self.client_address[0] if self.client_address else ""
            if mode_arg in ("tail", "tailscale", "ts"):
                use_ts = True
            elif mode_arg in ("lan", "local"):
                use_ts = False
            else:
                use_ts = client_ip.startswith("100.") or host_hdr.startswith("100.")
            projects = load_projects()

            with ThreadPoolExecutor(max_workers=48) as pool:
                proj_futures = [pool.submit(probe_project, p, use_ts) for p in projects]
                node_futures = [pool.submit(check_tcp, n["ts_ip"], n["probe_port"], 0.25) for n in TAILSCALE_NODES]
                probed = enrich_ha_clusters([f.result() for f in proj_futures])
                node_results = [f.result() for f in node_futures]

            nodes_out = []
            for n, (ok, ms) in zip(TAILSCALE_NODES, node_results):
                nodes_out.append({**n, "ip": n["ts_ip"], "online": ok, "latency_ms": ms})

            running = sum(1 for p in probed if p["status"] == "RUNNING")
            stopped = len(probed) - running
            now_str = time.strftime("%H:%M:%S")
            self._send_json({
                "status": "ok",
                "hostname": socket.gethostname(),
                "time": now_str,
                "timestamp": now_str,
                "running": running,
                "stopped": stopped,
                "total": len(probed),
                "projects": probed,
                "services": probed,
                "nodes": nodes_out,
                "tailscale": nodes_out,
            })
            return

        self.send_error(404)

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length).decode("utf-8")) if length > 0 else {}

        if parsed.path == "/api/action":
            act = body.get("action", "")
            pid = body.get("id", "")
            if act == "heal":
                out = run_node_ps("desarrollo", "& 'C:\\Users\\QB_DESARROLLO\\Desktop\\03-Orquestador-y-Proyectos-Home\\Merlin\\start_all_services.ps1'", timeout=18)
                self._send_json({"ok": True, "message": "Auto-Heal completado", "output": out})
                return
            res = control_project(pid, act)
            self._send_json(res)
            return

        if parsed.path == "/api/ntfy/test":
            src = body.get("source", "Merlin-SOC")
            projects = load_projects()
            with ThreadPoolExecutor(max_workers=24) as pool:
                probed = list(pool.map(lambda p: probe_project(p, True), projects))
            up_cnt = sum(1 for p in probed if p["healthy"])
            ok = send_ntfy_alert(
                title=f"Merlin SOC Activo ({up_cnt}/{len(probed)} ONLINE)",
                message=(
                    f"Alerta Push verificada desde {src} ({socket.gethostname()}).\n"
                    f"Servicios activos: {up_cnt}/{len(probed)} en .218 / .222 / Tailscale.\n"
                    f"Regla activa: Alerta solo si un servicio permanece desconectado > 60s."
                ),
                priority="high",
                tags="zap,shield,white_check_mark",
                click_url="http://100.77.199.69:9000",
            )
            self._send_json({"ok": ok, "topic": NTFY_TOPIC, "url": NTFY_URL})
            return

        if parsed.path == "/api/wake218":
            out = run_node_ps("desarrollo", "& 'C:\\Users\\QB_DESARROLLO\\Desktop\\03-Orquestador-y-Proyectos-Home\\Merlin\\start_all_services.ps1'", timeout=18)
            self._send_json({"ok": True, "output": out})
            return

        if parsed.path == "/api/exec":
            raw_node = body.get("node") or body.get("target") or "desarrollo"
            node = TARGET_ALIAS_MAP.get(str(raw_node).lower(), str(raw_node))
            cmd = body.get("command") or body.get("cmd") or ""
            try:
                out = run_node_ps(node, cmd, timeout=15)
                self._send_json({"ok": True, "output": out})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)})
            return

        self.send_error(404)


def auto_heal_and_ntfy_watchdog():
    """Hilo guardian en segundo plano: umbral uniforme de 60s para todos los servicios; alerta al caer >60s y confirma al volver a ONLINE."""
    down_since: dict[str, float] = {}
    alerted_down: set[str] = set()
    time.sleep(10)
    while True:
        try:
            subprocess.run(
                ["powershell", "-NoProfile", "-Command", "if ((Get-Service Tailscale -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service Tailscale -ErrorAction SilentlyContinue }"],
                capture_output=True,
                timeout=6,
            )
            projects = load_projects()
            now_ts = time.time()
            for proj in projects:
                pid = proj.get("id") or ""
                ext_ip = proj.get("external_ip") or "127.0.0.1"
                if not is_local_ip(ext_ip):
                    continue
                info = probe_project(proj, True)
                is_up = bool(info["healthy"])
                if is_up:
                    if pid in alerted_down:
                        total_down = int(now_ts - down_since.get(pid, now_ts))
                        send_ntfy_alert(
                            title=f"ONLINE de nuevo: {info['name']}",
                            message=(
                                f"El servicio {info['name']} (:{info['port']}) en {info['node_label']} "
                                f"volvio a estar ONLINE tras permanecer desconectado {total_down}s (>1 min)."
                            ),
                            priority="default",
                            tags="white_check_mark,merlin",
                            click_url=info.get("url") or "http://100.77.199.69:9000",
                        )
                    down_since.pop(pid, None)
                    alerted_down.discard(pid)
                    continue

                if pid not in down_since:
                    down_since[pid] = now_ts
                    control_project(pid, "restart")
                    continue

                down_elapsed = now_ts - down_since[pid]
                control_project(pid, "restart")
                time.sleep(2.0)
                recheck = probe_project(proj, True)
                if bool(recheck["healthy"]):
                    if pid in alerted_down:
                        total_down = int(time.time() - down_since.get(pid, now_ts))
                        send_ntfy_alert(
                            title=f"ONLINE de nuevo: {info['name']}",
                            message=(
                                f"El servicio {info['name']} (:{info['port']}) en {info['node_label']} "
                                f"fue auto-recuperado tras permanecer desconectado {total_down}s (>1 min)."
                            ),
                            priority="default",
                            tags="white_check_mark,merlin",
                            click_url=info.get("url") or "http://100.77.199.69:9000",
                        )
                    down_since.pop(pid, None)
                    alerted_down.discard(pid)
                    continue

                if down_elapsed >= 60.0 and pid not in alerted_down:
                    alerted_down.add(pid)
                    send_ntfy_alert(
                        title=f"Desconectado >1 min: {info['name']}",
                        message=(
                            f"El servicio {info['name']} (:{info['port']}) en {info['node_label']} "
                            f"permanece desconectado tras {int(down_elapsed)}s y reintentos de Auto-Heal."
                        ),
                        priority="urgent",
                        tags="warning,merlin",
                        click_url="http://100.77.199.69:9000",
                    )
        except Exception as e:
            print(f"[watchdog] Error: {e}")
        time.sleep(20)



if __name__ == "__main__":
    t = threading.Thread(target=auto_heal_and_ntfy_watchdog, daemon=True)
    t.start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), MerlinWebHandler)
    print(f"[*] Merlin v2.5 Mobile & Network Command Center listening on http://0.0.0.0:{PORT} (ntfy: {NTFY_TOPIC})")
    server.serve_forever()


