#!/usr/bin/env bash
# Quick launcher script for Linux/macOS
echo "=========================================="
echo "  Dev Orchestrator - Server Manager       "
echo "=========================================="

cd "$(dirname "$0")" || exit

# Check if pwsh is installed
if ! command -v pwsh &> /dev/null; then
    echo "ERROR: PowerShell Core (pwsh) is not installed."
    echo "Please install it via your package manager or snap:"
    echo "  sudo snap install powershell --classic"
    echo "  or see: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
    exit 1
fi

pwsh -NoProfile -ExecutionPolicy Bypass -File orchestrator.ps1
