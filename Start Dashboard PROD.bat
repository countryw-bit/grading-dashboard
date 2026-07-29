@echo off
cd /d "%~dp0"

echo.
echo ********************************************
echo *        PRODUCTION DATABASE               *
echo ********************************************
echo.

pause

powershell.exe -ExecutionPolicy Bypass -File start_dashboard.ps1 -Environment PROD