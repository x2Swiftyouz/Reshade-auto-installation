@echo off
rem Double-click to open "ReShade for FiveM".
rem Keep this file in the same folder as install-reshade.ps1.
cd /d "%~dp0"
if not exist "%~dp0install-reshade.ps1" (
  echo install-reshade.ps1 not found next to this file.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0install-reshade.ps1"
