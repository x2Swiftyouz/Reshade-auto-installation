# ReShade for FiveM - one-line launcher
#   irm https://raw.githubusercontent.com/x2Swiftyouz/Reshade-auto-installation/main/setup.ps1 | iex
#
# Downloads install-reshade.ps1 to %LOCALAPPDATA%\ReShadeFiveM and starts it as a file.
# (install-reshade.ps1 contains Thai text and must run as a UTF-8 file, not through iex.)
# This file must stay plain ASCII without a BOM so that "irm | iex" can read it.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

    $dir  = Join-Path $env:LOCALAPPDATA 'ReShadeFiveM'
    $file = Join-Path $dir 'install-reshade.ps1'
    $url  = 'https://raw.githubusercontent.com/x2Swiftyouz/Reshade-auto-installation/main/install-reshade.ps1'

    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Host 'Downloading ReShade for FiveM ...' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing

    # Run in this window so any error stays visible here. The app window opens on top;
    # this prompt returns when the app is closed.
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Host 'Opening ReShade for FiveM (this window waits until you close it) ...' -ForegroundColor Green
    & $ps -NoProfile -ExecutionPolicy Bypass -File $file
    if ($LASTEXITCODE) { Write-Host "ReShade for FiveM ended with exit code $LASTEXITCODE. Logs: $dir\logs" -ForegroundColor Yellow }
}
