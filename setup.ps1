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

    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$file`""
    Write-Host 'Opening ReShade for FiveM ...' -ForegroundColor Green
}
