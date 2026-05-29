# Dev Orchestrator - Production Blueprint

This folder contains a fully cross-platform (Windows & Linux) blueprint of the Dev Server Manager orchestrator. It features the exact same functionality, design, and robust networking checks (including the new TCP fallback for remote services) as the original version.

## Requirements

- **Windows**: PowerShell 5.1+ (built-in).
- **Linux / macOS**: [PowerShell Core (`pwsh`)](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux). The script intelligently switches to using `ss` for port detection and `sh -c` for process launching on Linux.

## Setup Instructions

1. **Configure your projects:**
   Open `projects.json` and replace the placeholder projects with your actual production services.
   
   Configuration Keys:
   - `id`: Unique slug identifier (no spaces)
   - `name`: Display name
   - `path`: Absolute or relative path to the working directory
   - `command`: The launch command (e.g., `npm run start`, `python app.py`)
   - `port`: The port the service will listen on (used for instant status detection)
   - `external_ip`: The IP to ping if running on another node
   - `ssh`: An optional block to control the service remotely via SSH keys

2. **Launch the Orchestrator:**
   - **Windows:** Double-click `start.bat` or run `.\start.bat` in a terminal.
   - **Linux/macOS:** Run `./start.sh` in a terminal (make sure it has execute permissions: `chmod +x start.sh`).

## Features
- **Instant Status Detection**: Monitors processes locally and maps ports natively.
- **Robust SSH Control**: For distributed microservices, it can trigger `start`/`stop`/`status` commands over SSH.
- **TCP Fallback**: If an SSH query fails, it seamlessly falls back to pinging the specified `port` directly.
- **Cross-Platform Lifecycle**: Kills processes and all their child-processes perfectly across Windows and Linux (`Get-CimInstance` on Windows, `pgrep` on Linux).
- **In-Memory Logging**: Captures `stdout` and `stderr` directly into the `logs/` directory.
