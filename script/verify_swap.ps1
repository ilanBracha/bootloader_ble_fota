<#
.SYNOPSIS
    End-to-end hardware test for the scratch swap bootloader.

.DESCRIPTION
    Runs entirely over J-Link, so it does not need the VCOM port (which an open terminal may hold).

      1. Clean install: bootloader + application (build tag 'A') in the primary slot, data flash state
         erased, secondary slot erased.
      2. Check the board boots from the primary slot and reports "nothing staged".
      3. Stage a patched image (build tag 'B') into the secondary slot.
      4. Request a swap through the RAM mailbox and reset - exactly what the CLI 'swap' command does.
      5. Check the primary slot now holds 'B', the secondary holds 'A', the bootloader acknowledged
         SWAPPED, and every swap leg is logged.
      6. Swap back, proving the exchange is symmetric and leaves the board on the original image.

    Every phase resets, runs and reads inside ONE J-Link session: "connect" halts the core, so a separate
    read session would observe a board that never booted.
#>
[CmdletBinding()]
param(
    [string] $Device = 'R7FA6E2BB',
    [string] $JLinkExe = '',
    [int]    $SwapMs = 20000
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'jlink_common.ps1')

# ---------------------------------------------------------------- layout (keep in sync with boot_layout.h)
$PRIMARY_BASE   = [uint32] 0x00010000
$SECONDARY_BASE = [uint32] 0x00028000
$RECORD_ADDR    = [uint32] 0x08000000
$LOG_ADDR       = [uint32] 0x08000040
$SWAP_STEPS     = 9
$LOG_TAG        = [uint32] 0xA5A50000L

$MAILBOX        = [uint32] 0x20009FE0
$MAILBOX_MAGIC  = [uint32] 0x51524F42
$ACK_MAGIC      = [uint32] 0x4B434142
$CMD_SWAP       = 1
$SWAP_TYPE_PERM = 1

$STATUS_OK      = 1
$STATUS_SWAPPED = 2

$bootBin = Join-Path $scriptDir '..\Debug\bootloader.bin'
$appBin  = Join-Path $scriptDir '..\..\ota_fw_app_ra6e2\Debug\app.bin'

foreach ($f in @($bootBin, $appBin)) {
    if (-not (Test-Path $f)) { Write-Error "missing build output: $f (build both projects first)" }
}

$jlink     = Get-JLinkExe $JLinkExe
$tagOffset = Get-BuildTagOffset $appBin

Write-Host ("build tag at image offset 0x{0:X}" -f $tagOffset)
Write-Host ''

$pass = 0
$fail = 0

function Check([string] $Name, $Actual, $Expected) {
    if ("$Actual" -eq "$Expected") {
        Write-Host ("  {0,-34} {1,-12} PASS" -f $Name, $Actual)
        $script:pass++
    } else {
        Write-Host ("  {0,-34} {1,-12} FAIL (expected {2})" -f $Name, $Actual, $Expected) -ForegroundColor Red
        $script:fail++
    }
}

# Everything a phase needs, read in one go.
$reads = @(
    @{ Address = [uint32]($PRIMARY_BASE + $tagOffset);   Count = 1 },
    @{ Address = [uint32]($SECONDARY_BASE + $tagOffset); Count = 1 },
    @{ Address = $MAILBOX;                               Count = 32 },
    @{ Address = $RECORD_ADDR;                           Count = 16 },
    @{ Address = $LOG_ADDR;                              Count = 64 }
)

function Get-Tag([hashtable] $Map, [uint32] $SlotBase) {
    $b = Get-DumpBytes -Map $Map -Address ([uint32]($SlotBase + $tagOffset)) -Count 1
    if ($null -eq $b) { return '?' }
    return [char] $b[0]
}

function Get-AckStatus([hashtable] $Map) {
    $magic = Get-DumpU32 -Map $Map -Address ([uint32]($MAILBOX + 12))
    if ($magic -ne $ACK_MAGIC) { return 'no-ack' }
    $b = Get-DumpBytes -Map $Map -Address ([uint32]($MAILBOX + 16)) -Count 1
    return [int] $b[0]
}

function Get-SwapLegs([hashtable] $Map) {
    $done = 0
    for ($i = 0; $i -lt $SWAP_STEPS; $i++) {
        $v = Get-DumpU32 -Map $Map -Address ([uint32]($LOG_ADDR + ($i * 4)))
        if ($v -eq [uint32]($LOG_TAG -bor [uint32]$i)) { $done++ } else { break }
    }
    return $done
}

<#
    Writes a swap request into the RAM mailbox, then resets, runs, waits and reads - all in one session.
    SRAM survives the reset, which is how the request reaches the bootloader; this is the same mechanism
    boot_request_swap_and_reset() uses from the application.
#>
function Invoke-SwapAndRead([int] $WaitMs) {
    $check = [uint32] ([uint32]$MAILBOX_MAGIC -bxor [uint32]0xA5A5A5A5L -bxor [uint32]($CMD_SWAP -shl 8) -bxor [uint32]$SWAP_TYPE_PERM)

    $body = @(
        'h',
        ("w1 0x{0:X}, 0x{1:X}" -f ($MAILBOX + 4), $CMD_SWAP),
        ("w1 0x{0:X}, 0x{1:X}" -f ($MAILBOX + 5), $SWAP_TYPE_PERM),
        ("w1 0x{0:X}, 0" -f ($MAILBOX + 6)),
        ("w1 0x{0:X}, 0" -f ($MAILBOX + 7)),
        ("w4 0x{0:X}, 0x{1:X}" -f ($MAILBOX + 8), $check),
        ("w4 0x{0:X}, 0x{1:X}" -f $MAILBOX, $MAILBOX_MAGIC),
        'r',
        'g',
        "sleep $WaitMs",
        'h'
    )

    foreach ($r in $reads) {
        $body += ("mem8 0x{0:X}, 0x{1:X}" -f [uint32]$r.Address, [int]$r.Count)
    }

    return ConvertFrom-JLinkDump (Invoke-JLink -Body $body -JLinkExe $jlink -Device $Device)
}

# ------------------------------------------------------------------------------------ 1. clean install
Write-Host '--- 1. clean install: bootloader + app (tag A), state and secondary erased ---'

Invoke-JLink -Body @('h', 'erase 0x08000000 0x08000080', 'erase 0x28000 0x40000') -JLinkExe $jlink -Device $Device | Out-Null
& (Join-Path $scriptDir 'flash.ps1') -Bootloader $bootBin -App $appBin -Device $Device -JLinkExe $jlink | Out-Null

$m = Invoke-BootAndRead -Reads $reads -RunMs 2000 -JLinkExe $jlink -Device $Device

Check 'primary build tag' (Get-Tag $m $PRIMARY_BASE) 'A'
Check 'secondary erased' (Get-Tag $m $SECONDARY_BASE) ([char] 0xFF)
Check 'bootloader ack' (Get-AckStatus $m) $STATUS_OK
Check 'swap legs logged' (Get-SwapLegs $m) 0
Write-Host ''

# ------------------------------------------------------------------------------------ 2. stage image B
Write-Host '--- 2. stage image B into the secondary slot ---'

& (Join-Path $scriptDir 'stage_secondary.ps1') -App $appBin -Tag 'B' -Device $Device -JLinkExe $jlink | Out-Null

$m = Invoke-BootAndRead -Reads $reads -RunMs 2000 -JLinkExe $jlink -Device $Device

Check 'primary still A' (Get-Tag $m $PRIMARY_BASE) 'A'
Check 'secondary staged B' (Get-Tag $m $SECONDARY_BASE) 'B'
Check 'no swap yet' (Get-SwapLegs $m) 0
Write-Host ''

# ------------------------------------------------------------------------------------ 3. swap
Write-Host "--- 3. request swap (96 KB exchange, allowing $($SwapMs)ms) ---"

$m = Invoke-SwapAndRead $SwapMs

Check 'primary now B' (Get-Tag $m $PRIMARY_BASE) 'B'
Check 'secondary now A' (Get-Tag $m $SECONDARY_BASE) 'A'
Check 'bootloader ack' (Get-AckStatus $m) $STATUS_SWAPPED
Check 'swap legs logged' (Get-SwapLegs $m) $SWAP_STEPS
Write-Host ''

# ------------------------------------------------------------------------------------ 4. swap back
Write-Host '--- 4. swap back (restores the original image) ---'

$m = Invoke-SwapAndRead $SwapMs

Check 'primary back to A' (Get-Tag $m $PRIMARY_BASE) 'A'
Check 'secondary back to B' (Get-Tag $m $SECONDARY_BASE) 'B'
Check 'bootloader ack' (Get-AckStatus $m) $STATUS_SWAPPED
Write-Host ''

Write-Host ("===== {0} passed, {1} failed =====" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
