# Builds "ReShade FiveM.exe" from install-reshade.ps1 with the ps2exe module.
# Needs internet once, to install ps2exe from the PowerShell Gallery.

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

$src = Join-Path $PSScriptRoot 'install-reshade.ps1'
$out = Join-Path $PSScriptRoot 'ReShade FiveM.exe'
if (-not (Test-Path -LiteralPath $src)) { throw "install-reshade.ps1 not found in $PSScriptRoot" }

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing ps2exe (PowerShell Gallery) ...' -ForegroundColor Cyan
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

Write-Host 'Creating icon ...' -ForegroundColor Cyan
$icon = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $src -Action icon | Select-Object -Last 1
if (-not $icon -or -not (Test-Path -LiteralPath $icon)) { throw 'Icon was not created.' }

Write-Host 'Building exe ...' -ForegroundColor Cyan
Invoke-ps2exe -inputFile $src -outputFile $out -iconFile $icon -noConsole -STA `
    -title 'ReShade for FiveM' -product 'ReShade for FiveM' -description 'ReShade installer for FiveM' -version '3.0.0.0'

if (Test-Path -LiteralPath $out) {
    Write-Host ''
    Write-Host "Done: $out" -ForegroundColor Green
    Write-Host 'Some antivirus programs flag ps2exe files by mistake. If that happens, use Install-ReShade-FiveM.bat instead.' -ForegroundColor Yellow
} else {
    throw 'Build failed.'
}
