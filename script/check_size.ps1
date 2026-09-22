<#
.SYNOPSIS
    Fails the build if an image is larger than the flash region reserved for it.

    Used as a post-build guard for the bootloader: it also catches a script/fsp.ld that lost its
    FLASH_LENGTH override, which "Generate Project Content" removes on every regeneration.

.EXAMPLE
    powershell -File script/check_size.ps1 -Image Debug/bootloader.bin -Limit 0x2000 -Name bootloader
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Image,
    [Parameter(Mandatory = $true)][string] $Limit,
    [string] $Name = 'image'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Image)) { Write-Error "Image not found: $Image" }

$max    = if ($Limit -match '^0[xX]') { [Convert]::ToInt32($Limit.Substring(2), 16) } else { [int] $Limit }
$length = (Get-Item $Image).Length

if ($length -gt $max) {
    Write-Error ("{0} is {1} bytes, which exceeds its {2} byte region. Check the FLASH_LENGTH override in script/fsp.ld." -f `
            $Name, $length, $max)
    exit 1
}

Write-Host ("{0}: {1} of {2} bytes used ({3:N1}%)" -f $Name, $length, $max, (100.0 * $length / $max))
