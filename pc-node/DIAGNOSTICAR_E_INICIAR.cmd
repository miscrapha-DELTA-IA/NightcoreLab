@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0DIAGNOSTICAR_E_INICIAR.ps1"
