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
    # Windows PowerShell 5.1 keeps web responses in the local Internet cache for minutes.
    [Net.WebRequest]::DefaultCachePolicy = New-Object Net.Cache.HttpRequestCachePolicy ([Net.Cache.HttpRequestCacheLevel]::NoCacheNoStore)

    $dir  = Join-Path $env:LOCALAPPDATA 'ReShadeFiveM'
    $file = Join-Path $dir 'install-reshade.ps1'
    $url  = 'https://raw.githubusercontent.com/x2Swiftyouz/Reshade-auto-installation/main/install-reshade.ps1'

    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # raw.githubusercontent.com caches "main" for a few minutes. Ask GitHub for the newest
    # commit and download that exact version, so a fresh push is used right away.
    try {
        $api = 'https://api.github.com/repos/x2Swiftyouz/Reshade-auto-installation/commits/main'
        $sha = (Invoke-RestMethod -Uri ($api + '?t=' + [DateTime]::UtcNow.Ticks) -UseBasicParsing -Headers @{ 'User-Agent' = 'ReShadeFiveM'; 'Cache-Control' = 'no-cache' }).sha
        if ($sha -match '^[0-9a-f]{40}$') { $url = $url -replace '/main/', "/$sha/" }
    } catch {
        $url = $url + '?nocache=' + [DateTime]::UtcNow.Ticks
    }

    $ver = if ($url -match '/([0-9a-f]{40})/') { $Matches[1].Substring(0, 7) } else { 'main' }
    Write-Host "Downloading ReShade for FiveM (build $ver) ..." -ForegroundColor Cyan
    # A unique query string also skips any local cache.
    $url = $url + $(if ($url.Contains('?')) { '&' } else { '?' }) + 't=' + [DateTime]::UtcNow.Ticks
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }

    # Run in this window so any error stays visible here. The app window opens on top;
    # this prompt returns when the app is closed.
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Host 'Opening ReShade for FiveM (this window waits until you close it) ...' -ForegroundColor Green
    & $ps -NoProfile -ExecutionPolicy Bypass -File $file
    if ($LASTEXITCODE) { Write-Host "ReShade for FiveM ended with exit code $LASTEXITCODE. Logs: $dir\logs" -ForegroundColor Yellow }
}
