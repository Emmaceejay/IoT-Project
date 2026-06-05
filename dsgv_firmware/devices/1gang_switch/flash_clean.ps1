param(
    [string]$Port = "COM3"
)

# Activate ESP-IDF v6.0.1 environment
. "C:\Espressif\tools\Microsoft.v6.0.1.PowerShell_profile.ps1"

# Always run from the device directory regardless of where the script is called from
Set-Location $PSScriptRoot

# Erase entire flash (clears Wi-Fi credentials, MQTT config, all NVS) then flash fresh firmware
idf.py -p $Port erase-flash flash
