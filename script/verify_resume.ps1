<#
.SYNOPSIS
    Power-cut resume test: interrupts a swap part way through and checks the bootloader finishes it correctly.

.DESCRIPTION
    A swap rewrites 96 KB across 9 erase/program legs. Losing power in the middle must never leave the board
    unbootable or half-swapped: the progress log in data flash records each completed leg, so the next boot
    continues from the first unfinished one.

    For each cut point this script:
      1. Puts the board in a known state (primary 'A', secondary 'B').
      2. Requests a swap, lets it run for N ms, then halts the core mid-exchange.
      3. Records how many legs had completed, to confirm the cut really landed inside the swap.
      4. Resets and lets the bootloader resume.
      5. Checks the swap finished: primary 'B', secondary 'A', all 9 legs logged.
      6. Swaps back, ready for the next cut point.

    Halting the core stops the RAM-resident driver from driving the sequence, which is the closest a debugger
    can get to a power cut. A real brown-out during an erase is harsher, but exercises the same resume path.
#>
[CmdletBinding()]
param(
    [string] $Device = 'R7FA6E2BB',
    [string] $JLinkExe = '',
    # A full 96 KB exchange takes roughly 1.1 s, so the useful cut points are all below that. Anything later
    # just watches a finished swap and proves nothing about resuming.
    [int[]]  $CutPointsMs = @(200, 400, 600, 800, 1000),
    [int]    $SwapMs = 20000
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'jlink_common.ps1')

$PRIMARY_BASE   = [uint32] 0x00010000
$SECONDARY_BASE = [uint32] 0x00028000
$LOG_ADDR       = [uint32] 0x08000040
$SWAP_STEPS     = 9
$LOG_TAG        = [uint32] 0xA5A50000L

$MAILBOX        = [uint32] 0x20009FE0
$MAILBOX_MAGIC  = [uint32] 0x51524F42
$ACK_MAGIC      = [uint32] 0x4B434142
$CMD_SWAP       = 1
$SWAP_TYPE_PERM = 1
$STATUS_SWAPPED = 2

$bootBin = Join-Path $scriptDir '..\Debug\bootloader.bin'
$appBin  = Join-Path $scriptDir '..\..\ota_fw_app_ra6e2\Debug\app.bin'

$jlink     = Get-JLinkExe $JLinkExe
$tagOffset = Get-BuildTagOffset $appBin

$reads = @(
    @{ Address = [uint32]($PRIMARY_BASE + $tagOffset);   Count = 1 },
    @{ Address = [uint32]($SECONDARY_BASE + $tagOffset); Count = 1 },
    @{ Address = $MAILBOX;                               Count = 32 },
    @{ Address = $LOG_ADDR;                              Count = 64 }
)

$pass = 0
$fail = 0

function Check([string] $Name, $Actual, $Expected) {
    if ("$Actual" -eq "$Expected") {
        Write-Host ("    {0,-30} {1,-10} PASS" -f $Name, $Actual)
        $script:pass++
    } else {
        Write-Host ("    {0,-30} {1,-10} FAIL (expected {2})" -f $Name, $Actual, $Expected) -ForegroundColor Red
        $script:fail++
    }
}

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

function Add-Reads([string[]] $Body) {
    foreach ($r in $reads) {
        $Body += ("mem8 0x{0:X}, 0x{1:X}" -f [uint32]$r.Address, [int]$r.Count)
    }
    return $Body
}

function Get-MailboxWrite() {
    $check = [uint32] ([uint32]$MAILBOX_MAGIC -bxor [uint32]0xA5A5A5A5L -bxor [uint32]($CMD_SWAP -shl 8) -bxor [uint32]$SWAP_TYPE_PERM)

    return @(
        'h',
        ("w1 0x{0:X}, 0x{1:X}" -f ($MAILBOX + 4), $CMD_SWAP),
        ("w1 0x{0:X}, 0x{1:X}" -f ($MAILBOX + 5), $SWAP_TYPE_PERM),
        ("w1 0x{0:X}, 0" -f ($MAILBOX + 6)),
        ("w1 0x{0:X}, 0" -f ($MAILBOX + 7)),
        ("w4 0x{0:X}, 0x{1:X}" -f ($MAILBOX + 8), $check),
        ("w4 0x{0:X}, 0x{1:X}" -f $MAILBOX, $MAILBOX_MAGIC)
    )
}

# Full swap, used only when a test wants a second exchange.
function Invoke-FullSwap() {
    $body = Get-MailboxWrite
    $body += @('r', 'g', "sleep $SwapMs", 'h')
    return ConvertFrom-JLinkDump (Invoke-JLink -Body (Add-Reads $body) -JLinkExe $jlink -Device $Device)
}

<#
    Puts the board back into a pristine, known state: both slots erased and reprogrammed, data flash state
    cleared. Every cut point starts from here.

    This deliberately does NOT restore by swapping back. Interrupting the flash controller can leave a sector
    partially erased, and swapping would carry that damage into the next iteration - which would make later
    failures look like firmware bugs when they are really fallout from the previous test.
#>
function Reset-Board() {
    Invoke-JLink -Body @('h', 'erase 0x08000000 0x08000080', 'erase 0x8000 0x40000') -JLinkExe $jlink -Device $Device | Out-Null
    & (Join-Path $scriptDir 'flash.ps1') -Bootloader $bootBin -App $appBin -Device $Device -JLinkExe $jlink | Out-Null
    & (Join-Path $scriptDir 'stage_secondary.ps1') -App $appBin -Tag 'B' -Device $Device -JLinkExe $jlink | Out-Null
}

Write-Host '--- baseline: clean install (primary A, secondary B) ---'

Reset-Board

$m = Invoke-BootAndRead -Reads $reads -RunMs 2000 -JLinkExe $jlink -Device $Device
Check 'primary' (Get-Tag $m $PRIMARY_BASE) 'A'
Check 'secondary' (Get-Tag $m $SECONDARY_BASE) 'B'
Write-Host ''

foreach ($cut in $CutPointsMs) {
    Write-Host "--- cut the swap after ${cut}ms ---"

    # Start the swap, halt part way through, then RESET before the session ends.
    #
    # The reset is essential: halting the core mid-exchange leaves the flash controller in P/E mode, where
    # code flash cannot be read. Disconnecting in that state hangs the next J-Link connect. A reset takes the
    # FCU out of P/E mode and leaves the core halted at the reset vector - as close to a power cut as a
    # debugger can get - after which the data flash log is readable.
    $body = Get-MailboxWrite
    $body += @('r', 'g', "sleep $cut", 'h', 'r')
    $body += ("mem8 0x{0:X}, 0x{1:X}" -f $LOG_ADDR, 64)
    $mid   = ConvertFrom-JLinkDump (Invoke-JLink -Body $body -JLinkExe $jlink -Device $Device)

    $midLegs = Get-SwapLegs $mid
    Write-Host ("    interrupted with {0}/{1} legs done" -f $midLegs, $SWAP_STEPS)

    if ($midLegs -eq $SWAP_STEPS) {
        Write-Host '    (swap had already finished - cut point too late to test resume)' -ForegroundColor Yellow
    }

    # Reset and let the bootloader resume from the log.
    $m = Invoke-BootAndRead -Reads $reads -RunMs $SwapMs -JLinkExe $jlink -Device $Device

    Check 'resumed: primary' (Get-Tag $m $PRIMARY_BASE) 'B'
    Check 'resumed: secondary' (Get-Tag $m $SECONDARY_BASE) 'A'
    Check 'resumed: legs logged' (Get-SwapLegs $m) $SWAP_STEPS

    # Start the next cut point from a pristine board rather than from whatever this one left behind.
    Reset-Board
    Write-Host ''
}

Write-Host ("===== {0} passed, {1} failed =====" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
