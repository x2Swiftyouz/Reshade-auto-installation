<#
  ReShade for FiveM - installer / manager
  ---------------------------------------
  - Downloads ReShade only from reshade.me (always the newest version).
  - Installs only into the FiveM plugins folder. The GTA V folder is never touched.
  - Installs effect packages from the official ReShade package list.
  - Adds the [Addons] ReShade line to CitizenFX.ini by itself.

  Start: double-click "Install-ReShade-FiveM.bat" (opens the window), or in PowerShell:
    irm https://raw.githubusercontent.com/x2Swiftyouz/Reshade-auto-installation/main/setup.ps1 | iex

  Command line (no window):
    powershell -ExecutionPolicy Bypass -File .\install-reshade.ps1 -NoGui
    -Action    menu | install | repair | effects | cleanup | preset | restore | open | uninstall | check
    -Packages  recommended | all | basic | "0,1,9,23"
    -Preset    path or https URL of a preset .ini
    -Addon     use the ReShade build with full add-on support
    -Force     reinstall ReShade even if the newest version is installed
    -PerformanceMode   turn on ReShade performance mode
    -NoGui     use the text menu instead of the window
    -NoAutoClose       keep the text window open at the end
    -Lang      th | en
    -FiveMApp  path to FiveM.app if FiveM is not in the default place
#>

param(
    [ValidateSet('menu', 'install', 'repair', 'effects', 'cleanup', 'preset', 'restore', 'open', 'uninstall', 'check', 'icon')]
    [string]$Action = 'menu',
    [string]$Packages,
    [string]$Preset,
    [switch]$Addon,
    [switch]$Force,
    [switch]$PerformanceMode,
    [switch]$NoGui,
    [switch]$NoAutoClose,
    [ValidateSet('th', 'en')]
    [string]$Lang,
    [string]$FiveMApp
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The launcher starts this script with a hidden console. Any error not handled below
# is shown in a message box, so it is never silent.
function Show-FatalError($err) {
    $text = 'ReShade for FiveM error:' + "`n`n" + $err.Exception.Message
    if ($err.InvocationInfo) { $text += "`n`nLine " + $err.InvocationInfo.ScriptLineNumber + ': ' + $err.InvocationInfo.Line.Trim() }
    $text += "`n`nLogs: " + (Join-Path $env:LOCALAPPDATA 'ReShadeFiveM\logs')
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($text, 'ReShade for FiveM', 'OK', 'Error')
    } catch { Write-Host $text -ForegroundColor Red }
}
trap { Show-FatalError $_; break }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

# If you host this script online (for "irm ... | iex"), put its raw URL here so the
# Desktop shortcut and the weekly update check can save a local copy.
$SelfUrl = 'https://raw.githubusercontent.com/x2Swiftyouz/Reshade-auto-installation/main/install-reshade.ps1'
$ScriptVersion = '3.0'

# Running as an .exe built with ps2exe?
$SelfProcess = (Get-Process -Id $PID).Path
$IsExe = $SelfProcess -and ([IO.Path]::GetFileName($SelfProcess) -notmatch '^(powershell|pwsh|powershell_ise)(\.exe)?$')
$SelfScript = $PSCommandPath

# ============================================================================
#  CORE - shared by the window (runs in a background runspace) and the text menu.
#  Everything it needs comes from the $Ctx hashtable.
# ============================================================================
$Core = {

$Site            = 'https://reshade.me'
$FallbackVersion = '6.8.0'
$PackageListUrl  = 'https://raw.githubusercontent.com/crosire/reshade-shaders/list/EffectPackages.ini'
$AckPattern      = '(ReShade\d*)=(ID:[0-9A-Fa-f]+ acknowledged that ReShade[^\r\n"]*?game crashes)'
$TaskName        = 'ReShadeFiveM Update Check'
$Utf8NoBom       = New-Object Text.UTF8Encoding $false

# Packages picked by "recommended" (matched by download URL, so list order does not matter).
$RecommendedKeys = @(
    'crosire/reshade-shaders/archive/slim',
    'CeeJayDK/SweetFX',
    'martymcmodding/qUINT',
    'martymcmodding/iMMERSE',
    'prod80/prod80-ReShade-Repository',
    'BlueSkyDefender/AstrayFX',
    'FransBouma/OtisFX',
    'luluco250/FXShaders',
    'LordOfLunacy/Insane-Shaders'
)

# Keys offered for ReShade hotkeys (Windows virtual-key codes).
$KeyList = [ordered]@{
    '-' = 0; 'Home' = 36; 'End' = 35; 'Insert' = 45; 'Delete' = 46; 'Page Up' = 33; 'Page Down' = 34
    'F1' = 112; 'F2' = 113; 'F3' = 114; 'F4' = 115; 'F5' = 116; 'F6' = 117; 'F7' = 118; 'F8' = 119
    'F9' = 120; 'F10' = 121; 'F11' = 122; 'F12' = 123; 'Scroll Lock' = 145; 'Pause' = 19
    'Print Screen' = 44; 'Num *' = 106; 'Num -' = 109; 'Num +' = 107; 'Num /' = 111
}

# ---------------------------------------------------------------------------
#  Download one URL to a file, with an ETag cache. Also used in parallel jobs,
#  so it only uses its parameters.
# ---------------------------------------------------------------------------
$DownloadBlock = {
    param([string]$Url, [string]$Out, $Dl, [string]$Key, [bool]$UseCache)
    $meta = "$Out.etag"
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'ReShadeFiveM-Installer'
    $req.AllowAutoRedirect = $true
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 60000
    if ($UseCache -and (Test-Path -LiteralPath $Out) -and (Test-Path -LiteralPath $meta)) {
        $req.Headers['If-None-Match'] = [IO.File]::ReadAllText($meta).Trim()
    }
    try {
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $r = $_.Exception.Response
        if ($r -and [int]$r.StatusCode -eq 304) {
            $r.Close()
            if ($Dl) { $Dl[$Key] = @{ Done = 0L; Total = 0L; State = 'cached' } }
            return 'cached'
        }
        throw
    }
    try {
        $total = $resp.ContentLength
        $tmp = "$Out.part"
        $in = $resp.GetResponseStream()
        $fs = [IO.File]::Create($tmp)
        $buf = New-Object byte[] 65536
        $done = 0L
        try {
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n)
                $done += $n
                if ($Dl) { $Dl[$Key] = @{ Done = $done; Total = $total; State = 'run' } }
            }
        } finally { $fs.Dispose(); $in.Dispose() }
        if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
        Move-Item -LiteralPath $tmp -Destination $Out
        $etag = $resp.Headers['ETag']
        if ($etag) { [IO.File]::WriteAllText($meta, $etag) }
        elseif (Test-Path -LiteralPath $meta) { Remove-Item -LiteralPath $meta -Force }
        if ($Dl) { $Dl[$Key] = @{ Done = $done; Total = $total; State = 'done' } }
        return 'downloaded'
    } finally { $resp.Close() }
}

# ---------------------------------------------------------------------------
#  Text, log and progress
# ---------------------------------------------------------------------------
function M([string]$th, [string]$en) { if ($Ctx.Lang -eq 'en') { $en } else { $th } }

function Log([string]$level, [string]$text) {
    if ($Ctx.Sync) { $Ctx.Sync.Log.Enqueue(@($level, $text)); return }
    $uni = [bool]$env:WT_SESSION
    switch ($level) {
        'step' { Write-Host ''; Write-Host ('  ' + $(if ($uni) { [string][char]0x25B6 + ' ' } else { '> ' })) -ForegroundColor Cyan -NoNewline; Write-Host $text -ForegroundColor White }
        'ok'   { Write-Host ('      ' + $(if ($uni) { [string][char]0x2714 + ' ' } else { '[OK] ' })) -ForegroundColor Green -NoNewline; Write-Host $text }
        'warn' { Write-Host ('      ' + $(if ($uni) { [string][char]0x26A0 + ' ' } else { '[!!] ' })) -ForegroundColor Yellow -NoNewline; Write-Host $text -ForegroundColor Yellow }
        'err'  { Write-Host ('      ' + $(if ($uni) { [string][char]0x2716 + ' ' } else { '[XX] ' })) -ForegroundColor Red -NoNewline; Write-Host $text -ForegroundColor Red }
        default { Write-Host "        $text" -ForegroundColor Gray }
    }
}

function Step([string]$text) {
    $Ctx.StepNo++
    Log 'step' ('[{0}/{1}] {2}' -f $Ctx.StepNo, $Ctx.StepTotal, $text)
    Set-Progress ([int](100 * ($Ctx.StepNo - 1) / [Math]::Max(1, $Ctx.StepTotal))) $text
}

function Set-Progress([int]$pct, [string]$text) {
    if ($Ctx.Sync) { $Ctx.Sync.Pct = [Math]::Min(100, [Math]::Max(0, $pct)); if ($text) { $Ctx.Sync.Status = $text } }
}

# One-line live status in the text window (the window shows it in its status bar).
function Set-Detail([string]$text) {
    if ($Ctx.Sync) { $Ctx.Sync.Detail = $text; return }
    try {
        $w = [Math]::Max(20, [Console]::WindowWidth - 2)
        if ($text) { Write-Host ("`r        " + $text).PadRight($w).Substring(0, $w) -NoNewline -ForegroundColor DarkGray }
        else { Write-Host ("`r" + (' ' * $w) + "`r") -NoNewline }
    } catch {}
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N2} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N1} MB' -f ($bytes / 1MB) }
    return '{0:N0} KB' -f ($bytes / 1KB)
}

function Show-Toast([string]$title, [string]$body) {
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        $null = $nodes.Item(0).AppendChild($xml.CreateTextNode($title))
        $null = $nodes.Item(1).AppendChild($xml.CreateTextNode($body))
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {}
}

# ---------------------------------------------------------------------------
#  Paths and state
# ---------------------------------------------------------------------------
function Set-CtxPaths([string]$fivemApp) {
    $Ctx.FiveMApp   = $fivemApp
    $Ctx.Plugins    = Join-Path $fivemApp 'plugins'
    $Ctx.ShadersDir = Join-Path $Ctx.Plugins 'reshade-shaders'
    $Ctx.Disabled   = Join-Path $Ctx.Plugins 'reshade-shaders-disabled'
    $Ctx.PresetDir  = Join-Path $Ctx.Plugins 'presets'
    $Ctx.ReShadeIni = Join-Path $Ctx.Plugins 'ReShade.ini'
    $Ctx.ReShadeDll = Join-Path $Ctx.Plugins 'dxgi.dll'
    $Ctx.ReShadeLog = Join-Path $Ctx.Plugins 'ReShade.log'
    $Ctx.CitizenIni = Join-Path $fivemApp 'CitizenFX.ini'
    $Ctx.FiveMLogs  = Join-Path $fivemApp 'logs'
    $Ctx.FiveMExe   = Join-Path (Split-Path -Parent $fivemApp) 'FiveM.exe'
}

function Get-State {
    $h = @{
        Packages = @(); Addon = $false; Version = ''; Lang = ''; AutoLaunch = $false; WeeklyCheck = $true
        Shortcut = $true; PerformanceMode = $false; FiveMApp = ''; DisabledFx = @()
    }
    if (Test-Path -LiteralPath $Ctx.StateFile) {
        try {
            $j = [IO.File]::ReadAllText($Ctx.StateFile) | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch {}
    }
    $h.Packages = @($h.Packages | Where-Object { $_ })
    $h.DisabledFx = @($h.DisabledFx | Where-Object { $_ })
    return $h
}

function Save-State {
    New-Item -ItemType Directory -Path $Ctx.HomeDir -Force | Out-Null
    [IO.File]::WriteAllText($Ctx.StateFile, (ConvertTo-Json $Ctx.State -Depth 4), $Utf8NoBom)
}

function Find-FiveM {
    $cands = New-Object System.Collections.Generic.List[string]
    $cands.Add((Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app'))
    foreach ($root in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and ($p.DisplayName -match 'FiveM' -or $_.PSChildName -match 'FiveM')) {
                foreach ($loc in @($p.InstallLocation, ($(if ($p.DisplayIcon) { Split-Path -Parent ($p.DisplayIcon -replace '"|,\d+$', '') })))) {
                    if ($loc) { $cands.Add((Join-Path $loc 'FiveM.app')) }
                }
            }
        }
    }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'),
                  [Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('CommonStartMenu'))
        foreach ($d in $dirs) {
            if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
            Get-ChildItem -LiteralPath $d -Filter 'FiveM*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $t = $ws.CreateShortcut($_.FullName).TargetPath
                if ($t -and $t -match 'FiveM\.exe$') { $cands.Add((Join-Path (Split-Path -Parent $t) 'FiveM.app')) }
            }
        }
    } catch {}
    foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($sub in 'FiveM\FiveM.app', 'Games\FiveM\FiveM.app', 'Program Files\FiveM\FiveM.app') {
            $cands.Add((Join-Path $drv.Root $sub))
        }
    }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return [IO.Path]::GetFullPath($c) } }
    return $null
}

# ---------------------------------------------------------------------------
#  File helpers
# ---------------------------------------------------------------------------
function Read-SharedText([string]$path) {
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Read-Lines([string]$path) {
    $list = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $path) { foreach ($l in [IO.File]::ReadAllLines($path)) { $list.Add($l) } }
    return , $list
}

function Write-Lines([string]$path, $lines) { [IO.File]::WriteAllLines($path, [string[]]$lines, $Utf8NoBom) }

function Set-IniValue([string]$path, [string]$section, [string]$key, [string]$value) {
    $lines = Read-Lines $path
    $sec = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq "[$section]") { $sec = $i; break } }
    if ($sec -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines.Add('') }
        $lines.Add("[$section]"); $lines.Add("$key=$value")
    } else {
        $end = $lines.Count
        for ($i = $sec + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -match '^\[.+\]$') { $end = $i; break } }
        $done = $false
        for ($i = $sec + 1; $i -lt $end; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $lines[$i] = "$key=$value"; $done = $true; break }
        }
        if (-not $done) {
            $at = $end
            while ($at -gt $sec + 1 -and $lines[$at - 1].Trim() -eq '') { $at-- }
            $lines.Insert($at, "$key=$value")
        }
    }
    Write-Lines $path $lines
}

function Get-IniValue([string]$path, [string]$section, [string]$key) {
    $inSec = $false
    foreach ($l in (Read-Lines $path)) {
        $t = $l.Trim()
        if ($t -match '^\[(.+)\]$') { $inSec = ($Matches[1] -ieq $section); continue }
        if ($inSec -and $t -match "^$([regex]::Escape($key))\s*=(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

function Get-Download([string]$url, [string]$out, [switch]$Cache) {
    & $DownloadBlock $url $out $Ctx.Dl ([IO.Path]::GetFileName($out)) ([bool]$Cache)
}

function New-Stage {
    $s = Join-Path $env:TEMP ('reshade-fivem-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $s | Out-Null
    return $s
}

function Get-DirSize([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $s = 0L
    foreach ($f in Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue) { $s += $f.Length }
    return $s
}

# ---------------------------------------------------------------------------
#  FiveM
# ---------------------------------------------------------------------------
function Test-FiveMRunning { [bool](Get-Process -Name 'FiveM*' -ErrorAction SilentlyContinue) }

function Stop-FiveM {
    Get-Process -Name 'FiveM*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Count down in the text window; $true if a key was pressed.
function Wait-Countdown([string]$text, [int]$seconds) {
    for ($i = $seconds; $i -gt 0; $i--) {
        Write-Host ("`r        $text ($i) ") -ForegroundColor DarkGray -NoNewline
        for ($j = 0; $j -lt 10; $j++) {
            try { if ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true); Write-Host ''; return $true } } catch {}
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ''
    return $false
}

function Close-FiveM {
    if (-not (Test-FiveMRunning)) { Log 'ok' (M 'FiveM ไม่ได้เปิดอยู่' 'FiveM is not running'); return }
    if (-not $Ctx.Sync) {
        Log 'warn' (M 'FiveM เปิดอยู่ ต้องปิดก่อน' 'FiveM is running and must be closed first')
        if (Wait-Countdown (M 'จะปิด FiveM ให้ กดปุ่มใดก็ได้เพื่อยกเลิก' 'Closing FiveM, press any key to cancel') 5) {
            throw (M 'ยกเลิก: FiveM ยังเปิดอยู่' 'Cancelled: FiveM is still running')
        }
    }
    Stop-FiveM
    Log 'ok' (M 'ปิด FiveM แล้ว' 'FiveM closed')
}

function Test-ReShadeAck {
    (Test-Path -LiteralPath $Ctx.CitizenIni) -and
        (Select-String -LiteralPath $Ctx.CitizenIni -Pattern '^\s*ReShade\d*\s*=\s*ID:' -Quiet)
}

function Add-ReShadeAckFromLogs {
    if (Test-ReShadeAck) { return $true }
    if (-not (Test-Path -LiteralPath $Ctx.FiveMLogs)) { return $false }
    $logs = Get-ChildItem -LiteralPath $Ctx.FiveMLogs -Filter '*.log' -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($lg in $logs) {
        $m = [regex]::Match((Read-SharedText $lg.FullName), $AckPattern)
        if ($m.Success) { Set-IniValue $Ctx.CitizenIni 'Addons' $m.Groups[1].Value $m.Groups[2].Value.Trim(); return $true }
    }
    return $false
}

function Add-ReShadeAckByLaunch([int]$timeoutSec = 180) {
    if (-not (Test-Path -LiteralPath $Ctx.FiveMExe)) { Log 'warn' ((M 'ไม่พบ FiveM.exe: ' 'FiveM.exe not found: ') + $Ctx.FiveMExe); return $false }
    Log 'info' (M 'เปิด FiveM 1 ครั้งเพื่อดึงรหัส ReShade (จะปิดให้เอง) ...' 'Starting FiveM once to get the ReShade ID (closes by itself) ...')
    Start-Process -FilePath $Ctx.FiveMExe | Out-Null
    $spin = '|/-\'
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $ok = $false; $i = 0
    while ((Get-Date) -lt $deadline) {
        Set-Detail ((M 'รอ FiveM ' 'Waiting for FiveM ') + $spin[$i++ % 4] + ' ' + [int]($deadline - (Get-Date)).TotalSeconds + 's')
        Start-Sleep -Milliseconds 500
        if (($i % 6) -eq 0 -and (Add-ReShadeAckFromLogs)) { $ok = $true; break }
    }
    Set-Detail $null
    Stop-FiveM
    Log 'info' (M 'ปิด FiveM แล้ว' 'FiveM closed')
    return $ok
}

function Confirm-Ack {
    if (Add-ReShadeAckFromLogs) { Log 'ok' (M 'CitizenFX.ini มีบรรทัด [Addons] ReShade แล้ว' 'CitizenFX.ini has the [Addons] ReShade line'); return }
    if (Add-ReShadeAckByLaunch) { Log 'ok' (M 'เพิ่มบรรทัด [Addons] ReShade ใน CitizenFX.ini แล้ว' 'Added the [Addons] ReShade line to CitizenFX.ini'); return }
    Log 'warn' (M 'ไม่พบรหัสใน log ของ FiveM เปิด FiveM 1 ครั้งแล้วกด "ซ่อม"' 'ReShade ID not found in FiveM logs. Start FiveM once, then run Repair.')
}

# ---------------------------------------------------------------------------
#  ReShade
# ---------------------------------------------------------------------------
function Get-InstalledReShade {
    if (-not (Test-Path -LiteralPath $Ctx.ReShadeDll)) { return $null }
    $vi = (Get-Item -LiteralPath $Ctx.ReShadeDll).VersionInfo
    if ($vi.ProductName -notmatch 'ReShade' -and $vi.FileDescription -notmatch 'ReShade') { return 'unknown' }
    return ('{0}.{1}.{2}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart)
}

function Get-LatestReShade([bool]$addon) {
    $suffix = if ($addon) { '_Addon' } else { '' }
    $pattern = 'href="(?<href>[^"]*ReShade_Setup_(?<ver>\d+(?:\.\d+)+)' + $suffix + '\.exe)"'
    $result = $null
    try {
        $html = (Invoke-WebRequest -Uri $Site -UseBasicParsing).Content
        $best = [regex]::Matches($html, $pattern) | Sort-Object { [version]$_.Groups['ver'].Value } -Descending | Select-Object -First 1
        if ($best) {
            $result = [pscustomobject]@{ Version = $best.Groups['ver'].Value; Url = ([Uri]::new([Uri]$Site, $best.Groups['href'].Value)).AbsoluteUri; Online = $true }
        }
    } catch {}
    if (-not $result) {
        $result = [pscustomobject]@{ Version = $FallbackVersion; Url = "$Site/downloads/ReShade_Setup_${FallbackVersion}${suffix}.exe"; Online = $false }
    }
    if (([Uri]$result.Url).Host -notmatch '(^|\.)reshade\.me$') { throw ((M 'ลิงก์ดาวน์โหลดไม่ได้อยู่บน reshade.me: ' 'Download link is not on reshade.me: ') + $result.Url) }
    return $result
}

function Install-ReShadeDll($latest, [string]$stage) {
    $exe = Join-Path $stage ([IO.Path]::GetFileName(([Uri]$latest.Url).AbsolutePath))
    Log 'info' ((M 'ดาวน์โหลด ' 'Downloading ') + [IO.Path]::GetFileName($exe))
    $null = Get-Download $latest.Url $exe
    Log 'info' ('SHA256: ' + (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash)
    $sig = Get-AuthenticodeSignature -FilePath $exe
    $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { 'none' }
    switch ($sig.Status) {
        'Valid'        { Log 'ok' ((M 'ลายเซ็นถูกต้อง: ' 'Signature valid: ') + $signer) }
        'HashMismatch' { throw (M 'ไฟล์ติดตั้งถูกแก้ไขหลังเซ็น (HashMismatch) ยกเลิก' 'Installer was modified after signing (HashMismatch). Aborted.') }
        default        { Log 'warn' (M "ลายเซ็น: $($sig.Status) ($signer) ไฟล์มาจาก reshade.me ผ่าน HTTPS ทำต่อ" "Signature: $($sig.Status) ($signer). Source is reshade.me over HTTPS; continuing.") }
    }
    # ReShade setup needs a target exe. A copy of 64-bit powershell.exe named GTA5.exe
    # in a temp folder is enough, so the real GTA V folder is never touched.
    $game = Join-Path $stage 'game'
    New-Item -ItemType Directory -Path $game | Out-Null
    $standIn = Join-Path $game 'GTA5.exe'
    Copy-Item -LiteralPath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -Destination $standIn
    Log 'info' (M 'ติดตั้งแบบเงียบ (DirectX 10/11/12) ...' 'Running setup headless (DirectX 10/11/12) ...')
    $p = Start-Process -FilePath $exe -ArgumentList @("`"$standIn`"", '--headless', '--api', 'dxgi') -Wait -PassThru -WindowStyle Hidden
    $built = Join-Path $game 'dxgi.dll'
    if (-not (Test-Path -LiteralPath $built)) { throw ((M 'ตัวติดตั้ง ReShade ไม่ได้สร้าง dxgi.dll (exit code ' 'ReShade setup did not create dxgi.dll (exit code ') + "$($p.ExitCode))") }
    New-Item -ItemType Directory -Path $Ctx.Plugins -Force | Out-Null
    Copy-Item -LiteralPath $built -Destination $Ctx.ReShadeDll -Force
    Log 'ok' (M 'ติดตั้ง dxgi.dll ลง plugins แล้ว' 'dxgi.dll installed to plugins')
}

# ---------------------------------------------------------------------------
#  Effect packages (official ReShade list)
# ---------------------------------------------------------------------------
function Get-PackageList {
    $cache = Join-Path $Ctx.HomeDir 'cache'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $file = Join-Path $cache 'EffectPackages.ini'
    try { $null = Get-Download $PackageListUrl $file -Cache }
    catch { if (-not (Test-Path -LiteralPath $file)) { throw } }
    $list = @(); $cur = $null
    foreach ($raw in [IO.File]::ReadAllLines($file)) {
        $l = $raw.Trim()
        if ($l -eq '' -or $l.StartsWith(';')) { continue }
        if ($l -match '^\[(.+)\]$') { if ($cur) { $list += $cur }; $cur = [ordered]@{ Id = $Matches[1] }; continue }
        if ($cur -and $l -match '^([^=]+)=(.*)$') { $cur[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    if ($cur) { $list += $cur }
    $i = 0
    foreach ($p in $list) {
        $url = [string]$p['DownloadUrl']
        [pscustomobject]@{
            No          = $i++
            Name        = [string]$p['PackageName']
            Description = [string]$p['PackageDescription']
            InstallPath = [string]$p['InstallPath']
            TexturePath = [string]$p['TextureInstallPath']
            Url         = $url
            Repo        = [string]$p['RepositoryUrl']
            Deny        = @(([string]$p['DenyEffectFiles'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            Required    = ($p['Required'] -eq '1')
            Recommended = [bool]($RecommendedKeys | Where-Object { $url -like "*$_*" })
        }
    }
}

function Select-Packages($all, [string]$mode) {
    switch -Regex ($mode) {
        '^(recommended|r)$' { $pick = @($all | Where-Object { $_.Recommended }) }
        '^(all|a)$'         { $pick = @($all) }
        '^(basic|b)$'       { $pick = @() }
        default {
            $nums = @($mode -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
            $pick = @($all | Where-Object { $nums -contains $_.No })
        }
    }
    return @(@($all | Where-Object { $_.Required }) + @($pick | Where-Object { -not $_.Required }))
}

function Resolve-PluginPath([string]$rel) {
    $rel = ($rel -replace '^\.[\\/]', '') -replace '/', '\'
    $full = [IO.Path]::GetFullPath((Join-Path $Ctx.Plugins $rel))
    if (-not $full.StartsWith([IO.Path]::GetFullPath($Ctx.Plugins), [StringComparison]::OrdinalIgnoreCase)) { throw "Package path outside plugins: $rel" }
    return $full
}

function Get-TopDir([string]$base, [string]$name) {
    Get-ChildItem -LiteralPath $base -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq $name } | Sort-Object { $_.FullName.Split('\').Count } | Select-Object -First 1
}

# Copy files; a file already placed in this run is not overwritten, so packages
# installed first (the standard effects) keep their shared headers.
function Copy-Tree([string]$src, [string]$dst, $claimed, $deny) {
    $n = 0
    $srcFull = [IO.Path]::GetFullPath($src).TrimEnd('\')
    foreach ($f in Get-ChildItem -LiteralPath $src -File -Recurse) {
        if ($deny -contains $f.Name) { continue }
        $target = Join-Path $dst $f.FullName.Substring($srcFull.Length + 1)
        $key = $target.ToLowerInvariant()
        if ($claimed.Contains($key)) { continue }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
        $null = $claimed.Add($key)
        $n++
    }
    return $n
}

# Download all packages in parallel (4 at a time) into the cache.
function Get-PackageZips($packages) {
    $cache = Join-Path $Ctx.HomeDir 'cache'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $Ctx.Dl.Clear()
    $pool = [runspacefactory]::CreateRunspacePool(1, 4)
    $pool.Open()
    $jobs = @()
    foreach ($p in $packages) {
        $file = Join-Path $cache (($p.Url -replace '^https?://', '' -replace '[^A-Za-z0-9]+', '_') + '.zip')
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($DownloadBlock.ToString()).AddArgument($p.Url).AddArgument($file).AddArgument($Ctx.Dl).AddArgument($p.Name).AddArgument($true)
        $jobs += [pscustomobject]@{ Pkg = $p; File = $file; PS = $ps; Handle = $ps.BeginInvoke(); Status = '' }
    }
    $spin = '|/-\'; $i = 0
    while (@($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) {
        $doneCount = @($jobs | Where-Object { $_.Handle.IsCompleted }).Count
        $bytes = 0L
        foreach ($v in @($Ctx.Dl.Values)) { $bytes += [long]$v.Done }
        Set-Progress ([int](15 + 50 * $doneCount / [Math]::Max(1, $jobs.Count))) $null
        Set-Detail ((M 'ดาวน์โหลด ' 'Downloading ') + "$doneCount/$($jobs.Count)  " + (Format-Size $bytes) + '  ' + $spin[$i++ % 4])
        Start-Sleep -Milliseconds 250
    }
    Set-Detail $null
    foreach ($j in $jobs) {
        try {
            $out = $j.PS.EndInvoke($j.Handle)
            if ($j.PS.Streams.Error.Count -gt 0 -and -not (Test-Path -LiteralPath $j.File)) { $j.Status = 'error: ' + $j.PS.Streams.Error[0].ToString() }
            else { $j.Status = [string]($out | Select-Object -Last 1) }
        } catch {
            $msg = $_.Exception.Message
            if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
            $j.Status = if (Test-Path -LiteralPath $j.File) { 'cached-fallback' } else { 'error: ' + $msg }
        }
        $j.PS.Dispose()
    }
    $pool.Close()
    return $jobs
}

function Install-Effects($all, $urls) {
    $sel = @(@($all | Where-Object { $_.Required }) + @($all | Where-Object { -not $_.Required -and $urls -contains $_.Url }))
    Log 'info' ((M 'ชุด effect ที่เลือก: ' 'Selected packages: ') + $sel.Count)
    $jobs = Get-PackageZips $sel
    $stage = New-Stage
    $ok = 0
    try {
        if (Test-Path -LiteralPath $Ctx.ShadersDir) { Remove-Item -LiteralPath $Ctx.ShadersDir -Recurse -Force }
        $claimed = New-Object 'System.Collections.Generic.HashSet[string]'
        $n = 0
        foreach ($j in $jobs) {
            $n++
            $p = $j.Pkg
            Set-Progress ([int](65 + 20 * $n / [Math]::Max(1, $jobs.Count))) $null
            if ($j.Status -like 'error*') { Log 'warn' ("$($p.Name): $($j.Status)"); continue }
            try {
                $x = Join-Path $stage ("p$n")
                Expand-Archive -LiteralPath $j.File -DestinationPath $x -Force
                $shaderSrc = Get-TopDir $x 'Shaders'
                if (-not $shaderSrc) {
                    $fx = Get-ChildItem -LiteralPath $x -File -Recurse -Include '*.fx', '*.fxh' | Sort-Object { $_.FullName.Split('\').Count } | Select-Object -First 1
                    if ($fx) { $shaderSrc = Get-Item -LiteralPath $fx.DirectoryName }
                }
                $texSrc = Get-TopDir $x 'Textures'
                $files = 0
                if ($shaderSrc) { $files += Copy-Tree $shaderSrc.FullName (Resolve-PluginPath $p.InstallPath) $claimed $p.Deny }
                if ($texSrc -and $p.TexturePath) { $files += Copy-Tree $texSrc.FullName (Resolve-PluginPath $p.TexturePath) $claimed @() }
                Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue
                $tag = if ($j.Status -eq 'cached') { (M ' (จาก cache)' ' (cached)') } else { '' }
                Log 'ok' ("$($p.Name)  $files " + (M 'ไฟล์' 'files') + $tag)
                $ok++
            } catch { Log 'warn' ("$($p.Name): " + $_.Exception.Message) }
        }
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }

    # Keep effects that were turned off by "clean up broken effects" turned off.
    $re = 0
    foreach ($rel in @($Ctx.State.DisabledFx)) {
        $src = Join-Path $Ctx.ShadersDir $rel
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $Ctx.Disabled $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Move-Item -LiteralPath $src -Destination $dst -Force
            $re++
        }
    }
    if ($re) { Log 'info' ((M 'ปิด effect ที่พังไว้เหมือนเดิม ' 'Kept broken effects off: ') + $re) }
    $Ctx.State.Packages = @($sel | ForEach-Object { $_.Url })
    Log 'ok' ((M 'ติดตั้งชุด effect สำเร็จ ' 'Effect packages installed: ') + "$ok/$($sel.Count)" + '  (' + (Format-Size (Get-DirSize $Ctx.ShadersDir)) + ')')
}

# Effects that failed to compile, read from ReShade.log.
function Get-BrokenEffects {
    $text = Read-SharedText $Ctx.ReShadeLog
    if (-not $text) { return @() }
    $set = @{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -notmatch '(?i)error|failed') { continue }
        if ($line -notmatch '(?i)compil|load') { continue }
        foreach ($m in [regex]::Matches($line, "['""\[]([^'""\[\]]+?\.fx)['""\]]")) { $set[$m.Groups[1].Value] = $true }
    }
    return @($set.Keys)
}

function Invoke-Cleanup {
    $Ctx.StepNo = 0; $Ctx.StepTotal = 2
    Step (M 'อ่าน ReShade.log' 'Read ReShade.log')
    if (-not (Test-Path -LiteralPath $Ctx.ReShadeLog)) { Log 'warn' (M 'ยังไม่มี ReShade.log เข้าเกม 1 ครั้งก่อน' 'No ReShade.log yet. Start the game once first.'); return 0 }
    $broken = @(Get-BrokenEffects)
    Log 'info' ((M 'effect ที่ compile ไม่ผ่าน: ' 'Effects that failed to compile: ') + $broken.Count)
    Step (M 'ปิด effect ที่พัง' 'Turn off broken effects')
    $moved = 0
    $root = [IO.Path]::GetFullPath($Ctx.ShadersDir).TrimEnd('\') + '\'
    $targets = @()
    foreach ($path in $broken) {
        $full = $null
        if ([IO.Path]::IsPathRooted($path)) { try { $full = [IO.Path]::GetFullPath($path) } catch {} }
        if ($full -and (Test-Path -LiteralPath $full)) { $targets += $full; continue }
        # The log or overlay may only give the file name: find it in the effect folders.
        $name = [IO.Path]::GetFileName($path)
        $targets += @(Get-ChildItem -LiteralPath $Ctx.ShadersDir -Filter $name -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    foreach ($full in ($targets | Select-Object -Unique)) {
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $rel = $full.Substring($root.Length)
        $dst = Join-Path $Ctx.Disabled $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
        Move-Item -LiteralPath $full -Destination $dst -Force
        if (@($Ctx.State.DisabledFx) -notcontains $rel) { $Ctx.State.DisabledFx = @($Ctx.State.DisabledFx) + $rel }
        Log 'ok' $rel
        $moved++
    }
    Save-State
    Log 'ok' ((M 'ปิด effect แล้ว ' 'Turned off ') + $moved + (M ' ไฟล์ (คืนได้ที่ "คืน effect ที่ปิด")' ' files (undo with "Restore turned-off effects")'))
    Set-Progress 100 $null
    return $moved
}

function Invoke-RestoreDisabled {
    $n = 0
    if (Test-Path -LiteralPath $Ctx.Disabled) {
        $root = [IO.Path]::GetFullPath($Ctx.Disabled).TrimEnd('\') + '\'
        foreach ($f in Get-ChildItem -LiteralPath $Ctx.Disabled -File -Recurse) {
            $rel = $f.FullName.Substring($root.Length)
            $dst = Join-Path $Ctx.ShadersDir $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Move-Item -LiteralPath $f.FullName -Destination $dst -Force
            $n++
        }
        Remove-Item -LiteralPath $Ctx.Disabled -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Ctx.State.DisabledFx = @()
    Save-State
    Log 'ok' ((M 'คืน effect แล้ว ' 'Restored effects: ') + $n)
    return $n
}

# ---------------------------------------------------------------------------
#  Settings, hotkeys, presets
# ---------------------------------------------------------------------------
function Set-ReShadeSettings {
    New-Item -ItemType Directory -Path $Ctx.Plugins -Force | Out-Null
    Set-IniValue $Ctx.ReShadeIni 'GENERAL' 'EffectSearchPaths'  "$($Ctx.ShadersDir)\**"
    Set-IniValue $Ctx.ReShadeIni 'GENERAL' 'TextureSearchPaths' "$($Ctx.ShadersDir)\Textures\**"
    Set-IniValue $Ctx.ReShadeIni 'GENERAL' 'PerformanceMode' $(if ($Ctx.State.PerformanceMode) { '1' } else { '0' })
    Set-IniValue $Ctx.ReShadeIni 'OVERLAY' 'TutorialProgress' '4'
    New-Item -ItemType Directory -Path $Ctx.ShotDir -Force | Out-Null
    Set-IniValue $Ctx.ReShadeIni 'SCREENSHOT' 'SavePath' $Ctx.ShotDir
    Log 'ok' (M 'ตั้ง path effect, ข้าม tutorial, ที่เก็บ screenshot' 'Effect paths, tutorial skipped, screenshot folder set')
    if ($Ctx.State.PerformanceMode) { Log 'ok' (M 'Performance Mode: เปิด' 'Performance Mode: on') }
}

function Get-Hotkeys {
    $r = @{}
    foreach ($k in 'KeyOverlay', 'KeyEffects', 'KeyScreenshot') {
        $v = Get-IniValue $Ctx.ReShadeIni 'INPUT' $k
        $r[$k] = if ($v -match '^(\d+)') { [int]$Matches[1] } else { -1 }
    }
    return $r
}

function Set-Hotkeys([int]$overlay, [int]$effects, [int]$shot) {
    New-Item -ItemType Directory -Path $Ctx.Plugins -Force | Out-Null
    Set-IniValue $Ctx.ReShadeIni 'INPUT' 'KeyOverlay' "$overlay,0,0,0"
    Set-IniValue $Ctx.ReShadeIni 'INPUT' 'KeyEffects' "$effects,0,0,0"
    Set-IniValue $Ctx.ReShadeIni 'INPUT' 'KeyScreenshot' "$shot,0,0,0"
}

function Get-Presets {
    $list = @()
    $default = Join-Path $Ctx.Plugins 'ReShadePreset.ini'
    if (Test-Path -LiteralPath $default) { $list += $default }
    if (Test-Path -LiteralPath $Ctx.PresetDir) { $list += @(Get-ChildItem -LiteralPath $Ctx.PresetDir -Filter '*.ini' | ForEach-Object { $_.FullName }) }
    return $list
}

function Get-ActivePreset {
    $p = Get-IniValue $Ctx.ReShadeIni 'GENERAL' 'PresetPath'
    if (-not $p) { return $null }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Ctx.Plugins ($p -replace '^\.[\\/]', '') }
    try { return [IO.Path]::GetFullPath($p) } catch { return $p }
}

function Add-Preset([string]$source) {
    New-Item -ItemType Directory -Path $Ctx.PresetDir -Force | Out-Null
    if ($source -match '^https?://') {
        $name = [IO.Path]::GetFileName(([Uri]$source).AbsolutePath)
        if ($name -notmatch '\.ini$') { $name = 'preset-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.ini' }
        $dst = Join-Path $Ctx.PresetDir $name
        $null = Get-Download $source $dst
    } else {
        $dst = Join-Path $Ctx.PresetDir ([IO.Path]::GetFileName($source))
        if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($dst)) { Copy-Item -LiteralPath $source -Destination $dst -Force }
    }
    Set-ActivePreset $dst
    Log 'ok' ((M 'เพิ่ม preset: ' 'Preset added: ') + [IO.Path]::GetFileName($dst))
    return $dst
}

function Set-ActivePreset([string]$path) {
    New-Item -ItemType Directory -Path $Ctx.Plugins -Force | Out-Null
    Set-IniValue $Ctx.ReShadeIni 'GENERAL' 'PresetPath' $path
}

# ---------------------------------------------------------------------------
#  Backup / restore
# ---------------------------------------------------------------------------
function Backup-Configs {
    $dst = Join-Path $Ctx.BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    $any = $false
    foreach ($f in @($Ctx.CitizenIni, $Ctx.ReShadeIni, (Join-Path $Ctx.Plugins 'ReShadePreset.ini'))) {
        if (Test-Path -LiteralPath $f) { New-Item -ItemType Directory -Path $dst -Force | Out-Null; Copy-Item -LiteralPath $f -Destination $dst -Force; $any = $true }
    }
    if (Test-Path -LiteralPath $Ctx.PresetDir) {
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -LiteralPath $Ctx.PresetDir -Destination $dst -Recurse -Force
        $any = $true
    }
    if (Test-Path -LiteralPath $Ctx.BackupRoot) {
        Get-ChildItem -LiteralPath $Ctx.BackupRoot -Directory | Sort-Object Name -Descending | Select-Object -Skip 10 |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($any) { Log 'ok' ((M 'สำรองไฟล์แล้ว: ' 'Backup saved: ') + (Split-Path -Leaf $dst)) }
    else { Log 'ok' (M 'ยังไม่มีไฟล์ตั้งค่าให้สำรอง' 'No config files to back up yet') }
}

function Get-Backups {
    if (-not (Test-Path -LiteralPath $Ctx.BackupRoot)) { return @() }
    @(Get-ChildItem -LiteralPath $Ctx.BackupRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
        $d = $null
        try { $d = [datetime]::ParseExact($_.Name, 'yyyyMMdd-HHmmss', $null) } catch {}
        $files = @(Get-ChildItem -LiteralPath $_.FullName -File | ForEach-Object { $_.Name })
        if (Test-Path -LiteralPath (Join-Path $_.FullName 'presets')) { $files += 'presets\' }
        [pscustomobject]@{
            Name  = $_.Name
            Path  = $_.FullName
            Label = $(if ($d) { $d.ToString('yyyy-MM-dd HH:mm:ss') } else { $_.Name }) + '   ' + ($files -join ', ')
        }
    })
}

function Invoke-Restore([string]$backupPath) {
    $Ctx.StepNo = 0; $Ctx.StepTotal = 3
    Step (M 'ตรวจ FiveM' 'Check FiveM'); Close-FiveM
    Step (M 'สำรองไฟล์ปัจจุบันก่อน' 'Back up current files first'); Backup-Configs
    Step ((M 'กู้คืน ' 'Restore ') + (Split-Path -Leaf $backupPath))
    $map = @{ 'CitizenFX.ini' = $Ctx.FiveMApp; 'ReShade.ini' = $Ctx.Plugins; 'ReShadePreset.ini' = $Ctx.Plugins }
    foreach ($name in $map.Keys) {
        $src = Join-Path $backupPath $name
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $map[$name] -Force; Log 'ok' $name }
    }
    $pre = Join-Path $backupPath 'presets'
    if (Test-Path -LiteralPath $pre) {
        New-Item -ItemType Directory -Path $Ctx.PresetDir -Force | Out-Null
        Copy-Item -Path (Join-Path $pre '*') -Destination $Ctx.PresetDir -Recurse -Force
        Log 'ok' 'presets\'
    }
    Set-Progress 100 $null
}

# ---------------------------------------------------------------------------
#  Shortcut, icon, weekly update check
# ---------------------------------------------------------------------------
function New-AppIcon([string]$path) {
    Add-Type -AssemblyName System.Drawing
    $pngs = @()
    foreach ($size in 256, 48, 32) {
        $bmp = New-Object Drawing.Bitmap $size, $size
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
        $rect = New-Object Drawing.Rectangle 0, 0, ($size - 1), ($size - 1)
        $brush = New-Object Drawing.Drawing2D.LinearGradientBrush $rect, ([Drawing.Color]::FromArgb(124, 77, 255)), ([Drawing.Color]::FromArgb(0, 176, 255)), ([float]45)
        $g.FillEllipse($brush, $rect)
        $font = New-Object Drawing.Font 'Segoe UI', ([float]($size * 0.5)), ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString('R', $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, ([float]($size * 0.02)), $size, $size), $sf)
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $pngs += , @($size, $ms.ToArray())
    }
    # ICO file with PNG images (Windows Vista and newer read these).
    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $out
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$pngs.Count)
    $offset = 6 + 16 * $pngs.Count
    foreach ($p in $pngs) {
        $s = $p[0]; $b = $p[1]
        $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
        $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$b.Length); $w.Write([uint32]$offset)
        $offset += $b.Length
    }
    foreach ($p in $pngs) { $w.Write([byte[]]$p[1]) }
    $w.Flush()
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllBytes($path, $out.ToArray())
    return $path
}

# Copy this program to a fixed place so the shortcut and the weekly check keep working.
function Install-LocalCopy {
    New-Item -ItemType Directory -Path $Ctx.HomeDir -Force | Out-Null
    if ($Ctx.IsExe) {
        $dst = Join-Path $Ctx.HomeDir 'ReShade FiveM.exe'
        if ([IO.Path]::GetFullPath($Ctx.SelfProcess) -ne [IO.Path]::GetFullPath($dst)) { Copy-Item -LiteralPath $Ctx.SelfProcess -Destination $dst -Force }
        return $dst
    }
    $dst = Join-Path $Ctx.HomeDir 'install-reshade.ps1'
    if ($Ctx.SelfScript -and (Test-Path -LiteralPath $Ctx.SelfScript)) {
        if ([IO.Path]::GetFullPath($Ctx.SelfScript) -ne [IO.Path]::GetFullPath($dst)) { Copy-Item -LiteralPath $Ctx.SelfScript -Destination $dst -Force }
    } elseif ($Ctx.SelfUrl) {
        $null = Get-Download $Ctx.SelfUrl $dst
    }
    if (Test-Path -LiteralPath $dst) { return $dst } else { return $null }
}

function Get-LaunchCommand([string]$local, [string]$extraArgs) {
    if ($Ctx.IsExe) { return @{ File = $local; Args = $extraArgs } }
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return @{ File = $ps; Args = ("-NoProfile -ExecutionPolicy Bypass -File `"$local`" " + $extraArgs).Trim() }
}

function Install-Shortcut {
    $local = Install-LocalCopy
    if (-not $local) { Log 'warn' (M 'ข้าม shortcut (ไม่มีไฟล์โปรแกรมในเครื่อง)' 'Shortcut skipped (no local copy)'); return }
    $icon = New-AppIcon (Join-Path $Ctx.HomeDir 'icon.ico')
    $cmd = Get-LaunchCommand $local ''
    if (-not $Ctx.IsExe) { $cmd.Args = '-WindowStyle Hidden ' + $cmd.Args }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ReShade FiveM.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $cmd.File
    $sc.Arguments = $cmd.Args
    $sc.WorkingDirectory = $Ctx.HomeDir
    $sc.IconLocation = "$icon,0"
    $sc.WindowStyle = 7   # minimized console; the app window opens normally
    $sc.Description = 'ReShade for FiveM'
    $sc.Save()
    Log 'ok' (M 'shortcut "ReShade FiveM" บน Desktop' 'Desktop shortcut "ReShade FiveM"')
}

function Set-UpdateTask([bool]$on) {
    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $on) {
            if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
            Log 'ok' (M 'เช็กอัปเดตรายสัปดาห์: ปิด' 'Weekly update check: off')
            return
        }
        $local = Install-LocalCopy
        if (-not $local) { Log 'warn' (M 'ตั้งเช็กอัปเดตไม่ได้ (ไม่มีไฟล์โปรแกรมในเครื่อง)' 'Cannot set update check (no local copy)'); return }
        $cmd = Get-LaunchCommand $local '-Action check -NoGui'
        if (-not $Ctx.IsExe) { $cmd.Args = '-WindowStyle Hidden ' + $cmd.Args }
        $act = New-ScheduledTaskAction -Execute $cmd.File -Argument $cmd.Args
        $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '12:00'
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Description 'Checks reshade.me for a new ReShade version for FiveM.' -Force | Out-Null
        Log 'ok' (M 'เช็กอัปเดตรายสัปดาห์: เปิด (วันอาทิตย์ 12:00)' 'Weekly update check: on (Sunday 12:00)')
    } catch { Log 'warn' ((M 'ตั้งเช็กอัปเดตไม่ได้: ' 'Could not set update check: ') + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
#  Status
# ---------------------------------------------------------------------------
function Get-Status {
    $fx = 0
    if (Test-Path -LiteralPath $Ctx.ShadersDir) { $fx = @(Get-ChildItem -LiteralPath $Ctx.ShadersDir -Filter '*.fx' -File -Recurse -ErrorAction SilentlyContinue).Count }
    $preset = Get-ActivePreset
    [pscustomobject]@{
        Installed   = Get-InstalledReShade
        Ack         = [bool](Test-ReShadeAck)
        Effects     = $fx
        ShadersSize = Get-DirSize $Ctx.ShadersDir
        Packages    = @($Ctx.State.Packages).Count
        Preset      = $(if ($preset) { [IO.Path]::GetFileName($preset) } else { $null })
        Disabled    = @($Ctx.State.DisabledFx).Count
        FiveMFound  = (Test-Path -LiteralPath $Ctx.FiveMApp)
    }
}

# ---------------------------------------------------------------------------
#  Main operations
# ---------------------------------------------------------------------------
# $o: Addon, Force, PackageUrls ($null = keep saved), Preset, EffectsOnly
function Invoke-Install($o) {
    $Ctx.StepNo = 0
    $Ctx.StepTotal = if ($o.EffectsOnly) { 5 } else { 8 }
    $stage = New-Stage
    try {
        Step (M 'ตรวจ FiveM' 'Check FiveM'); Close-FiveM
        New-Item -ItemType Directory -Path $Ctx.Plugins -Force | Out-Null

        Step (M 'สำรองไฟล์ตั้งค่า' 'Back up config files'); Backup-Configs

        if (-not $o.EffectsOnly) {
            Step (M 'ตรวจเวอร์ชัน ReShade' 'Check ReShade version')
            $installed = Get-InstalledReShade
            $latest = Get-LatestReShade ([bool]$o.Addon)
            if (-not $latest.Online) { Log 'warn' ((M 'อ่าน reshade.me ไม่ได้ ใช้เวอร์ชันสำรอง ' 'Could not read reshade.me, using fallback ') + $latest.Version) }
            Log 'info' ((M 'ล่าสุด: ' 'Latest: ') + $latest.Version + '    ' + (M 'ในเครื่อง: ' 'Installed: ') + $(if ($installed) { $installed } else { '-' }))
            $need = $o.Force -or (-not $installed) -or ($installed -eq 'unknown') -or
                    ([bool]$Ctx.State.Addon -ne [bool]$o.Addon) -or ([version]$installed -lt [version]$latest.Version)
            if ($need) { Log 'ok' (M 'ต้องติดตั้ง / อัปเดต' 'Install / update needed') } else { Log 'ok' (M 'เป็นเวอร์ชันล่าสุดแล้ว' 'Already up to date') }

            Step (M 'ติดตั้ง ReShade' 'Install ReShade')
            if ($need) { Install-ReShadeDll $latest $stage } else { Log 'ok' (M 'ข้าม (ล่าสุดแล้ว)' 'Skipped (up to date)') }
            $Ctx.State.Version = $latest.Version
            $Ctx.State.Addon = [bool]$o.Addon
        }

        Step (M 'ติดตั้งชุด effect' 'Install effect packages')
        $all = @(Get-PackageList)
        $haveShaders = Test-Path -LiteralPath (Join-Path $Ctx.ShadersDir 'Shaders')
        if ($null -ne $o.PackageUrls) { Install-Effects $all @($o.PackageUrls) }
        elseif (@($Ctx.State.Packages).Count -and $haveShaders) { Log 'ok' ((M 'ใช้ชุด effect เดิม ' 'Keeping current packages: ') + @($Ctx.State.Packages).Count) }
        elseif (@($Ctx.State.Packages).Count) { Install-Effects $all @($Ctx.State.Packages) }
        else { Install-Effects $all @($all | Where-Object { $_.Recommended } | ForEach-Object { $_.Url }) }
        Save-State

        Step (M 'ตั้งค่า ReShade.ini' 'Configure ReShade.ini')
        Set-ReShadeSettings
        if ($o.Preset) { $null = Add-Preset $o.Preset }

        Step (M 'ยืนยัน ReShade กับ FiveM' 'Confirm ReShade with FiveM'); Confirm-Ack

        if (-not $o.EffectsOnly) {
            Step (M 'shortcut และเช็กอัปเดต' 'Shortcut and update check')
            if ($Ctx.State.Shortcut) { try { Install-Shortcut } catch { Log 'warn' $_.Exception.Message } }
            Set-UpdateTask ([bool]$Ctx.State.WeeklyCheck)
        }
        Save-State
        Set-Progress 100 (M 'เสร็จแล้ว' 'Done')
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-Repair {
    $Ctx.StepNo = 0; $Ctx.StepTotal = 6
    $stage = New-Stage
    $fixed = 0
    try {
        Step (M 'ตรวจ FiveM' 'Check FiveM'); Close-FiveM
        New-Item -ItemType Directory -Path $Ctx.Plugins -Force | Out-Null
        Step (M 'สำรองไฟล์ตั้งค่า' 'Back up config files'); Backup-Configs

        Step (M 'ตรวจ dxgi.dll' 'Check dxgi.dll')
        $installed = Get-InstalledReShade
        if (-not $installed -or $installed -eq 'unknown') {
            Log 'warn' (M 'dxgi.dll หายหรือไม่ใช่ ReShade ติดตั้งใหม่' 'dxgi.dll missing or not ReShade, reinstalling')
            $latest = Get-LatestReShade ([bool]$Ctx.State.Addon)
            Install-ReShadeDll $latest $stage
            $Ctx.State.Version = $latest.Version
            $fixed++
        } else { Log 'ok' "ReShade $installed" }

        Step (M 'ตรวจ effect' 'Check effects')
        $fxCount = 0
        if (Test-Path -LiteralPath $Ctx.ShadersDir) { $fxCount = @(Get-ChildItem -LiteralPath $Ctx.ShadersDir -Filter '*.fx' -File -Recurse -ErrorAction SilentlyContinue).Count }
        if ($fxCount -eq 0) {
            Log 'warn' (M 'ไม่มี effect ติดตั้งใหม่' 'No effects found, reinstalling')
            $all = @(Get-PackageList)
            $urls = if (@($Ctx.State.Packages).Count) { @($Ctx.State.Packages) } else { @($all | Where-Object { $_.Recommended } | ForEach-Object { $_.Url }) }
            Install-Effects $all $urls
            $fixed++
        } else { Log 'ok' ("$fxCount effect") }

        Step (M 'ตรวจ ReShade.ini' 'Check ReShade.ini')
        $want = "$($Ctx.ShadersDir)\**"
        if ((Get-IniValue $Ctx.ReShadeIni 'GENERAL' 'EffectSearchPaths') -ne $want) { $fixed++; Log 'warn' (M 'path effect ไม่ถูกต้อง แก้แล้ว' 'Effect path was wrong, fixed') }
        Set-ReShadeSettings

        Step (M 'ตรวจ CitizenFX.ini' 'Check CitizenFX.ini')
        if (-not (Test-ReShadeAck)) { $fixed++ }
        Confirm-Ack

        # Turn off effects that failed to compile last time (red entries in the ReShade menu).
        if (Test-Path -LiteralPath $Ctx.ReShadeLog) {
            $step = $Ctx.StepNo; $total = $Ctx.StepTotal
            $moved = Invoke-Cleanup
            $Ctx.StepNo = $step; $Ctx.StepTotal = $total
            $fixed += $moved
        }
        Save-State
        Set-Progress 100 (M 'เสร็จแล้ว' 'Done')
        Log 'ok' ((M 'ซ่อมเสร็จ แก้ไป ' 'Repair done, fixed ') + $fixed + (M ' จุด' ' items'))
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-Uninstall {
    $Ctx.StepNo = 0; $Ctx.StepTotal = 3
    Step (M 'ตรวจ FiveM' 'Check FiveM'); Close-FiveM
    Step (M 'สำรองไฟล์ตั้งค่า' 'Back up config files'); Backup-Configs
    Step (M 'ลบ ReShade' 'Remove ReShade')
    foreach ($f in 'dxgi.dll', 'ReShade.ini', 'ReShadePreset.ini', 'ReShade.log', 'ReShade.log1') {
        Remove-Item -LiteralPath (Join-Path $Ctx.Plugins $f) -Force -ErrorAction SilentlyContinue
    }
    foreach ($d in $Ctx.ShadersDir, $Ctx.Disabled, $Ctx.PresetDir) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $Ctx.CitizenIni) {
        Write-Lines $Ctx.CitizenIni @((Read-Lines $Ctx.CitizenIni) | Where-Object { $_ -notmatch '^\s*ReShade\d*\s*=\s*ID:' })
    }
    Set-UpdateTask $false
    $Ctx.State.Packages = @(); $Ctx.State.DisabledFx = @(); $Ctx.State.Version = ''
    Save-State
    Set-Progress 100 (M 'เสร็จแล้ว' 'Done')
    Log 'ok' (M 'ลบ ReShade ออกจาก FiveM แล้ว (ไฟล์สำรองยังอยู่)' 'ReShade removed from FiveM (backups kept)')
}

# Used by the weekly scheduled task: notify when a newer ReShade is out.
function Invoke-Check {
    $installed = Get-InstalledReShade
    if (-not $installed -or $installed -eq 'unknown') { return }
    $latest = Get-LatestReShade ([bool]$Ctx.State.Addon)
    if ($latest.Online -and [version]$latest.Version -gt [version]$installed) {
        Show-Toast 'ReShade for FiveM' (M "ReShade $($latest.Version) ออกแล้ว (ในเครื่อง $installed) เปิด ReShade FiveM เพื่ออัปเดต" "ReShade $($latest.Version) is out (you have $installed). Open ReShade FiveM to update.")
    }
}

}   # end of $Core

# ============================================================================
#  WINDOW (WinForms)
# ============================================================================
function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $Sync = [hashtable]::Synchronized(@{
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Pct = 0; Status = ''; Detail = ''; Done = $true; Result = $null; Error = $null
    })
    $Ctx.Sync = $Sync

    $Clr = @{
        Bg      = [Drawing.Color]::FromArgb(23, 24, 29)
        Side    = [Drawing.Color]::FromArgb(30, 32, 39)
        Card    = [Drawing.Color]::FromArgb(39, 42, 52)
        CardHi  = [Drawing.Color]::FromArgb(52, 56, 70)
        Text    = [Drawing.Color]::FromArgb(236, 238, 245)
        Dim     = [Drawing.Color]::FromArgb(150, 156, 175)
        Accent  = [Drawing.Color]::FromArgb(92, 124, 255)
        AccentD = [Drawing.Color]::FromArgb(58, 70, 140)
        Green   = [Drawing.Color]::FromArgb(70, 205, 130)
        Amber   = [Drawing.Color]::FromArgb(255, 190, 70)
        Red     = [Drawing.Color]::FromArgb(240, 90, 90)
        Danger  = [Drawing.Color]::FromArgb(170, 50, 60)
        LogBg   = [Drawing.Color]::FromArgb(17, 18, 22)
    }
    $fontName = 'Leelawadee UI'
    $Fnt = @{
        Normal = New-Object Drawing.Font $fontName, 10
        Small  = New-Object Drawing.Font $fontName, 8.5
        Bold   = New-Object Drawing.Font $fontName, 10, ([Drawing.FontStyle]::Bold)
        Big    = New-Object Drawing.Font $fontName, 18, ([Drawing.FontStyle]::Bold)
        Title  = New-Object Drawing.Font $fontName, 17, ([Drawing.FontStyle]::Bold)
        Head   = New-Object Drawing.Font $fontName, 13, ([Drawing.FontStyle]::Bold)
        Log    = New-Object Drawing.Font $fontName, 9
    }
    $ui = @{ Busy = $false; ActionButtons = New-Object System.Collections.ArrayList; Pages = @{}; Nav = @{}
             Packages = @(); Checked = @{}; Filling = $false; Latest = $null; LastBytes = 0L; LastTick = [DateTime]::Now; Speed = 0.0 }

    # ---------- small builders ----------
    function L($parent, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $font, $color) {
        $l = New-Object Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object Drawing.Point $x, $y; $l.Size = New-Object Drawing.Size $w, $h
        $l.Font = $(if ($font) { $font } else { $Fnt.Normal }); $l.ForeColor = $(if ($color) { $color } else { $Clr.Text })
        $l.BackColor = [Drawing.Color]::Transparent
        $parent.Controls.Add($l); return $l
    }
    function B($parent, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [string]$style, [scriptblock]$click, [bool]$isAction = $true) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $text; $b.Location = New-Object Drawing.Point $x, $y; $b.Size = New-Object Drawing.Size $w, $h
        $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = 'Hand'
        $b.Font = $(if ($style -eq 'accent') { $Fnt.Bold } else { $Fnt.Normal }); $b.ForeColor = $Clr.Text
        switch ($style) {
            'accent' { $b.BackColor = $Clr.Accent; $b.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(118, 146, 255) }
            'danger' { $b.BackColor = $Clr.Danger; $b.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(200, 60, 72) }
            default  { $b.BackColor = $Clr.Card;   $b.FlatAppearance.MouseOverBackColor = $Clr.CardHi }
        }
        if ($click) { $b.Add_Click($click) }
        $parent.Controls.Add($b)
        if ($isAction) { [void]$ui.ActionButtons.Add($b) }
        return $b
    }
    function CB($parent, [string]$text, [int]$x, [int]$y, [int]$w, [bool]$checked) {
        $c = New-Object Windows.Forms.CheckBox
        $c.Text = $text; $c.Location = New-Object Drawing.Point $x, $y; $c.Size = New-Object Drawing.Size $w, 26
        $c.Checked = $checked; $c.ForeColor = $Clr.Text; $c.Font = $Fnt.Normal; $c.FlatStyle = 'Flat'; $c.Cursor = 'Hand'
        $parent.Controls.Add($c); return $c
    }
    function Card($parent, [int]$x, [int]$y, [int]$w, [int]$h) {
        $p = New-Object Windows.Forms.Panel
        $p.Location = New-Object Drawing.Point $x, $y; $p.Size = New-Object Drawing.Size $w, $h; $p.BackColor = $Clr.Card
        $parent.Controls.Add($p); return $p
    }
    function New-Page([string]$name, [string]$title) {
        $p = New-Object Windows.Forms.Panel
        $p.Dock = 'Fill'; $p.BackColor = $Clr.Bg; $p.Visible = $false
        $null = L $p $title 24 14 600 32 $Fnt.Head $Clr.Text
        $content.Controls.Add($p); $ui.Pages[$name] = $p
        return $p
    }
    function Get-IconBitmap([int]$size) {
        $bmp = New-Object Drawing.Bitmap $size, $size
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
        $rect = New-Object Drawing.Rectangle 0, 0, ($size - 1), ($size - 1)
        $br = New-Object Drawing.Drawing2D.LinearGradientBrush $rect, ([Drawing.Color]::FromArgb(124, 77, 255)), ([Drawing.Color]::FromArgb(0, 176, 255)), ([float]45)
        $g.FillEllipse($br, $rect)
        $iconFont = New-Object Drawing.Font 'Segoe UI', ([float]($size * 0.5)), ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString('R', $iconFont, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, ([float]($size * 0.02)), $size, $size), $sf)
        $g.Dispose()
        return $bmp
    }

    # ---------- form ----------
    $form = New-Object Windows.Forms.Form
    $form.Text = "ReShade for FiveM  v$ScriptVersion"
    $form.ClientSize = New-Object Drawing.Size 1000, 690
    $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
    $form.BackColor = $Clr.Bg; $form.ForeColor = $Clr.Text; $form.Font = $Fnt.Normal
    try { $form.Icon = [Drawing.Icon]::FromHandle((Get-IconBitmap 64).GetHicon()) } catch {}

    $content = New-Object Windows.Forms.Panel; $content.Dock = 'Fill'; $content.BackColor = $Clr.Bg
    $side = New-Object Windows.Forms.Panel; $side.Dock = 'Left'; $side.Width = 190; $side.BackColor = $Clr.Side
    $bottom = New-Object Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 196; $bottom.BackColor = $Clr.Side
    $header = New-Object Windows.Forms.Panel; $header.Dock = 'Top'; $header.Height = 74
    $form.Controls.AddRange(@($content, $side, $bottom, $header))

    # Header: gradient background image, icon, title, version line.
    $hb = New-Object Drawing.Bitmap 1000, 74
    $hg = [Drawing.Graphics]::FromImage($hb)
    $hbr = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.Rectangle 0, 0, 1000, 74), ([Drawing.Color]::FromArgb(70, 40, 160)), ([Drawing.Color]::FromArgb(0, 120, 200)), ([float]0)
    $hg.FillRectangle($hbr, 0, 0, 1000, 74); $hg.Dispose()
    $header.BackgroundImage = $hb
    $pic = New-Object Windows.Forms.PictureBox
    $pic.Image = Get-IconBitmap 46; $pic.Location = New-Object Drawing.Point 18, 14; $pic.Size = New-Object Drawing.Size 46, 46; $pic.BackColor = [Drawing.Color]::Transparent
    $header.Controls.Add($pic)
    $null = L $header 'ReShade for FiveM' 76 10 400 34 $Fnt.Title $Clr.Text
    $ui.HeadSub = L $header '' 78 44 880 22 $Fnt.Small ([Drawing.Color]::FromArgb(220, 225, 255))

    # Bottom: progress bar, status, log.
    $barBg = New-Object Windows.Forms.Panel; $barBg.Location = New-Object Drawing.Point 16, 12; $barBg.Size = New-Object Drawing.Size 968, 8; $barBg.BackColor = $Clr.Card
    $bar = New-Object Windows.Forms.Panel; $bar.Location = New-Object Drawing.Point 0, 0; $bar.Size = New-Object Drawing.Size 0, 8; $bar.BackColor = $Clr.Accent
    $barBg.Controls.Add($bar); $bottom.Controls.Add($barBg)
    $ui.Bar = $bar; $ui.BarBg = $barBg
    $ui.Status = L $bottom (M 'พร้อม' 'Ready') 16 26 560 22 $Fnt.Bold $Clr.Text
    $ui.Detail = L $bottom '' 580 26 404 22 $Fnt.Small $Clr.Dim
    $ui.Detail.TextAlign = 'MiddleRight'
    $rtb = New-Object Windows.Forms.RichTextBox
    $rtb.Location = New-Object Drawing.Point 16, 52; $rtb.Size = New-Object Drawing.Size 968, 132
    $rtb.ReadOnly = $true; $rtb.BorderStyle = 'None'; $rtb.BackColor = $Clr.LogBg; $rtb.ForeColor = $Clr.Dim; $rtb.Font = $Fnt.Log
    $rtb.DetectUrls = $false
    $bottom.Controls.Add($rtb); $ui.Log = $rtb

    function Add-LogLine([string]$level, [string]$text) {
        $map = @{
            step = @($Clr.Accent, ([string][char]0x25B6 + ' '))
            ok   = @($Clr.Green, ('   ' + [string][char]0x2714 + ' '))
            warn = @($Clr.Amber, ('   ' + [string][char]0x26A0 + ' '))
            err  = @($Clr.Red, ('   ' + [string][char]0x2716 + ' '))
            info = @($Clr.Dim, '     ')
        }
        $m = $map[$level]; if (-not $m) { $m = $map.info }
        $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
        $rtb.SelectionColor = $m[0]
        $rtb.SelectionFont = $(if ($level -eq 'step') { $Fnt.Bold } else { $Fnt.Log })
        $rtb.AppendText($m[1] + $text + "`n")
        $rtb.SelectionStart = $rtb.TextLength; $rtb.ScrollToCaret()
    }

    # Sidebar navigation.
    $navItems = @(
        @('home',    (M 'หน้าหลัก' 'Home')),
        @('effects', (M 'ชุด effect' 'Effects')),
        @('presets', 'Presets'),
        @('keys',    (M 'ปุ่มลัด' 'Hotkeys')),
        @('backup',  (M 'สำรอง / กู้คืน' 'Backup / restore')),
        @('tools',   (M 'เครื่องมือ / ตั้งค่า' 'Tools / settings'))
    )
    $ny = 16
    foreach ($n in $navItems) {
        $nb = New-Object Windows.Forms.Button
        $nb.Text = '   ' + $n[1]; $nb.Tag = $n[0]; $nb.TextAlign = 'MiddleLeft'
        $nb.Location = New-Object Drawing.Point 0, $ny; $nb.Size = New-Object Drawing.Size 190, 44
        $nb.FlatStyle = 'Flat'; $nb.FlatAppearance.BorderSize = 0; $nb.FlatAppearance.MouseOverBackColor = $Clr.Card
        $nb.Font = $Fnt.Normal; $nb.ForeColor = $Clr.Dim; $nb.BackColor = $Clr.Side; $nb.Cursor = 'Hand'
        $nb.Add_Click({ Show-Page $this.Tag })
        $side.Controls.Add($nb); $ui.Nav[$n[0]] = $nb
        $ny += 46
    }

    function Show-Page([string]$name) {
        foreach ($k in $ui.Pages.Keys) { $ui.Pages[$k].Visible = ($k -eq $name) }
        foreach ($k in $ui.Nav.Keys) {
            $ui.Nav[$k].BackColor = $(if ($k -eq $name) { $Clr.AccentD } else { $Clr.Side })
            $ui.Nav[$k].ForeColor = $(if ($k -eq $name) { $Clr.Text } else { $Clr.Dim })
        }
        switch ($name) {
            'presets' { Fill-Presets }
            'keys'    { Load-Hotkeys }
            'backup'  { Fill-Backups }
            'tools'   { $ui.PathBox.Text = $Ctx.FiveMApp }
        }
    }

    # ---------- background work ----------
    function Set-Busy([bool]$busy) {
        $ui.Busy = $busy
        foreach ($b in $ui.ActionButtons) { $b.Enabled = -not $busy }
        $form.Cursor = $(if ($busy) { 'AppStarting' } else { 'Default' })
    }

    function Start-Work([string]$title, [string]$job, $opt, [bool]$needClose, [scriptblock]$onDone) {
        if ($ui.Busy) { return }
        if ($needClose -and (Test-FiveMRunning)) {
            $r = [Windows.Forms.MessageBox]::Show($form, (M 'FiveM เปิดอยู่ ต้องปิดก่อน ปิดให้เลยไหม?' 'FiveM is running and must be closed. Close it now?'), 'ReShade for FiveM', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
        }
        Set-Busy $true
        $Ctx.StepNo = 0; $Ctx.Dl.Clear()
        $Sync.Done = $false; $Sync.Result = $null; $Sync.Error = $null; $Sync.Pct = 0; $Sync.Status = $title; $Sync.Detail = ''
        $ui.LastBytes = 0L; $ui.LastTick = [DateTime]::Now; $ui.Speed = 0.0
        Add-LogLine 'info' ''
        Add-LogLine 'step' $title
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
        $rs.SessionStateProxy.SetVariable('Ctx', $Ctx)
        $rs.SessionStateProxy.SetVariable('Opt', $opt)
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $text = $Core.ToString() + "`n" + @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
try { `$r = & { $job }; `$Ctx.Sync.Result = `$r }
catch { `$Ctx.Sync.Error = `$_.Exception.Message }
finally { `$Ctx.Sync.Done = `$true }
"@
        $null = $ps.AddScript($text)
        $ui.Work = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); OnDone = $onDone; Title = $title }
    }

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 120
    $timer.Add_Tick({
        $item = $null
        $n = 0
        while ($n -lt 200 -and $Sync.Log.TryDequeue([ref]$item)) { Add-LogLine $item[0] $item[1]; $n++ }
        $ui.Bar.Width = [int]($ui.BarBg.Width * [Math]::Min(100, $Sync.Pct) / 100)
        if ($ui.Busy) {
            if ($Sync.Status) { $ui.Status.Text = $Sync.Status }
            $bytes = 0L; $running = $false
            foreach ($v in @($Ctx.Dl.Values)) { $bytes += [long]$v.Done; if ($v.State -eq 'run') { $running = $true } }
            $now = [DateTime]::Now
            $dt = ($now - $ui.LastTick).TotalSeconds
            if ($dt -ge 0.5) {
                $inst = [Math]::Max(0, ($bytes - $ui.LastBytes)) / $dt
                $ui.Speed = 0.6 * $ui.Speed + 0.4 * $inst
                $ui.LastBytes = $bytes; $ui.LastTick = $now
            }
            $d = ''
            if ($running -or $bytes -gt 0) { $d = (Format-Size $bytes) + $(if ($running) { '   ' + (Format-Size $ui.Speed) + '/s' } else { '' }) }
            if ($Sync.Detail) { $d = $Sync.Detail + $(if ($running) { '   ' + (Format-Size $ui.Speed) + '/s' } else { '' }) }
            $ui.Detail.Text = $d
        }

        if ($ui.Busy -and $Sync.Done) {
            $w = $ui.Work
            try { $null = $w.PS.EndInvoke($w.Handle) } catch {}
            $w.PS.Dispose(); $w.RS.Close(); $w.RS.Dispose()
            while ($Sync.Log.TryDequeue([ref]$item)) { Add-LogLine $item[0] $item[1] }
            Set-Busy $false
            $ui.Detail.Text = ''
            if ($Sync.Error) {
                Add-LogLine 'err' $Sync.Error
                $ui.Status.Text = (M 'ผิดพลาด: ' 'Error: ') + $Sync.Error
                $ui.Bar.BackColor = $Clr.Red
                Show-Toast 'ReShade for FiveM' (M 'ทำงานไม่สำเร็จ ดูรายละเอียดในหน้าต่าง' 'Something failed. See the window.')
                [void][Windows.Forms.MessageBox]::Show($form, $Sync.Error, (M 'เกิดข้อผิดพลาด' 'Error'), 'OK', 'Error')
            } else {
                $ui.Bar.BackColor = $Clr.Accent
                if ($w.OnDone) { & $w.OnDone $Sync.Result }
            }
            Refresh-Status
        }
    })

    # ---------- status ----------
    function Refresh-Status {
        $st = Get-Status
        $ui.CardVer.Text = $(if ($st.Installed) { $st.Installed } else { '-' })
        $ui.CardVerSub.Text = (M 'ล่าสุด: ' 'Latest: ') + $(if ($ui.Latest) { $ui.Latest } else { '...' })
        if ($st.Installed -and $ui.Latest -and $st.Installed -ne 'unknown') {
            try { if ([version]$st.Installed -lt [version]$ui.Latest) { $ui.CardVerSub.Text += (M '  (มีอัปเดต)' '  (update)'); $ui.CardVerSub.ForeColor = $Clr.Amber } else { $ui.CardVerSub.ForeColor = $Clr.Dim } } catch {}
        }
        $ui.CardAck.Text = $(if ($st.Ack) { (M 'พร้อม' 'Ready') } else { (M 'ยังไม่ยืนยัน' 'Not confirmed') })
        $ui.CardAck.ForeColor = $(if ($st.Ack) { $Clr.Green } else { $Clr.Amber })
        $ui.CardFx.Text = "$($st.Effects)"
        $ui.CardFxSub.Text = "$($st.Packages) " + (M 'ชุด, ' 'packages, ') + (Format-Size $st.ShadersSize) + $(if ($st.Disabled) { (M ", ปิด $($st.Disabled)" ", $($st.Disabled) off") } else { '' })
        $ui.CardPreset.Text = $(if ($st.Preset) { $st.Preset } else { '-' })
        $ui.HeadSub.Text = 'FiveM.app: ' + $Ctx.FiveMApp + $(if (-not $st.FiveMFound) { (M '   (ไม่พบ!)' '   (not found!)') } else { '' })
        if ($ui.FxInfo) { $ui.FxInfo.Text = (M 'ใช้พื้นที่: ' 'Disk use: ') + (Format-Size $st.ShadersSize) + '   ' + (M 'effect ที่ปิดไว้: ' 'Turned off: ') + $st.Disabled }
    }

    # ======================= HOME =======================
    $pg = New-Page 'home' (M 'หน้าหลัก' 'Home')
    $cw = 180; $cx = 24
    $c1 = Card $pg $cx 58 $cw 96
    $null = L $c1 'ReShade' 12 8 150 20 $Fnt.Small $Clr.Dim
    $ui.CardVer = L $c1 '-' 12 28 160 36 $Fnt.Big $Clr.Text
    $ui.CardVerSub = L $c1 '' 12 66 166 22 $Fnt.Small $Clr.Dim
    $c2 = Card $pg ($cx + 190) 58 $cw 96
    $null = L $c2 'FiveM (CitizenFX.ini)' 12 8 160 20 $Fnt.Small $Clr.Dim
    $ui.CardAck = L $c2 '-' 12 28 166 36 $Fnt.Big $Clr.Text
    $null = L $c2 '[Addons] ReShade' 12 66 160 22 $Fnt.Small $Clr.Dim
    $c3 = Card $pg ($cx + 380) 58 $cw 96
    $null = L $c3 'Effects' 12 8 150 20 $Fnt.Small $Clr.Dim
    $ui.CardFx = L $c3 '0' 12 28 160 36 $Fnt.Big $Clr.Text
    $ui.CardFxSub = L $c3 '' 12 66 166 22 $Fnt.Small $Clr.Dim
    $c4 = Card $pg ($cx + 570) 58 $cw 96
    $null = L $c4 'Preset' 12 8 150 20 $Fnt.Small $Clr.Dim
    $ui.CardPreset = L $c4 '-' 12 34 166 30 $Fnt.Head $Clr.Text
    $null = L $c4 (M 'ใช้อยู่' 'active') 12 66 160 22 $Fnt.Small $Clr.Dim

    $null = L $pg (M 'ตัวเลือก' 'Options') 24 168 300 24 $Fnt.Bold $Clr.Dim
    $ui.OptAddon = CB $pg (M 'ใช้ ReShade รุ่น Add-on' 'Use the ReShade Add-on build') 24 194 340 ([bool]$Ctx.State.Addon)
    $ui.OptPerf = CB $pg (M 'Performance Mode (FPS ดีขึ้น แก้ค่า effect ไม่ได้)' 'Performance Mode (more FPS, effects locked)') 24 222 380 ([bool]$Ctx.State.PerformanceMode)
    $ui.OptLaunch = CB $pg (M 'เปิด FiveM หลังติดตั้งเสร็จ' 'Start FiveM after install') 400 194 360 ([bool]$Ctx.State.AutoLaunch)
    $ui.OptWeekly = CB $pg (M 'เช็กอัปเดต ReShade ทุกสัปดาห์' 'Check for ReShade updates weekly') 400 222 360 ([bool]$Ctx.State.WeeklyCheck)
    $ui.OptShortcut = CB $pg (M 'สร้าง shortcut บน Desktop' 'Create Desktop shortcut') 24 250 340 ([bool]$Ctx.State.Shortcut)

    $ui.OptAddon.Add_CheckedChanged({ $Ctx.State.Addon = $ui.OptAddon.Checked; Save-State })
    $ui.OptLaunch.Add_CheckedChanged({ $Ctx.State.AutoLaunch = $ui.OptLaunch.Checked; Save-State })
    $ui.OptShortcut.Add_CheckedChanged({ $Ctx.State.Shortcut = $ui.OptShortcut.Checked; Save-State })
    $ui.OptPerf.Add_CheckedChanged({
        $Ctx.State.PerformanceMode = $ui.OptPerf.Checked; Save-State
        if (Test-Path -LiteralPath $Ctx.ReShadeIni) { Set-IniValue $Ctx.ReShadeIni 'GENERAL' 'PerformanceMode' $(if ($ui.OptPerf.Checked) { '1' } else { '0' }) }
    })
    $ui.OptWeekly.Add_CheckedChanged({
        $Ctx.State.WeeklyCheck = $ui.OptWeekly.Checked; Save-State
        if (Get-InstalledReShade) { Set-UpdateTask $ui.OptWeekly.Checked }
    })

    $null = B $pg (M 'ติดตั้ง / อัปเดต' 'Install / update') 24 296 230 52 'accent' {
        $urls = $null
        $haveShaders = Test-Path -LiteralPath (Join-Path $Ctx.ShadersDir 'Shaders')
        if (-not (@($Ctx.State.Packages).Count -and $haveShaders) -and $ui.Packages.Count) { $urls = @(Get-CheckedUrls) }
        $opt = @{ Addon = $ui.OptAddon.Checked; Force = $false; PackageUrls = $urls; EffectsOnly = $false }
        Start-Work (M 'ติดตั้ง / อัปเดต ReShade' 'Install / update ReShade') 'Invoke-Install $Opt' $opt $true {
            param($r)
            $ui.Status.Text = (M 'เสร็จแล้ว! เข้า FiveM แล้วกด Home เพื่อเปิด ReShade' 'Done! In FiveM press Home to open ReShade')
            Show-Toast 'ReShade for FiveM' (M 'ติดตั้งเสร็จแล้ว กด Home ในเกมเพื่อเปิด ReShade' 'Installed. Press Home in game to open ReShade.')
            if ($Ctx.State.AutoLaunch -and (Test-Path -LiteralPath $Ctx.FiveMExe)) { Start-Process -FilePath $Ctx.FiveMExe }
        }
    }
    $null = B $pg (M 'ติดตั้งใหม่ทั้งหมด' 'Force reinstall') 264 296 160 52 '' {
        $opt = @{ Addon = $ui.OptAddon.Checked; Force = $true; PackageUrls = $null; EffectsOnly = $false }
        Start-Work (M 'ติดตั้ง ReShade ใหม่' 'Reinstall ReShade') 'Invoke-Install $Opt' $opt $true { param($r) $ui.Status.Text = (M 'เสร็จแล้ว' 'Done') }
    }
    $null = B $pg (M 'ซ่อม' 'Repair') 434 296 120 52 '' {
        Start-Work (M 'ซ่อม ReShade' 'Repair ReShade') 'Invoke-Repair' $null $true { param($r) $ui.Status.Text = (M 'ซ่อมเสร็จแล้ว' 'Repair done') }
    }
    $null = B $pg (M 'เปิด FiveM' 'Start FiveM') 564 296 120 52 '' {
        if (Test-Path -LiteralPath $Ctx.FiveMExe) { Start-Process -FilePath $Ctx.FiveMExe } else { [void][Windows.Forms.MessageBox]::Show($form, (M 'ไม่พบ FiveM.exe' 'FiveM.exe not found')) }
    }
    $null = B $pg 'Changelog' 694 296 100 52 '' { Start-Process 'https://reshade.me' } $false
    $null = L $pg (M 'ในเกม: Home = เปิดเมนู ReShade   |   ตั้งปุ่มอื่นได้ที่หน้า "ปุ่มลัด"' 'In game: Home = ReShade menu   |   change keys on the "Hotkeys" page') 24 362 770 22 $Fnt.Small $Clr.Dim

    # ======================= EFFECTS =======================
    $pg = New-Page 'effects' (M 'ชุด effect' 'Effect packages')
    $null = L $pg (M 'ค้นหา' 'Search') 24 58 60 26 $Fnt.Normal $Clr.Dim
    $ui.Search = New-Object Windows.Forms.TextBox
    $ui.Search.Location = New-Object Drawing.Point 84, 56; $ui.Search.Size = New-Object Drawing.Size 300, 26
    $ui.Search.BackColor = $Clr.Card; $ui.Search.ForeColor = $Clr.Text; $ui.Search.BorderStyle = 'FixedSingle'
    $ui.Search.Add_TextChanged({ Fill-PackageList })
    $pg.Controls.Add($ui.Search)
    $null = B $pg (M 'แนะนำ' 'Recommended') 400 54 110 30 '' { Set-Checked 'recommended' } $false
    $null = B $pg (M 'ทั้งหมด' 'All') 516 54 90 30 '' { Set-Checked 'all' } $false
    $null = B $pg (M 'พื้นฐาน' 'Basic') 612 54 90 30 '' { Set-Checked 'basic' } $false
    $null = B $pg (M 'เว็บ' 'Web') 708 54 86 30 '' {
        if ($ui.Lv.SelectedItems.Count -and $ui.Lv.SelectedItems[0].Tag.Repo) { Start-Process $ui.Lv.SelectedItems[0].Tag.Repo }
    } $false

    $lv = New-Object Windows.Forms.ListView
    $lv.Location = New-Object Drawing.Point 24, 92; $lv.Size = New-Object Drawing.Size 770, 222
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.HideSelection = $false
    $lv.BackColor = $Clr.Card; $lv.ForeColor = $Clr.Text; $lv.BorderStyle = 'None'; $lv.Font = $Fnt.Normal
    $lv.HeaderStyle = 'Nonclickable'; $lv.OwnerDraw = $true
    [void]$lv.Columns.Add((M 'ชื่อ' 'Name'), 250)
    [void]$lv.Columns.Add((M 'คำอธิบาย' 'Description'), 500)
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $Clr.Side), $e.Bounds)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $Fnt.Bold, $e.Bounds, $Clr.Dim, ([Windows.Forms.TextFormatFlags]'VerticalCenter, Left'))
    })
    $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_ItemCheck({
        param($s, $e)
        if ($ui.Filling) { return }
        if ($lv.Items[$e.Index].Tag.Required) { $e.NewValue = 'Checked' }
    })
    $lv.Add_ItemChecked({
        param($s, $e)
        if ($ui.Filling) { return }
        $ui.Checked[$e.Item.Tag.Url] = $e.Item.Checked
        Update-SelCount
    })
    $pg.Controls.Add($lv); $ui.Lv = $lv

    $ui.SelCount = L $pg '' 24 320 400 22 $Fnt.Small $Clr.Dim
    $ui.FxInfo = L $pg '' 430 320 364 22 $Fnt.Small $Clr.Dim
    $ui.FxInfo.TextAlign = 'MiddleRight'
    $null = B $pg (M 'ติดตั้ง effect ที่เลือก' 'Install selected') 24 346 200 40 'accent' {
        $opt = @{ Addon = [bool]$Ctx.State.Addon; Force = $false; PackageUrls = @(Get-CheckedUrls); EffectsOnly = $true }
        Start-Work (M 'ติดตั้งชุด effect' 'Install effect packages') 'Invoke-Install $Opt' $opt $true { param($r) $ui.Status.Text = (M 'ติดตั้ง effect เสร็จแล้ว' 'Effects installed') }
    }
    $null = B $pg (M 'ปิด effect ที่พัง' 'Turn off broken effects') 234 346 190 40 '' {
        Start-Work (M 'ปิด effect ที่ compile ไม่ผ่าน' 'Turn off effects that failed to compile') 'Invoke-Cleanup' $null $false { param($r) $ui.Status.Text = (M "ปิด effect ที่พังแล้ว $r ไฟล์" "Turned off $r broken effects") }
    }
    $null = B $pg (M 'คืน effect ที่ปิด' 'Restore turned-off') 434 346 170 40 '' {
        Start-Work (M 'คืน effect ที่ปิดไว้' 'Restore turned-off effects') 'Invoke-RestoreDisabled' $null $false { param($r) $ui.Status.Text = (M "คืน effect แล้ว $r ไฟล์" "Restored $r effects") }
    }

    function Get-CheckedUrls { @($ui.Packages | Where-Object { $_.Required -or $ui.Checked[$_.Url] } | ForEach-Object { $_.Url }) }
    function Update-SelCount {
        $n = @(Get-CheckedUrls).Count
        $ui.SelCount.Text = (M "เลือก $n จาก $($ui.Packages.Count) ชุด   (★ = แนะนำ)" "$n of $($ui.Packages.Count) selected   (★ = recommended)")
    }
    function Set-Checked([string]$mode) {
        foreach ($p in $ui.Packages) {
            $ui.Checked[$p.Url] = switch ($mode) { 'all' { $true } 'basic' { $p.Required } default { $p.Required -or $p.Recommended } }
        }
        Fill-PackageList
    }
    function Fill-PackageList {
        $q = $ui.Search.Text.Trim()
        $ui.Filling = $true
        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($p in $ui.Packages) {
            if ($q -and ($p.Name -notlike "*$q*") -and ($p.Description -notlike "*$q*")) { continue }
            $name = $(if ($p.Recommended) { [string][char]0x2605 + ' ' } else { '    ' }) + $p.Name + $(if ($p.Required) { (M '  (จำเป็น)' '  (required)') } else { '' })
            $it = New-Object Windows.Forms.ListViewItem $name
            [void]$it.SubItems.Add($p.Description)
            $it.Tag = $p
            $it.Checked = [bool]($p.Required -or $ui.Checked[$p.Url])
            if ($p.Required) { $it.ForeColor = $Clr.Dim }
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
        $ui.Filling = $false
        Update-SelCount
    }

    # ======================= PRESETS =======================
    $pg = New-Page 'presets' 'Presets'
    $ui.PresetList = New-Object Windows.Forms.ListBox
    $ui.PresetList.Location = New-Object Drawing.Point 24, 58; $ui.PresetList.Size = New-Object Drawing.Size 500, 290
    $ui.PresetList.BackColor = $Clr.Card; $ui.PresetList.ForeColor = $Clr.Text; $ui.PresetList.BorderStyle = 'None'; $ui.PresetList.Font = $Fnt.Normal
    $ui.PresetList.ItemHeight = 22
    $pg.Controls.Add($ui.PresetList)
    $null = B $pg (M 'เพิ่มจากไฟล์...' 'Add from file...') 540 58 254 40 '' {
        $dlg = New-Object Windows.Forms.OpenFileDialog
        $dlg.Filter = 'ReShade preset (*.ini)|*.ini'; $dlg.Title = (M 'เลือกไฟล์ preset' 'Select a preset')
        if ($dlg.ShowDialog($form) -eq 'OK') { $null = Add-Preset $dlg.FileName; Fill-Presets; Refresh-Status }
    }
    $null = B $pg (M 'เพิ่มจาก URL...' 'Add from URL...') 540 104 254 40 '' {
        $u = [Microsoft.VisualBasic.Interaction]::InputBox((M 'วางลิงก์ไฟล์ preset (.ini)' 'Paste the preset (.ini) link'), 'Preset URL', '')
        if ($u -match '^https?://') {
            Start-Work (M 'ดาวน์โหลด preset' 'Download preset') 'Add-Preset $Opt.Url' @{ Url = $u } $false { param($r) Fill-Presets }
        }
    }
    $null = B $pg (M 'ใช้ preset นี้' 'Use this preset') 540 150 254 40 'accent' {
        $i = $ui.PresetList.SelectedIndex
        if ($i -ge 0) { Set-ActivePreset $ui.PresetPaths[$i]; Add-LogLine 'ok' ((M 'ใช้ preset: ' 'Active preset: ') + [IO.Path]::GetFileName($ui.PresetPaths[$i])); Fill-Presets; Refresh-Status }
    }
    $null = B $pg (M 'ลบ' 'Delete') 540 196 254 40 'danger' {
        $i = $ui.PresetList.SelectedIndex
        if ($i -ge 0) {
            $p = $ui.PresetPaths[$i]
            if ([Windows.Forms.MessageBox]::Show($form, ((M 'ลบ ' 'Delete ') + [IO.Path]::GetFileName($p) + '?'), 'Preset', 'YesNo', 'Warning') -eq 'Yes') {
                Remove-Item -LiteralPath $p -Force; Fill-Presets; Refresh-Status
            }
        }
    }
    $null = B $pg (M 'เปิดโฟลเดอร์ presets' 'Open presets folder') 540 242 254 40 '' {
        New-Item -ItemType Directory -Path $Ctx.PresetDir -Force | Out-Null; Start-Process explorer.exe $Ctx.PresetDir
    } $false
    $null = L $pg (M 'เปลี่ยน preset แล้วเปิด FiveM ใหม่ หรือเปลี่ยนในเกมได้จากเมนู ReShade' 'Restart FiveM after changing, or switch in game from the ReShade menu') 24 356 770 22 $Fnt.Small $Clr.Dim

    function Fill-Presets {
        $ui.PresetList.Items.Clear()
        $ui.PresetPaths = @(Get-Presets)
        $active = Get-ActivePreset
        foreach ($p in $ui.PresetPaths) {
            $mark = if ($active -and ([IO.Path]::GetFullPath($p) -eq $active)) { [string][char]0x2605 + '  ' } else { '    ' }
            [void]$ui.PresetList.Items.Add($mark + [IO.Path]::GetFileName($p))
        }
        if (-not $ui.PresetPaths.Count) { [void]$ui.PresetList.Items.Add((M '   (ยังไม่มี preset)' '   (no presets yet)')) }
    }

    # ======================= HOTKEYS =======================
    $pg = New-Page 'keys' (M 'ปุ่มลัด' 'Hotkeys')
    $keyNames = @($KeyList.Keys)
    $rows = @(
        @('KeyOverlay', (M 'เปิด / ปิดเมนู ReShade' 'Open / close the ReShade menu'), 36),
        @('KeyEffects', (M 'เปิด / ปิด effect ทั้งหมด' 'Turn all effects on / off'), 145),
        @('KeyScreenshot', (M 'ถ่าย screenshot' 'Take a screenshot'), 44)
    )
    $ui.KeyCombos = @{}
    $ky = 64
    foreach ($r in $rows) {
        $kc = Card $pg 24 $ky 500 52
        $null = L $kc $r[1] 16 14 280 24 $Fnt.Normal $Clr.Text
        $cb = New-Object Windows.Forms.ComboBox
        $cb.DropDownStyle = 'DropDownList'; $cb.FlatStyle = 'Flat'
        $cb.BackColor = $Clr.Side; $cb.ForeColor = $Clr.Text; $cb.Font = $Fnt.Normal
        $cb.Location = New-Object Drawing.Point 300, 12; $cb.Size = New-Object Drawing.Size 180, 28
        [void]$cb.Items.AddRange([object[]]$keyNames)
        $cb.Tag = $r[2]
        $kc.Controls.Add($cb)
        $ui.KeyCombos[$r[0]] = $cb
        $ky += 62
    }
    $null = B $pg (M 'บันทึกปุ่มลัด' 'Save hotkeys') 24 258 200 42 'accent' {
        $v = @{}
        foreach ($k in $ui.KeyCombos.Keys) { $v[$k] = [int]$KeyList[[string]$ui.KeyCombos[$k].SelectedItem] }
        Set-Hotkeys $v.KeyOverlay $v.KeyEffects $v.KeyScreenshot
        Add-LogLine 'ok' (M 'บันทึกปุ่มลัดแล้ว มีผลเมื่อเปิด FiveM ใหม่' 'Hotkeys saved. Restart FiveM to apply.')
        $ui.Status.Text = (M 'บันทึกปุ่มลัดแล้ว' 'Hotkeys saved')
    }
    $null = B $pg (M 'ค่าเริ่มต้น' 'Defaults') 234 258 140 42 '' {
        foreach ($k in $ui.KeyCombos.Keys) { $cb = $ui.KeyCombos[$k]; $name = ($KeyList.GetEnumerator() | Where-Object { $_.Value -eq $cb.Tag } | Select-Object -First 1).Key; $cb.SelectedItem = $name }
    } $false
    $null = L $pg (M '"-" = ไม่ใช้ปุ่ม   |   ปุ่มเปิด/ปิด effect ช่วยเทียบภาพก่อน-หลัง' '"-" = no key   |   the effects key is handy for before/after') 24 310 770 22 $Fnt.Small $Clr.Dim

    function Load-Hotkeys {
        $hk = Get-Hotkeys
        foreach ($k in $ui.KeyCombos.Keys) {
            $cb = $ui.KeyCombos[$k]
            $vk = if ($hk[$k] -ge 0) { $hk[$k] } else { $cb.Tag }
            $name = ($KeyList.GetEnumerator() | Where-Object { $_.Value -eq $vk } | Select-Object -First 1).Key
            if (-not $name) { $name = ($KeyList.GetEnumerator() | Where-Object { $_.Value -eq $cb.Tag } | Select-Object -First 1).Key }
            $cb.SelectedItem = $name
        }
    }

    # ======================= BACKUP =======================
    $pg = New-Page 'backup' (M 'สำรอง / กู้คืน' 'Backup / restore')
    $ui.BackupList = New-Object Windows.Forms.ListBox
    $ui.BackupList.Location = New-Object Drawing.Point 24, 58; $ui.BackupList.Size = New-Object Drawing.Size 560, 290
    $ui.BackupList.BackColor = $Clr.Card; $ui.BackupList.ForeColor = $Clr.Text; $ui.BackupList.BorderStyle = 'None'; $ui.BackupList.Font = $Fnt.Normal
    $pg.Controls.Add($ui.BackupList)
    $null = B $pg (M 'กู้คืนที่เลือก' 'Restore selected') 600 58 194 42 'accent' {
        $i = $ui.BackupList.SelectedIndex
        if ($i -lt 0 -or $i -ge $ui.Backups.Count) { return }
        $b = $ui.Backups[$i]
        if ([Windows.Forms.MessageBox]::Show($form, ((M 'กู้คืนไฟล์ตั้งค่าจาก ' 'Restore settings from ') + $b.Name + '?'), (M 'กู้คืน' 'Restore'), 'YesNo', 'Question') -eq 'Yes') {
            Start-Work (M 'กู้คืนไฟล์ตั้งค่า' 'Restore settings') 'Invoke-Restore $Opt.Path' @{ Path = $b.Path } $true { param($r) Fill-Backups; $ui.Status.Text = (M 'กู้คืนแล้ว' 'Restored') }
        }
    }
    $null = B $pg (M 'สำรองตอนนี้' 'Back up now') 600 106 194 42 '' { Backup-Configs; Fill-Backups }
    $null = B $pg (M 'เปิดโฟลเดอร์ backup' 'Open backup folder') 600 154 194 42 '' {
        New-Item -ItemType Directory -Path $Ctx.BackupRoot -Force | Out-Null; Start-Process explorer.exe $Ctx.BackupRoot
    } $false
    $null = L $pg (M 'สำรองอัตโนมัติก่อนติดตั้ง/ซ่อม/ถอน ทุกครั้ง เก็บ 10 ชุดล่าสุด' 'Automatic backup before every install/repair/uninstall, newest 10 kept') 24 356 770 22 $Fnt.Small $Clr.Dim

    function Fill-Backups {
        $ui.BackupList.Items.Clear()
        $ui.Backups = @(Get-Backups)
        foreach ($b in $ui.Backups) { [void]$ui.BackupList.Items.Add('  ' + $b.Label) }
        if (-not $ui.Backups.Count) { [void]$ui.BackupList.Items.Add((M '   (ยังไม่มีไฟล์สำรอง)' '   (no backups yet)')) }
    }

    # ======================= TOOLS =======================
    $pg = New-Page 'tools' (M 'เครื่องมือ / ตั้งค่า' 'Tools / settings')
    $null = L $pg (M 'ภาษา' 'Language') 24 62 120 24 $Fnt.Normal $Clr.Dim
    $ui.LangBox = New-Object Windows.Forms.ComboBox
    $ui.LangBox.DropDownStyle = 'DropDownList'; $ui.LangBox.FlatStyle = 'Flat'; $ui.LangBox.BackColor = $Clr.Card; $ui.LangBox.ForeColor = $Clr.Text
    $ui.LangBox.Location = New-Object Drawing.Point 150, 58; $ui.LangBox.Size = New-Object Drawing.Size 160, 28
    [void]$ui.LangBox.Items.AddRange(@('ไทย', 'English'))
    $ui.LangBox.SelectedIndex = $(if ($Ctx.Lang -eq 'en') { 1 } else { 0 })
    $ui.LangBox.Add_SelectedIndexChanged({
        $new = if ($ui.LangBox.SelectedIndex -eq 1) { 'en' } else { 'th' }
        if ($new -eq $Ctx.Lang) { return }
        $Ctx.State.Lang = $new; Save-State
        if ([Windows.Forms.MessageBox]::Show($form, 'Restart now? / เปิดโปรแกรมใหม่เลยไหม?', 'Language', 'YesNo', 'Question') -eq 'Yes') { Restart-App }
    })
    $pg.Controls.Add($ui.LangBox)

    $null = L $pg 'FiveM.app' 24 104 120 24 $Fnt.Normal $Clr.Dim
    $ui.PathBox = New-Object Windows.Forms.TextBox
    $ui.PathBox.Location = New-Object Drawing.Point 150, 100; $ui.PathBox.Size = New-Object Drawing.Size 400, 26
    $ui.PathBox.ReadOnly = $true; $ui.PathBox.BackColor = $Clr.Card; $ui.PathBox.ForeColor = $Clr.Text; $ui.PathBox.BorderStyle = 'FixedSingle'
    $pg.Controls.Add($ui.PathBox)
    $null = B $pg (M 'เลือก...' 'Browse...') 560 98 110 30 '' {
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = (M 'เลือกโฟลเดอร์ FiveM.app (หรือ "FiveM Application Data")' 'Select the FiveM.app folder (or "FiveM Application Data")')
        if ($dlg.ShowDialog($form) -eq 'OK') { Set-FiveMPath $dlg.SelectedPath }
    }
    $null = B $pg (M 'หาอัตโนมัติ' 'Auto find') 676 98 118 30 '' {
        $f = Find-FiveM
        if ($f) { Set-FiveMPath $f } else { [void][Windows.Forms.MessageBox]::Show($form, (M 'หา FiveM ไม่เจอ' 'FiveM not found')) }
    }

    $tx = 24; $ty = 150
    $tools = @(
        @((M 'โฟลเดอร์ plugins' 'plugins folder'), { New-Item -ItemType Directory -Path $Ctx.Plugins -Force | Out-Null; Start-Process explorer.exe $Ctx.Plugins }),
        @((M 'โฟลเดอร์ screenshot' 'Screenshot folder'), { New-Item -ItemType Directory -Path $Ctx.ShotDir -Force | Out-Null; Start-Process explorer.exe $Ctx.ShotDir }),
        @('ReShade.log', { if (Test-Path -LiteralPath $Ctx.ReShadeLog) { Start-Process notepad.exe $Ctx.ReShadeLog } else { [void][Windows.Forms.MessageBox]::Show($form, (M 'ยังไม่มี ReShade.log' 'No ReShade.log yet')) } }),
        @((M 'log ของโปรแกรมนี้' 'Installer logs'), { Start-Process explorer.exe $Ctx.LogDir }),
        @('reshade.me', { Start-Process 'https://reshade.me' }),
        @((M 'สร้าง shortcut ใหม่' 'Recreate shortcut'), { Install-Shortcut })
    )
    foreach ($t in $tools) {
        $null = B $pg $t[0] $tx $ty 250 40 '' $t[1] $false
        $tx += 260; if ($tx -gt 600) { $tx = 24; $ty += 48 }
    }
    $null = B $pg (M 'ถอนการติดตั้ง ReShade' 'Uninstall ReShade') 24 300 250 42 'danger' {
        if ([Windows.Forms.MessageBox]::Show($form, (M 'ลบ ReShade, effect และ preset ออกจาก FiveM? (มีไฟล์สำรองไว้)' 'Remove ReShade, effects and presets from FiveM? (a backup is kept)'), (M 'ถอนการติดตั้ง' 'Uninstall'), 'YesNo', 'Warning') -eq 'Yes') {
            Start-Work (M 'ถอนการติดตั้ง' 'Uninstall') 'Invoke-Uninstall' $null $true { param($r) $ui.Status.Text = (M 'ถอนการติดตั้งแล้ว' 'Uninstalled') }
        }
    }
    $null = L $pg ("ReShade for FiveM v$ScriptVersion   |   " + (M 'ดาวน์โหลดจาก reshade.me และ GitHub เท่านั้น' 'Downloads only from reshade.me and GitHub')) 24 356 770 22 $Fnt.Small $Clr.Dim

    function Set-FiveMPath([string]$path) {
        $p = $path
        if (-not (Test-Path -LiteralPath (Join-Path $p 'plugins')) -and (Test-Path -LiteralPath (Join-Path $p 'FiveM.app'))) { $p = Join-Path $p 'FiveM.app' }
        Set-CtxPaths $p
        $Ctx.State.FiveMApp = $p; Save-State
        $ui.PathBox.Text = $p
        Add-LogLine 'ok' ('FiveM.app: ' + $p)
        Refresh-Status
    }

    function Restart-App {
        if ($Ctx.IsExe) { Start-Process -FilePath $Ctx.SelfProcess }
        else {
            $file = $Ctx.SelfScript
            if (-not $file) { $file = Install-LocalCopy }
            if ($file) { Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$file`"" }
        }
        $form.Close()
    }

    # ---------- start ----------
    $form.Add_Shown({
        # Bring the window to the front even when started from another window.
        $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
        Show-Page 'home'
        Refresh-Status
        $timer.Start()
        if (-not (Test-Path -LiteralPath $Ctx.FiveMApp)) {
            [void][Windows.Forms.MessageBox]::Show($form, (M 'ไม่พบโฟลเดอร์ FiveM.app กรุณาเลือกเอง' 'FiveM.app folder not found. Please select it.'), 'FiveM', 'OK', 'Warning')
            Show-Page 'tools'
        }
        Start-Work (M 'โหลดรายการ effect และเช็กเวอร์ชัน' 'Loading effect list and checking version') '[pscustomobject]@{ Packages = @(Get-PackageList); Latest = (Get-LatestReShade ([bool]$Ctx.State.Addon)) }' $null $false {
            param($r)
            if ($r) {
                $ui.Packages = @($r.Packages)
                $ui.Latest = $r.Latest.Version
                $saved = @($Ctx.State.Packages)
                foreach ($p in $ui.Packages) { $ui.Checked[$p.Url] = $(if ($saved.Count) { $p.Required -or ($saved -contains $p.Url) } else { $p.Required -or $p.Recommended }) }
                Fill-PackageList
                Add-LogLine 'ok' ((M 'ReShade ล่าสุด: ' 'Latest ReShade: ') + $ui.Latest + '   ' + (M 'ชุด effect: ' 'Effect packages: ') + $ui.Packages.Count)
            }
            $ui.Status.Text = (M 'พร้อม' 'Ready')
            $Sync.Pct = 0
        }
    })
    $form.Add_FormClosing({
        param($s, $e)
        if ($ui.Busy) {
            $r = [Windows.Forms.MessageBox]::Show($form, (M 'กำลังทำงานอยู่ ปิดเลยไหม?' 'Work in progress. Close anyway?'), 'ReShade for FiveM', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $e.Cancel = $true; return }
            try { $ui.Work.PS.Stop() } catch {}
        }
        $timer.Stop()
    })

    # The .bat file and the shortcut start PowerShell hidden. When started from a
    # terminal (for example "irm ... | iex"), the terminal stays visible on purpose.

    [void]$form.ShowDialog()
    $Ctx.Sync = $null
}

# ============================================================================
#  TEXT MENU (used with -NoGui, or when the window cannot open)
# ============================================================================
function Write-ConsoleBanner {
    try { Clear-Host } catch {}
    $uni = [bool]$env:WT_SESSION
    $h = if ($uni) { [string][char]0x2500 } else { '=' }
    $line = $h * 60
    Write-Host ''
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host '    ___      ___ _            _       ' -ForegroundColor Magenta
    Write-Host '   | _ \___ / __| |_  __ _ __| |___   ' -ForegroundColor DarkMagenta
    Write-Host '   |   / -_)\__ \ '' \/ _` / _` / -_)  ' -ForegroundColor Blue
    Write-Host '   |_|_\___||___/_||_\__,_\__,_\___|  ' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "    ReShade for FiveM  v$ScriptVersion" -ForegroundColor White
    Write-Host ('    ' + (M 'ติดตั้ง ReShade ลง FiveM อัตโนมัติ' 'Automatic ReShade setup for FiveM')) -ForegroundColor Gray
    Write-Host "  $line" -ForegroundColor DarkCyan
}

# Arrow-key menu. Returns the chosen index. Picks the default after $timeout seconds
# unless a key is pressed.
function Select-Arrow([string]$title, [string[]]$items, [int]$default = 0, [int]$timeout = 10) {
    Write-Host ''
    Write-Host "  $title" -ForegroundColor White
    try { $null = [Console]::KeyAvailable; $top = [Console]::CursorTop } catch {
        for ($i = 0; $i -lt $items.Count; $i++) { Write-Host ("    {0}  {1}" -f ($i + 1), $items[$i]) }
        $r = Read-Host '  >'
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $items.Count) { return [int]$r - 1 }
        return $default
    }
    $lines = $items.Count + 1
    for ($i = 0; $i -lt $lines; $i++) { Write-Host '' }
    $top = [Console]::CursorTop - $lines
    $sel = $default; $auto = $true
    $deadline = (Get-Date).AddSeconds($timeout)
    $width = [Math]::Max(40, [Math]::Min(76, [Console]::WindowWidth - 4))
    try { [Console]::CursorVisible = $false } catch {}
    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $top)
            for ($i = 0; $i -lt $items.Count; $i++) {
                $t = ('  ' + ($i + 1) + '  ' + $items[$i])
                if ($t.Length -gt $width) { $t = $t.Substring(0, $width) }
                if ($i -eq $sel) { Write-Host ('  ' + $t.PadRight($width)) -ForegroundColor Black -BackgroundColor Cyan }
                else { Write-Host ('  ' + $t.PadRight($width)) -ForegroundColor Gray }
            }
            $remain = [Math]::Max(0, [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
            $hint = if ($auto) { (M "  ↑↓ เลือก   Enter ยืนยัน   อัตโนมัติใน $remain วิ" "  Up/Down choose   Enter confirm   auto in ${remain}s") } else { (M '  ↑↓ เลือก   Enter ยืนยัน' '  Up/Down choose   Enter confirm') }
            Write-Host $hint.PadRight($width + 2) -ForegroundColor DarkGray
            $waited = 0
            while (-not [Console]::KeyAvailable -and $waited -lt 250) { Start-Sleep -Milliseconds 50; $waited += 50 }
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                $auto = $false
                switch ($k.Key) {
                    'UpArrow'   { $sel = ($sel - 1 + $items.Count) % $items.Count }
                    'DownArrow' { $sel = ($sel + 1) % $items.Count }
                    'Enter'     { return $sel }
                    'Escape'    { return -1 }
                    default {
                        if ($k.KeyChar -match '^\d$') { $d = [int][string]$k.KeyChar - 1; if ($d -ge 0 -and $d -lt $items.Count) { $sel = $d } }
                    }
                }
            } elseif ($auto -and (Get-Date) -ge $deadline) { return $sel }
        }
    } finally { try { [Console]::CursorVisible = $true } catch {} }
}

function Ask-PackageUrls($all) {
    $rec = @($all | Where-Object { $_.Recommended }).Count
    $choice = Select-Arrow (M 'เลือกชุด effect' 'Choose effect packages') @(
        (M "แนะนำ ($rec ชุด: SweetFX, qUINT, iMMERSE, prod80 ...)" "Recommended (${rec}: SweetFX, qUINT, iMMERSE, prod80 ...)"),
        (M "ทั้งหมด ($($all.Count) ชุด, เข้าเกมช้าลงมาก)" "All ($($all.Count) packages, much slower game start)"),
        (M 'เลือกเอง' 'Pick myself'),
        (M 'พื้นฐานเท่านั้น' 'Standard effects only')
    ) 0 10
    switch ($choice) {
        1 { return @($all | ForEach-Object { $_.Url }) }
        2 {
            $chosen = $null
            try {
                $chosen = $all | Select-Object No, Name, Description |
                    Out-GridView -Title (M 'เลือกชุด effect (กด Ctrl ค้างเพื่อเลือกหลายอัน แล้วกด OK)' 'Pick effect packages (hold Ctrl for many, then OK)') -PassThru
            } catch {}
            if (-not $chosen) {
                foreach ($p in $all) { Write-Host ("    {0,2}  {1}" -f $p.No, $p.Name) -ForegroundColor Gray }
                $typed = Read-Host (M '  พิมพ์เลขที่ต้องการ คั่นด้วย ,' '  Type numbers separated by ,')
                return @(Select-Packages $all $typed | ForEach-Object { $_.Url })
            }
            $nums = @($chosen | ForEach-Object { $_.No })
            return @($all | Where-Object { $_.Required -or $nums -contains $_.No } | ForEach-Object { $_.Url })
        }
        3 { return @($all | Where-Object { $_.Required } | ForEach-Object { $_.Url }) }
        default { return @($all | Where-Object { $_.Required -or $_.Recommended } | ForEach-Object { $_.Url }) }
    }
}

function Write-ConsoleStatus {
    $st = Get-Status
    Write-Host ''
    Write-Host ('  FiveM.app : ' + $Ctx.FiveMApp + $(if (-not $st.FiveMFound) { (M '  (ไม่พบ!)' '  (not found!)') } else { '' })) -ForegroundColor Gray
    Write-Host ('  ReShade   : ' + $(if ($st.Installed) { $st.Installed } else { (M 'ยังไม่ได้ติดตั้ง' 'not installed') })) -ForegroundColor Gray
    Write-Host ('  Effects   : ' + $st.Effects + '  (' + (Format-Size $st.ShadersSize) + ')') -ForegroundColor Gray
    Write-Host ('  Preset    : ' + $(if ($st.Preset) { $st.Preset } else { '-' })) -ForegroundColor Gray
    Write-Host ('  CitizenFX : ' + $(if ($st.Ack) { 'OK' } else { (M 'ยังไม่ยืนยัน' 'not confirmed') })) -ForegroundColor Gray
}

function Invoke-Console([string]$todo) {
    Write-ConsoleBanner
    Write-ConsoleStatus
    if (-not (Test-Path -LiteralPath $Ctx.FiveMApp)) {
        throw ((M 'ไม่พบโฟลเดอร์ FiveM.app: ' 'FiveM.app folder not found: ') + $Ctx.FiveMApp + (M '  (ใช้ -FiveMApp ระบุตำแหน่ง)' '  (use -FiveMApp)'))
    }
    if ($todo -eq 'menu') {
        $acts = @('install', 'repair', 'effects', 'cleanup', 'preset', 'restore', 'open', 'uninstall', 'exit')
        $i = Select-Arrow (M 'เมนู' 'Menu') @(
            (M 'ติดตั้ง / อัปเดต' 'Install / update'),
            (M 'ซ่อม' 'Repair'),
            (M 'เลือกชุด effect ใหม่' 'Choose effect packages again'),
            (M 'ปิด effect ที่พัง (อ่านจาก ReShade.log)' 'Turn off broken effects (from ReShade.log)'),
            (M 'ติดตั้ง preset' 'Install a preset'),
            (M 'กู้คืนไฟล์สำรอง' 'Restore a backup'),
            (M 'เปิดโฟลเดอร์ plugins' 'Open plugins folder'),
            (M 'ถอนการติดตั้ง' 'Uninstall'),
            (M 'ออก' 'Exit')
        ) 0 10
        $todo = if ($i -ge 0) { $acts[$i] } else { 'exit' }
    }
    switch ($todo) {
        'install' {
            $urls = $null
            $have = Test-Path -LiteralPath (Join-Path $Ctx.ShadersDir 'Shaders')
            if ($Packages) { $urls = @(Select-Packages @(Get-PackageList) $Packages | ForEach-Object { $_.Url }) }
            elseif (-not (@($Ctx.State.Packages).Count -and $have)) { $urls = Ask-PackageUrls @(Get-PackageList) }
            Invoke-Install @{ Addon = ([bool]$Addon -or [bool]$Ctx.State.Addon); Force = [bool]$Force; PackageUrls = $urls; Preset = $Preset; EffectsOnly = $false }
            Write-Host ''
            Write-Host ('  ' + (M 'เสร็จแล้ว! เข้า FiveM แล้วกด Home เพื่อเปิด ReShade' 'Done! In FiveM press Home to open ReShade')) -ForegroundColor Green
            Show-Toast 'ReShade for FiveM' (M 'ติดตั้งเสร็จแล้ว กด Home ในเกมเพื่อเปิด ReShade' 'Installed. Press Home in game to open ReShade.')
        }
        'effects' {
            $all = @(Get-PackageList)
            $urls = if ($Packages) { @(Select-Packages $all $Packages | ForEach-Object { $_.Url }) } else { Ask-PackageUrls $all }
            Invoke-Install @{ Addon = [bool]$Ctx.State.Addon; Force = $false; PackageUrls = $urls; Preset = $null; EffectsOnly = $true }
        }
        'repair'  { Invoke-Repair }
        'cleanup' { $null = Invoke-Cleanup }
        'preset' {
            $src = $Preset
            if (-not $src) {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.OpenFileDialog
                $dlg.Filter = 'ReShade preset (*.ini)|*.ini'
                if ($dlg.ShowDialog() -eq 'OK') { $src = $dlg.FileName }
            }
            if ($src) { Backup-Configs; $null = Add-Preset $src } else { Log 'warn' (M 'ไม่ได้เลือก preset' 'No preset selected') }
        }
        'restore' {
            $list = @(Get-Backups)
            if (-not $list.Count) { Log 'warn' (M 'ยังไม่มีไฟล์สำรอง' 'No backups yet'); break }
            $i = Select-Arrow (M 'เลือกไฟล์สำรอง' 'Choose a backup') @($list | ForEach-Object { $_.Label }) 0 60
            if ($i -ge 0) { Invoke-Restore $list[$i].Path }
        }
        'open' { New-Item -ItemType Directory -Path $Ctx.Plugins -Force | Out-Null; Start-Process explorer.exe $Ctx.Plugins }
        'uninstall' {
            $i = Select-Arrow (M 'ยืนยันถอนการติดตั้ง?' 'Really uninstall?') @((M 'ไม่' 'No'), (M 'ใช่ ถอนการติดตั้ง' 'Yes, uninstall')) 0 30
            if ($i -eq 1) { Invoke-Uninstall }
        }
        default { }
    }
}

# ============================================================================
#  MAIN
# ============================================================================
$HomeDir = Join-Path $env:LOCALAPPDATA 'ReShadeFiveM'
$Ctx = @{
    HomeDir     = $HomeDir
    StateFile   = Join-Path $HomeDir 'state.json'
    BackupRoot  = Join-Path $HomeDir 'backup'
    LogDir      = Join-Path $HomeDir 'logs'
    ShotDir     = Join-Path $(if ([Environment]::GetFolderPath('MyPictures')) { [Environment]::GetFolderPath('MyPictures') } else { Join-Path $env:USERPROFILE 'Pictures' }) 'FiveM'
    Dl          = [hashtable]::Synchronized(@{})
    Sync        = $null
    StepNo      = 0
    StepTotal   = 0
    Lang        = 'th'
    IsExe       = [bool]$IsExe
    SelfProcess = $SelfProcess
    SelfScript  = $SelfScript
    SelfUrl     = $SelfUrl
}
. $Core

$Ctx.State = Get-State
if ($Lang) { $Ctx.Lang = $Lang; $Ctx.State.Lang = $Lang } elseif ($Ctx.State.Lang) { $Ctx.Lang = $Ctx.State.Lang }
if ($PerformanceMode) { $Ctx.State.PerformanceMode = $true }
if ($Addon) { $Ctx.State.Addon = $true }

$fivem = $null
if ($FiveMApp) { $fivem = $FiveMApp }
elseif ($Ctx.State.FiveMApp -and (Test-Path -LiteralPath $Ctx.State.FiveMApp)) { $fivem = $Ctx.State.FiveMApp }
elseif (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app')) { $fivem = Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app' }
else { try { $fivem = Find-FiveM } catch {} }
if (-not $fivem) { $fivem = Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app' }
Set-CtxPaths $fivem
if (Test-Path -LiteralPath $fivem) { $Ctx.State.FiveMApp = $fivem }

if ($Action -eq 'icon')  { $p = New-AppIcon (Join-Path $HomeDir 'icon.ico'); Write-Output $p; return }
if ($Action -eq 'check') { try { Invoke-Check } catch {}; return }

New-Item -ItemType Directory -Path $Ctx.LogDir -Force | Out-Null
$logFile = Join-Path $Ctx.LogDir ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
try { Start-Transcript -Path $logFile -Force | Out-Null } catch {}
Get-ChildItem -LiteralPath $Ctx.LogDir -Filter '*.log' | Sort-Object Name -Descending | Select-Object -Skip 15 | Remove-Item -Force -ErrorAction SilentlyContinue

$useGui = ($Action -eq 'menu') -and -not $NoGui
$failed = $false
try {
    $guiOk = $false
    if ($useGui) {
        try { Show-Gui; $guiOk = $true }
        catch {
            $Ctx.Sync = $null
            # The window may have been started hidden, so report with a message box and stop
            # (a hidden text menu would pick its default by itself).
            Show-FatalError $_
            throw
        }
        $guiOk = $true
    }
    if (-not $guiOk) { Invoke-Console $Action }
    Save-State
} catch {
    $failed = $true
    Write-Host ''
    Write-Host ('  ' + (M 'เกิดข้อผิดพลาด:' 'ERROR:')) -ForegroundColor Red
    Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host ('  ' + (M 'บรรทัด ' 'Line ') + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkRed }
    Show-Toast 'ReShade for FiveM' (M 'ทำงานไม่สำเร็จ ดูรายละเอียดในหน้าต่าง' 'Something failed. See the window.')
} finally {
    try { Stop-Transcript | Out-Null } catch {}
    if (-not $useGui) {
        Write-Host ''
        Write-Host ('  Log: ' + $logFile) -ForegroundColor DarkGray
        if ($failed) {
            try { Copy-Item -LiteralPath $logFile -Destination ([Environment]::GetFolderPath('Desktop')) -Force } catch {}
            Write-Host ('  ' + (M 'คัดลอก log ไว้บน Desktop แล้ว' 'Log copied to Desktop')) -ForegroundColor DarkGray
            Read-Host ('  ' + (M 'กด Enter เพื่อปิด' 'Press Enter to close'))
        } elseif ($NoAutoClose) {
            Read-Host ('  ' + (M 'กด Enter เพื่อปิด' 'Press Enter to close'))
        } elseif (Wait-Countdown (M 'ปิดหน้าต่างอัตโนมัติ กดปุ่มใดก็ได้เพื่อค้างไว้' 'Closing, press any key to keep open') 5) {
            Read-Host ('  ' + (M 'กด Enter เพื่อปิด' 'Press Enter to close'))
        }
    }
}
