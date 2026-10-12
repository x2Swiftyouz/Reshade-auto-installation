@echo off
rem Builds "ReShade FiveM.exe" (one file with icon) from install-reshade.ps1.
rem Keep this file in the same folder as install-reshade.ps1 and build-exe.ps1.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-exe.ps1"
pause
