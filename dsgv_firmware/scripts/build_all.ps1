<#
.SYNOPSIS
    Build all 11 DSGV device SKUs for a given chip target.

.PARAMETER Target
    IDF chip target. One of: esp32, esp32c3, esp32s3, esp32c6   (default: esp32c3)

.PARAMETER FlashMB
    Flash size of the target hardware in megabytes. Passed to build_device.ps1
    for the binary size check after each build.
      4  →  partitions_4mb.csv  — hard limit 1,835,008 bytes per OTA slot
      8  →  partitions_8mb.csv  — hard limit 3,080,192 bytes per OTA slot
    Default: 4

.PARAMETER ContinueOnError
    If set, a single device build failure does not abort the entire run.

.EXAMPLE
    # Build every device for ESP32-C3 (4 MB flash)
    .\scripts\build_all.ps1 esp32c3

.EXAMPLE
    # Build every device for ESP32-S3 with 8 MB flash, keep going if one fails
    .\scripts\build_all.ps1 esp32s3 -FlashMB 8 -ContinueOnError
#>

param(
    [ValidateSet("esp32","esp32c3","esp32s3","esp32c6")]
    [string]$Target = "esp32c3",

    [ValidateSet(4, 8)]
    [int]$FlashMB = 4,

    [switch]$ContinueOnError
)

$ErrorActionPreference = if ($ContinueOnError) { "Continue" } else { "Stop" }

$devices = @(
    "1gang_switch","2gang_switch","3gang_switch","4gang_switch",
    "dimmer","colour_temp","rgb_light",
    "temp_sensor","motion_sensor","contact_sensor","thermostat"
)

$pass   = @()
$fail   = @()
$script = Join-Path $PSScriptRoot "build_device.ps1"

foreach ($d in $devices) {
    Write-Host "`n========================================" -ForegroundColor DarkGray
    Write-Host " Building: $d  ($Target  ${FlashMB}MB)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor DarkGray
    & $script -Device $d -Target $Target -FlashMB $FlashMB
    if ($LASTEXITCODE -eq 0) { $pass += $d } else { $fail += $d }
}

Write-Host "`n======== Build Summary ($Target  ${FlashMB}MB) ========" -ForegroundColor DarkGray
$pass | ForEach-Object { Write-Host "  PASS  $_" -ForegroundColor Green }
$fail | ForEach-Object { Write-Host "  FAIL  $_" -ForegroundColor Red   }
Write-Host "Passed: $($pass.Count)  Failed: $($fail.Count)"
if ($fail.Count -gt 0) { exit 1 }
