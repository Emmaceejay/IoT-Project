<#
.SYNOPSIS
    Build (and optionally flash) a single DSGV device firmware.

.DESCRIPTION
    Builds the firmware for one device SKU targeting a specific ESP32 chip variant.
    After a successful build, runs a hard binary-size check to guarantee the firmware
    fits inside its OTA partition before it is ever flashed or deployed.
    Optionally flashes and opens the serial monitor if a COM port is supplied.

.PARAMETER Device
    Device folder name under devices/. Must match one of:
    1gang_switch, 2gang_switch, 3gang_switch, 4gang_switch,
    dimmer, colour_temp, rgb_light,
    temp_sensor, motion_sensor, contact_sensor, thermostat

.PARAMETER Target
    IDF chip target. One of: esp32, esp32c3, esp32s3, esp32c6   (default: esp32c3)

.PARAMETER FlashMB
    Flash size of the target hardware in megabytes. Determines the OTA slot size
    limit passed to check_binary_size.py.
      4  →  partitions_4mb.csv  — OTA slot 1.8 MB, hard limit 1,835,008 bytes
      8  →  partitions_8mb.csv  — OTA slot 3.0 MB, hard limit 3,080,192 bytes
    Default: 4

.PARAMETER Port
    COM port for flash + monitor (e.g. COM5). Omit to build-only.

.EXAMPLE
    # Build dimmer firmware for ESP32-C3 (4 MB flash)
    .\scripts\build_device.ps1 dimmer esp32c3

.EXAMPLE
    # Build and flash 2-gang switch to COM5 (ESP32, 4 MB flash)
    .\scripts\build_device.ps1 2gang_switch esp32 COM5

.EXAMPLE
    # Build rgb_light for ESP32-S3 with 8 MB flash
    .\scripts\build_device.ps1 rgb_light esp32s3 -FlashMB 8
#>

param(
    [Parameter(Mandatory, HelpMessage="Device name (e.g. dimmer, 2gang_switch)")]
    [ValidateSet("1gang_switch","2gang_switch","3gang_switch","4gang_switch",
                 "dimmer","colour_temp","rgb_light",
                 "temp_sensor","motion_sensor","contact_sensor","thermostat")]
    [string]$Device,

    [ValidateSet("esp32","esp32c3","esp32s3","esp32c6")]
    [string]$Target = "esp32c3",

    [ValidateSet(4, 8)]
    [int]$FlashMB = 4,

    [string]$Port = ""
)

$ErrorActionPreference = "Stop"

# ── OTA slot limits (slot size minus 64 KB safety margin) ────────────────────
# 4 MB: slot = 0x1D0000 (1,900,544 B) — limit = 1,900,544 - 65,536 = 1,835,008 B
# 8 MB: slot = 0x300000 (3,145,728 B) — limit = 3,145,728 - 65,536 = 3,080,192 B
$limitMap = @{ 4 = 1835008; 8 = 3080192 }
$sizeLimit = $limitMap[$FlashMB]

$devicePath  = Join-Path $PSScriptRoot "..\devices\$Device"
$scriptRoot  = $PSScriptRoot
$sizeScript  = Join-Path $scriptRoot "check_binary_size.py"

if (-not (Test-Path $devicePath)) {
    Write-Error "Device folder not found: $devicePath"
    exit 1
}

Write-Host "`n>>> Building: $Device  target: $Target  flash: ${FlashMB}MB" -ForegroundColor Cyan
Push-Location $devicePath

try {
    idf.py -DIDF_TARGET=$Target build
    if ($LASTEXITCODE -ne 0) { throw "idf.py build failed (exit $LASTEXITCODE)" }

    Write-Host "`n>>> Build succeeded: $Device / $Target" -ForegroundColor Green

    # ── Binary size verification ──────────────────────────────────────────────
    $binPath = Join-Path $devicePath "build\dsgv_$Device.bin"
    if (Test-Path $binPath) {
        $sizeKB = [int]((Get-Item $binPath).Length / 1KB)
        Write-Host "    Binary : $binPath  ($sizeKB KB)" -ForegroundColor Green

        Write-Host "`n>>> Size check (limit: $([int]($sizeLimit / 1KB)) KB for ${FlashMB}MB flash)" -ForegroundColor Cyan
        python $sizeScript $binPath $sizeLimit
        if ($LASTEXITCODE -ne 0) {
            throw "Binary size check FAILED. Fix binary size before flashing."
        }
    } else {
        Write-Warning "Binary not found at expected path: $binPath"
        Write-Warning "Size check skipped."
    }

    if ($Port) {
        Write-Host "`n>>> Flashing to $Port ..." -ForegroundColor Cyan
        idf.py -p $Port flash monitor
    }
} finally {
    Pop-Location
}
