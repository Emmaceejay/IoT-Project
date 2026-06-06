param(
    [string]$Port = "COM3",
    [switch]$NoErase
)

# Activate ESP-IDF v6.0.1 environment
. "C:\Espressif\tools\Microsoft.v6.0.1.PowerShell_profile.ps1"

Set-Location $PSScriptRoot

if ($NoErase) {
    Write-Host "[flash] Flashing without erase (retaining NVS credentials)..." -ForegroundColor Yellow
    idf.py -p $Port flash
} else {
    Write-Host "[flash] Erasing entire flash then flashing (clean slate)..." -ForegroundColor Cyan
    idf.py -p $Port erase-flash flash
}
