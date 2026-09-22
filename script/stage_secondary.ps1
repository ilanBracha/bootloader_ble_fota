<#
.SYNOPSIS
    Stages an application image into the SECONDARY slot, patching its build tag so the swap is provable.

.DESCRIPTION
    Both images are built from identical source, so a byte-identical copy would make a successful swap
    invisible. This script rewrites the APP_BUILD_TAG_PREFIX string inside a copy of the .bin before
    programming it, which changes the CLI 'info' output and the LED blink rate of the staged image.

    This stands in for what the real application will do over the air. The demo application deliberately
    has no code flash driver, so staging is done here over J-Link instead.

.EXAMPLE
    powershell -File script/stage_secondary.ps1 -App ..\ota_fw_app_ra6e2\Debug\app.bin -Tag B
#>
[CmdletBinding()]
param(
    [string] $App = '..\ota_fw_app_ra6e2\Debug\app.bin',
    [ValidatePattern('^[A-Z0-9]$')]
    [string] $Tag = 'B',
    [string] $SecondaryBase = '0x28000',
    [string] $Device = 'R7FA6E2BB',
    [string] $JLinkExe = ''
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not [System.IO.Path]::IsPathRooted($App)) {
    $App = Join-Path $scriptDir $App
}

if (-not (Test-Path $App)) {
    Write-Error "Application image not found: $App"
}

$bytes  = [System.IO.File]::ReadAllBytes($App)
$prefix = [System.Text.Encoding]::ASCII.GetBytes('OTA-BUILD:')

# Locate the build tag inside the raw image.
$offset = -1
for ($i = 0; $i -le ($bytes.Length - $prefix.Length - 1); $i++) {
    $match = $true
    for ($j = 0; $j -lt $prefix.Length; $j++) {
        if ($bytes[$i + $j] -ne $prefix[$j]) { $match = $false; break }
    }
    if ($match) { $offset = $i; break }
}

if ($offset -lt 0) {
    Write-Error "Build tag '$([System.Text.Encoding]::ASCII.GetString($prefix))' not found in $App - is app_build.c linked in?"
}

$tagOffset = $offset + $prefix.Length
$original  = [char] $bytes[$tagOffset]
$bytes[$tagOffset] = [byte][char] $Tag

$staged = Join-Path ([System.IO.Path]::GetDirectoryName($App)) ("staged_{0}.bin" -f $Tag)
[System.IO.File]::WriteAllBytes($staged, $bytes)

Write-Host ("build tag at image offset 0x{0:X}: '{1}' -> '{2}'" -f $tagOffset, $original, $Tag)
Write-Host "staged image: $staged"

& (Join-Path $scriptDir 'flash.ps1') -Secondary $staged -SecondaryBase $SecondaryBase -Device $Device -JLinkExe $JLinkExe
