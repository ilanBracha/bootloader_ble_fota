<#
.SYNOPSIS
    Dumps the build tag region of both slots plus the boot record and swap log.
#>
[CmdletBinding()]
param(
    [string] $Device = 'R7FA6E2BB',
    [string] $JLinkExe = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'jlink_common.ps1')

$jlink   = Get-JLinkExe $JLinkExe
$appBin  = Join-Path $scriptDir '..\..\ota_fw_app_ra6e2\Debug\app.bin'
$tagOff  = Get-BuildTagOffset $appBin

# Start of the whole "OTA-BUILD:x" string, not just the letter.
$strOff  = $tagOff - 10

Write-Host ("tag letter offset 0x{0:X}, string offset 0x{1:X}" -f $tagOff, $strOff)

$body = @(
    'h',
    ("mem8 0x{0:X}, 0x20" -f (0x10000 + $strOff)),
    ("mem8 0x{0:X}, 0x20" -f (0x28000 + $strOff)),
    ("mem8 0x{0:X}, 0x20" -f (0x8000  + $strOff)),
    'mem8 0x08000000, 0x20',
    'mem8 0x08000040, 0x28',
    'mem32 0x10000, 2',
    'mem32 0x28000, 2'
)

$out = Invoke-JLink -Body $body -JLinkExe $jlink -Device $Device

foreach ($line in ($out -split "`r?`n")) {
    if ($line -match '^\s*[0-9A-Fa-f]{6,8}\s*=') { Write-Host $line }
}

Write-Host ''
Write-Host 'expected ASCII for the tag region: 4F 54 41 2D 42 55 49 4C 44 3A <letter> 00'
