@echo off
cd /d "%~dp0"

powershell.exe -ExecutionPolicy Bypass -File start_dashboard.ps1 -Environment QA