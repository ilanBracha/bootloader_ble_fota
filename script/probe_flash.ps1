<#
.SYNOPSIS
    Read-only snapshot of the boot-critical flash addresses.

.DESCRIPTION
    Answers one question: what will the CPU execute out of reset? Reads the reset vector at 0x0,
    the start of each slot, and the boot record. Never writes, never resets.
#>

. (Join-Path $PSScriptRoot 'jlink_common.ps1')

$exe = Get-JLinkExe

$body = @(
    'mem32 0x0,4'          # reset vector the CPU actually uses
    'mem32 0x4000,4'       # end of the bootloader region
    'mem32 0x10000,4'      # primary slot (where the app now links)
    'mem32 0x28000,4'      # secondary slot
    'mem32 0x8000000,8'    # boot record
)

$out = Invoke-JLink -Body $body -JLinkExe $exe
$map = ConvertFrom-JLinkDump $out

function Show([string] $Label, [uint32] $Addr) {
    $sp = Get-DumpU32 -Map $map -Address $Addr
    $pc = Get-DumpU32 -Map $map -Address ([uint32]($Addr + 4))

    if ($null -eq $sp) { Write-Host ("{0,-18} <unreadable>" -f $Label); return }

    $blank = ($sp -eq 0xFFFFFFFF) -and ($pc -eq 0xFFFFFFFF)
    $note  = if ($blank) { 'ERASED' } else { "initial SP=0x{0:X8}  reset PC=0x{1:X8}" -f $sp, $pc }
    Write-Host ("{0,-18} {1}" -f $Label, $note)
}

Write-Host ''
Show 'vector @ 0x00000'  0x00000000
Show 'vector @ 0x04000'  0x00004000
Show 'primary @ 0x10000' 0x00010000
Show 'secondary @0x28000' 0x00028000
Write-Host ''

$magic = Get-DumpU32 -Map $map -Address 0x08000000
if ($null -ne $magic) { Write-Host ("boot record magic  0x{0:X8}" -f $magic) }
Write-Host ''
