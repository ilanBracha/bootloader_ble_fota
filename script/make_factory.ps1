<#
.SYNOPSIS
    Builds the combined "factory" image: bootloader padded up to the IMAGE_0 base, followed by the slot 0 application.

.EXAMPLE
    powershell -File script/make_factory.ps1 -Bootloader Debug/bootloader.bin -App ../ota_fw_app/Debug_Slot0/app_slot0.bin -Base 0x2000 -Out Debug/factory.bin
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Bootloader,
    [Parameter(Mandatory = $false)][string] $App = '',
    [Parameter(Mandatory = $true)][string] $Base,
    [Parameter(Mandatory = $true)][string] $Out
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($App)) {
    Write-Error "No application image given. Build the app project and pass APP0_BIN=<path to app_slot0.bin>."
}

if (-not (Test-Path $Bootloader)) { Write-Error "Bootloader image not found: $Bootloader" }
if (-not (Test-Path $App))        { Write-Error "Application image not found: $App" }

# Accept 0x2000 or 8192.
$slotBase = if ($Base -match '^0[xX]') { [Convert]::ToInt32($Base.Substring(2), 16) } else { [int]$Base }

$blBytes  = [System.IO.File]::ReadAllBytes((Resolve-Path $Bootloader))
$appBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $App))

if ($blBytes.Length -gt $slotBase) {
    Write-Error ("Bootloader is {0} bytes but the IMAGE_0 slot starts at 0x{1:X} - it does not fit." -f $blBytes.Length, $slotBase)
}

# 0xFF padding matches erased flash so the gap is not programmed unnecessarily.
$image = New-Object byte[] ($slotBase + $appBytes.Length)
for ($i = 0; $i -lt $image.Length; $i++) { $image[$i] = 0xFF }

[Array]::Copy($blBytes, 0, $image, 0, $blBytes.Length)
[Array]::Copy($appBytes, 0, $image, $slotBase, $appBytes.Length)

$outFull = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location) $Out }
$outFull = [System.IO.Path]::GetFullPath($outFull)
[System.IO.File]::WriteAllBytes($outFull, $image)

Write-Host ("Created {0}: bootloader {1} bytes + app {2} bytes at 0x{3:X} = {4} bytes total" -f `
        $Out, $blBytes.Length, $appBytes.Length, $slotBase, $image.Length)
