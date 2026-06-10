param(
    [string]$Port   = "COM3",
    [string]$Target = "esp32c3",
    [switch]$NoErase
)

# Activate ESP-IDF v6.0.1 environment
. "C:\Espressif\tools\Microsoft.v6.0.1.PowerShell_profile.ps1"

Set-Location $PSScriptRoot

# If the build directory exists but targets a different chip, wipe it so
# CMake re-configures cleanly. Mixing targets corrupts the build.
$cacheFile = "build\CMakeCache.txt"
if (Test-Path $cacheFile) {
    $cachedTarget = Select-String -Path $cacheFile -Pattern "^IDF_TARGET:STRING=(.+)" |
                    ForEach-Object { $_.Matches[0].Groups[1].Value }
    if ($cachedTarget -and $cachedTarget -ne $Target) {
        Write-Host "[flash] Target mismatch: cache=$cachedTarget requested=$Target — wiping build dir." -ForegroundColor Yellow
        Remove-Item -Recurse -Force build
    }
}

if ($NoErase) {
    Write-Host "[flash] Building and flashing to $Port (retaining NVS)..." -ForegroundColor Yellow
    idf.py -DIDF_TARGET=$Target -p $Port flash
} else {
    Write-Host "[flash] Erasing flash then building and flashing to $Port (clean slate)..." -ForegroundColor Cyan
    idf.py -DIDF_TARGET=$Target -p $Port erase-flash flash
}
