<#
.SYNOPSIS
    Programs the bootloader / primary slot / secondary slot / boot record with J-Link commander,
    without erasing the other regions.

.EXAMPLE
    # Bootloader only
    powershell -File script/flash.ps1 -Bootloader Debug/bootloader.bin

    # Full first download: bootloader plus the application in the primary slot
    powershell -File script/flash.ps1 -Bootloader Debug/bootloader.bin -App ..\ota_fw_app_ra6e2\Debug\app.bin

    # Stage an image into the secondary slot (see also stage_secondary.ps1, which patches the build tag)
    powershell -File script/flash.ps1 -Secondary ..\ota_fw_app_ra6e2\Debug\app.bin
#>
[CmdletBinding()]
param(
    [string] $Bootloader = '',
    [string] $App = '',
    [string] $AppBase = '0x10000',
    [string] $Secondary = '',
    [string] $SecondaryBase = '0x28000',
    [switch] $EraseState,
    [string] $Device = 'R7FA6E2BB',
    [string] $Interface = 'SWD',
    [int]    $Speed = 4000,
    [string] $JLinkExe = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($JLinkExe)) {
    # Prefer the plain install dir, otherwise the newest versioned one (JLink_Vxxx).
    $candidates = @("C:\Program Files\SEGGER\JLink\JLink.exe", "C:\Program Files (x86)\SEGGER\JLink\JLink.exe") |
        Where-Object { Test-Path $_ }

    if (-not $candidates) {
        $candidates = Get-ChildItem "C:\Program Files*\SEGGER\JLink*\JLink.exe" -ErrorAction SilentlyContinue |
            Sort-Object VersionInfo.FileVersion, Name -Descending |
            ForEach-Object { $_.FullName }
    }

    $JLinkExe = $candidates | Select-Object -First 1
}

if (-not $JLinkExe -or -not (Test-Path $JLinkExe)) {
    Write-Error "JLink.exe not found. Pass -JLinkExe <path>."
}

$lines = @("si $Interface", "speed $Speed", "device $Device", "connect", "r", "h")
$work  = 0

function Add-Image([string] $Path, [string] $Address) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path $Path)) { Write-Error "Image not found: $Path" }
    $full = (Resolve-Path $Path).Path
    $script:lines += "loadbin `"$full`", $Address"
    $script:work++
}

Add-Image $Bootloader '0x0'
Add-Image $App $AppBase
Add-Image $Secondary $SecondaryBase

if ($EraseState) {
    # Boot record (block 0) and swap progress log (block 1). The data flash blocks must be erased explicitly:
    # without it a program step can silently fail. J-Link caches flash contents within a session, so verify
    # from a separate session.
    $lines += 'erase 0x08000000 0x08000080'
    $work++
}

if ($work -eq 0) {
    Write-Error "Nothing to program. Pass -Bootloader, -App, -Secondary and/or -EraseState."
}

$lines += @('r', 'g', 'qc')

$cmdFile = Join-Path $env:TEMP ("ota_flash_{0}.jlink" -f (Get-Date -Format 'yyyyMMddHHmmss'))
$lines | Set-Content -Path $cmdFile -Encoding ASCII

Write-Host "Running $JLinkExe -CommanderScript $cmdFile"

# No -ExitOnError: J-Link can report a spurious "Programming failed @ address 0x2000xxxx" while restoring
# its RAM code after a data flash write. Confirm the result with script/verify_swap.ps1.
& $JLinkExe -AutoConnect 1 -NoGui 1 -CommanderScript $cmdFile