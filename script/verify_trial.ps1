<#
.SYNOPSIS
    Hardware test for trial boot, automatic revert and confirm (phase 2).

.DESCRIPTION
    A permanent swap is easy to trust because it is irreversible. A TRIAL swap is the interesting one: the
    new image is installed but put on probation, and it only becomes permanent if it says so. This script
    proves both outcomes on real silicon, over J-Link only, so it does not need the VCOM port.

      1. Clean install: bootloader + application (tag 'A') in the primary slot, state and secondary erased.
      2. Stage a patched image (tag 'B') into the secondary slot.
      3. TRIAL swap. Expect primary = B, secondary = A, and the record left ON TRIAL
         (swap_type = REVERT, copy_done = 1, image_ok = 0).
      4. Reset WITHOUT confirming - this stands in for a crash, a watchdog reset or a user power cycle.
         Expect the bootloader to swap A back in by itself and report REVERTED.
      5. TRIAL swap again, then CONFIRM. Expect the record cleared and B kept.
      6. Reset again. Expect B to stay put - a confirmed image is never reverted.

    Steps 4 and 6 are the two halves of the same question, and they must not agree: if the board reverts in
    both, confirm does nothing; if it reverts in neither, the trial mechanism does nothing.

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

# boot_record_t field offsets
$REC_SWAP_TYPE  = 5
$REC_COPY_DONE  = 6
$REC_IMAGE_OK   = 7

$MAILBOX        = [uint32] 0x20009FE0
$MAILBOX_MAGIC  = [uint32] 0x51524F42
$ACK_MAGIC      = [uint32] 0x4B434142

$CMD_SWAP       = 1
$CMD_CONFIRM    = 2

$SWAP_TYPE_NONE = 0
$SWAP_TYPE_PERM = 1
$SWAP_TYPE_TEST = 2
$SWAP_TYPE_REV  = 3

$STATUS_OK        = 1
$STATUS_SWAPPED   = 2
$STATUS_CONFIRMED = 3
$STATUS_REVERTED  = 4

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

function Get-RecordField([hashtable] $Map, [int] $Offset) {
    $b = Get-DumpBytes -Map $Map -Address ([uint32]($RECORD_ADDR + $Offset)) -Count 1
    if ($null -eq $b) { return '?' }
    return [int] $b[0]
}

<#
    Writes a mailbox request, then resets, runs, waits and reads - all in one session. SRAM survives the
    reset, which is how the request reaches the bootloader; this is exactly what the application's
    boot_request_*_and_reset() functions do.
#>
function Invoke-RequestAndRead([int] $Command, [int] $Arg, [int] $WaitMs) {
    $check = [uint32] ([uint32]$MAILBOX_MAGIC -bxor [uint32]0xA5A5A5A5L -bxor [uint32]($Command -shl 8) -bxor [uint32]$Arg)

    $body = @(
        'h',
        ("w1 0x{0:X}, 0x{1:X}" -f ($MAILBOX + 4), $Command),
        ("w1 0x{0:X}, 0x{1:X}" -f ($MAILBOX + 5), $Arg),
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
Check 'bootloader ack' (Get-AckStatus $m) $STATUS_OK
Write-Host ''

# ------------------------------------------------------------------------------------ 2. stage image B
Write-Host '--- 2. stage image B into the secondary slot ---'

& (Join-Path $scriptDir 'stage_secondary.ps1') -App $appBin -Tag 'B' -Device $Device -JLinkExe $jlink | Out-Null

$m = Invoke-BootAndRead -Reads $reads -RunMs 2000 -JLinkExe $jlink -Device $Device

Check 'primary still A' (Get-Tag $m $PRIMARY_BASE) 'A'
Check 'secondary staged B' (Get-Tag $m $SECONDARY_BASE) 'B'
Write-Host ''

# ------------------------------------------------------------------------------------ 3. trial swap
Write-Host "--- 3. TRIAL swap (96 KB exchange, allowing $($SwapMs)ms) ---"

$m = Invoke-RequestAndRead $CMD_SWAP $SWAP_TYPE_TEST $SwapMs

Check 'primary now B' (Get-Tag $m $PRIMARY_BASE) 'B'
Check 'secondary now A' (Get-Tag $m $SECONDARY_BASE) 'A'
Check 'bootloader ack' (Get-AckStatus $m) $STATUS_SWAPPED
Check 'record swap_type = REVERT' (Get-RecordField $m $REC_SWAP_TYPE) $SWAP_TYPE_REV
Check 'record copy_done' (Get-RecordField $m $REC_COPY_DONE) 1
Check 'record image_ok (on trial)' (Get-RecordField $m $REC_IMAGE_OK) 0
Write-Host ''

# ------------------------------------------------------------------------------------ 4. revert
Write-Host "--- 4. reset WITHOUT confirming - the bootloader must roll back by itself ---"

$m = Invoke-BootAndRead -Reads $reads -RunMs $SwapMs -JLinkExe $jlink -Device $Device

Check 'primary back to A' (Get-Tag $m $PRIMARY_BASE) 'A'
Check 'secondary back to B' (Get-Tag $m $SECONDARY_BASE) 'B'
Check 'bootloader ack' (Get-AckStatus $m) $STATUS_REVERTED
Check 'record swap_type cleared' (Get-RecordField $m $REC_SWAP_TYPE) $SWAP_TYPE_NONE
Check 'record image_ok' (Get-RecordField $m $REC_IMAGE_OK) 1
Write-Host ''

# ------------------------------------------------------------- 5. trial swap again, this time confirm it
Write-Host "--- 5. TRIAL swap again, then confirm ---"

$m = Invoke-RequestAndRead $CMD_SWAP $SWAP_TYPE_TEST $SwapMs

Check 'primary now B' (Get-Tag $m $PRIMARY_BASE) 'B'
Check 'record image_ok (on trial)' (Get-RecordField $m $REC_IMAGE_OK) 0

$m = Invoke-RequestAndRead $CMD_CONFIRM 0 5000

Check 'primary still B after confirm' (Get-Tag $m $PRIMARY_BASE) 'B'
Check 'bootloader ack' (Get-AckStatus $m) $STATUS_CONFIRMED
Check 'record swap_type cleared' (Get-RecordField $m $REC_SWAP_TYPE) $SWAP_TYPE_NONE
Check 'record image_ok' (Get-RecordField $m $REC_IMAGE_OK) 1
Write-Host ''

# ------------------------------------------------------------------------- 6. a confirmed image stays put
Write-Host '--- 6. reset again - a confirmed image must NOT be reverted ---'

$m = Invoke-BootAndRead -Reads $reads -RunMs 3000 -JLinkExe $jlink -Device $Device

Check 'primary still B' (Get-Tag $m $PRIMARY_BASE) 'B'
Check 'secondary still A' (Get-Tag $m $SECONDARY_BASE) 'A'
Check 'bootloader ack' (Get-AckStatus $m) $STATUS_OK
Write-Host ''

# --------------------------------------------------------------------- restore the board to a known state
Write-Host '--- restoring the board (permanent swap back to A) ---'

$m = Invoke-RequestAndRead $CMD_SWAP $SWAP_TYPE_PERM $SwapMs

Check 'primary restored to A' (Get-Tag $m $PRIMARY_BASE) 'A'
Check 'record swap_type cleared' (Get-RecordField $m $REC_SWAP_TYPE) $SWAP_TYPE_NONE
Write-Host ''

Write-Host ("===== {0} passed, {1} failed =====" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
