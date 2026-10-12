# ReShade auto installation for FiveM

Installs and manages [ReShade](https://reshade.me) for **FiveM only**.
Files go into the FiveM `plugins` folder. The GTA V folder is never touched.

ติดตั้งและจัดการ ReShade สำหรับ **FiveM เท่านั้น** ไฟล์ลงในโฟลเดอร์ `plugins` ของ FiveM ไม่แตะโฟลเดอร์ GTA V

## ติดตั้ง / Install

**วิธีที่ 1 – คำสั่งบรรทัดเดียว (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/x2Swiftyouz/Reshade-auto-installation/main/install-reshade.ps1 | iex
```

**วิธีที่ 2 – ดาวน์โหลดไฟล์**

1. Download this repository (Code > Download ZIP) and extract it.
2. Double-click `Install-ReShade-FiveM.bat`.

**วิธีที่ 3 – ไฟล์ .exe**

Double-click `Build-EXE.bat` to build `ReShade FiveM.exe` (needs internet once for the `ps2exe` module).
Some antivirus programs flag ps2exe files by mistake. If that happens, use method 1 or 2.

## What it does

- Downloads ReShade only from reshade.me, always the newest version, and checks the file signature.
- Installs ReShade headless (no setup wizard) and copies only `dxgi.dll` into `FiveM.app\plugins`.
- Installs effect packages from the official ReShade package list (recommended / all / basic / pick yourself).
  Downloads run 4 at a time and are cached.
- Adds the `[Addons] ReShade5=ID:...` line to `CitizenFX.ini` by itself (reads the ID from the FiveM logs,
  or starts FiveM once to get it).
- Turns off effects that fail to compile (reads `ReShade.log`). Turned-off effects can be restored.
- Repair, backup / restore (newest 10 kept), presets (file or URL), hotkeys, Performance Mode,
  screenshot folder, Desktop shortcut, weekly update check with a Windows notification.
- Window UI in Thai or English. Text menu with `-NoGui`.

## Command line

```powershell
powershell -ExecutionPolicy Bypass -File .\install-reshade.ps1 -NoGui -Action install -Packages recommended
```

| Parameter | Values |
|---|---|
| `-Action` | `menu`, `install`, `repair`, `effects`, `cleanup`, `preset`, `restore`, `open`, `uninstall`, `check` |
| `-Packages` | `recommended`, `all`, `basic`, or numbers like `"0,1,9,23"` |
| `-Preset` | path or https URL of a preset `.ini` |
| `-Addon` | use the ReShade build with full add-on support |
| `-Force` | reinstall ReShade even if it is up to date |
| `-PerformanceMode` | turn on ReShade Performance Mode |
| `-NoGui` | text menu instead of the window |
| `-Lang` | `th` or `en` |
| `-FiveMApp` | path to `FiveM.app` if FiveM is not in the default place |

## Files and folders

| Path | Content |
|---|---|
| `%LOCALAPPDATA%\FiveM\FiveM.app\plugins\dxgi.dll` | ReShade |
| `...\plugins\reshade-shaders` | effects |
| `...\plugins\reshade-shaders-disabled` | effects turned off because they failed to compile |
| `...\plugins\presets` | presets |
| `%LOCALAPPDATA%\ReShadeFiveM` | settings, cache, backups, logs |

## Notes

- FiveM shows a warning that ReShade 5.x and newer can cause crashes. The `[Addons]` line confirms that warning.
  FiveM gives no support for ReShade.
- ReShade is made by crosire. Effect packages belong to their authors. This project only downloads them
  from their official sources.
