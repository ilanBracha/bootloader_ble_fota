<#
.SYNOPSIS
    Dumps the RAM mailbox, boot record and swap log so the on-target state can be inspected directly.
#>
[CmdletBinding()]
param(
    [string] $Device = 'R7FA6E2BB',
    [string] $JLinkExe = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'jlink_common.ps1')

$jlink = Get-JLinkExe $JLinkExe

$body = @(
    'h',
    'mem8 0x20009FE0, 0x20',
    'mem8 0x08000000, 0x40',
    'mem8 0x08000040, 0x40',
    'mem32 0x10000, 2',
    'mem32 0x28000, 2'
)

$out = Invoke-JLink -Body $body -JLinkExe $jlink -Device $Device
Write-Output $out
