@echo off
title Merlin Server Manager
powershell -ExecutionPolicy Bypass -File "%~dp0orchestrator.ps1"
