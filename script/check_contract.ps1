<#
.SYNOPSIS
    Checks that the application's copy of the OTA contract still matches the bootloader's.

.DESCRIPTION
    The bootloader owns the real definitions:

        ota_fw_bootloader/src/boot_layout.h    flash map
        ota_fw_bootloader/src/boot_mailbox.h   RAM handshake

    The application deliberately does NOT include those - it would drag the whole boot record, swap engine and image
    validation into a project that has no business seeing them. Instead the OTA module carries its own copy:

        src/rs_ota_fw_update_over_ble/src/hal/rs_ota_fw_update_over_ble_boot.h          slot geometry
        src/rs_ota_fw_update_over_ble/src/hal/rs_ota_fw_update_over_ble_deps.h          staging window
        src/rs_ota_fw_update_over_ble/src/hal/rs_ota_fw_update_over_ble_boot_rsboot.c   mailbox layout

    That is a copy, and copies drift. Drift here is expensive AND SILENT: a mismatched mailbox address or magic means
    the bootloader ignores every request, which is indistinguishable from "the swap never happened". A mismatched slot
    address means an image is downloaded to the wrong place. This script compares the two sides and fails loudly.

    NOTE ON NAMES: the application does not reuse the bootloader's identifiers. The module has its own public names
    (BOOT_PRIMARY_BASE, RS_OTA_..._CFG_STAGE_ADDR) and its back-end prefixes its private copies with RSBOOT_. The map
    below records which name on each side means the same thing, so a rename on either side shows up here rather than
    at run time.

    Swap types are a special case: the module numbers them TEST=1/PERM=2 and the bootloader PERM=1/TEST=2. That is
    deliberate and the back-end translates. What must match is the back-end's RSBOOT_SWAP_* copies, which is what is
    checked here.

    Run it after changing either side. It needs no hardware.

.EXAMPLE
    .\check_contract.ps1
#>

[CmdletBinding()]
param(
    [string] $BootloaderSrc,
    [string] $AppRoot
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably bound inside a param() default on Windows PowerShell 5.1, so resolve here.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $BootloaderSrc) { $BootloaderSrc = Join-Path $here '..\src' }
if (-not $AppRoot)       { $AppRoot       = Join-Path $here '..\..\rs_fota_da14531evz' }

$AppHal = Join-Path $AppRoot 'src\rs_ota_fw_update_over_ble\src\hal'

# ---------------------------------------------------------------------------------------------------- helpers

<#
    Pulls a value out of C source, accepting either form:

        #define NAME    (0x1234UL)      -> macro
        NAME = 3,                       -> enumerator

    Returns a [uint32], or $null when the name is absent.
#>
function Get-CValue([string] $Text, [string] $Name) {
    $m = [regex]::Match($Text, "(?m)^\s*#\s*define\s+$Name\s+\(?\s*(0[xX][0-9a-fA-F]+|\d+)")
    if (-not $m.Success) {
        $m = [regex]::Match($Text, "(?m)^\s*$Name\s*=\s*\(?\s*(0[xX][0-9a-fA-F]+|\d+)")
    }
    if (-not $m.Success) { return $null }

    $raw = $m.Groups[1].Value
    if ($raw -like '0x*' -or $raw -like '0X*') { return [uint32] ('0x' + $raw.Substring(2)) }
    return [uint32] $raw
}

function Read-Source([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "missing source file: $Path" }
    return (Get-Content -LiteralPath $Path -Raw)
}

$script:Failures = 0

function Compare-Value([string] $Label, $Expected, $Actual) {
    if ($null -eq $Expected) {
        Write-Host ("  {0,-44} NOT FOUND in the bootloader" -f $Label) -ForegroundColor Red
        $script:Failures++
        return
    }
    if ($null -eq $Actual) {
        Write-Host ("  {0,-44} NOT FOUND in the application" -f $Label) -ForegroundColor Red
        $script:Failures++
        return
    }
    if ($Expected -eq $Actual) {
        Write-Host ("  {0,-44} 0x{1:X8}  ok" -f $Label, $Expected) -ForegroundColor DarkGray
    }
    else {
        Write-Host ("  {0,-44} bootloader 0x{1:X8} != application 0x{2:X8}  MISMATCH" -f $Label, $Expected, $Actual) `
            -ForegroundColor Red
        $script:Failures++
    }
}

<# Compares a bootloader name against the application's name for the same thing. #>
function Compare-Pair([string] $BlName, [string] $AppName) {
    $label = if ($BlName -eq $AppName) { $BlName } else { "$BlName -> $AppName" }
    Compare-Value $label (Get-CValue $script:blSide $BlName) (Get-CValue $script:appSide $AppName)
}

# ---------------------------------------------------------------------------------------------------- load

$layout  = Read-Source (Join-Path $BootloaderSrc 'boot_layout.h')
$mailbox = Read-Source (Join-Path $BootloaderSrc 'boot_mailbox.h')

$bootH   = Read-Source (Join-Path $AppHal 'rs_ota_fw_update_over_ble_boot.h')
$depsH   = Read-Source (Join-Path $AppHal 'rs_ota_fw_update_over_ble_deps.h')
$rsbootC = Read-Source (Join-Path $AppHal 'rs_ota_fw_update_over_ble_boot_rsboot.c')

# Each side spans several files; concatenating keeps the lookup simple and still catches a name that moved between
# files, which is a refactor rather than a contract change.
$script:blSide  = $layout + "`n" + $mailbox
$script:appSide = $bootH  + "`n" + $depsH + "`n" + $rsbootC

Write-Host ''
Write-Host 'OTA contract check - bootloader (master) vs ra6e2_da14531ebz_v2 (copy)' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------------------------------------------- compare

Write-Host 'flash map'
Compare-Pair 'BOOT_PRIMARY_BASE'     'BOOT_PRIMARY_BASE'
Compare-Pair 'BOOT_PRIMARY_SIZE'     'BOOT_PRIMARY_SIZE'
Compare-Pair 'BOOT_SECONDARY_BASE'   'RS_OTA_FW_UPDATE_OVER_BLE_CFG_STAGE_ADDR'
Compare-Pair 'BOOT_SECONDARY_SIZE'   'RS_OTA_FW_UPDATE_OVER_BLE_CFG_STAGE_SIZE'
Compare-Pair 'BOOT_SLOT_SECTOR_SIZE' 'RS_OTA_FW_UPDATE_OVER_BLE_CFG_ERASE_BLOCK_SIZE'

Write-Host ''
Write-Host 'mailbox'
Compare-Pair 'BOOT_RAM_BASE'        'RSBOOT_RAM_BASE'
Compare-Pair 'BOOT_RAM_SIZE'        'RSBOOT_RAM_SIZE'
Compare-Pair 'BOOT_MAILBOX_RESERVE' 'RSBOOT_MAILBOX_RESERVE'
Compare-Pair 'BOOT_MAILBOX_MAGIC'   'RSBOOT_MAILBOX_MAGIC'
Compare-Pair 'BOOT_ACK_MAGIC'       'RSBOOT_ACK_MAGIC'

Write-Host ''
Write-Host 'commands and swap types (as the back-end sends them)'
Compare-Pair 'BOOT_CMD_SWAP'       'RSBOOT_CMD_SWAP'
Compare-Pair 'BOOT_CMD_CONFIRM'    'RSBOOT_CMD_CONFIRM'
Compare-Pair 'BOOT_SWAP_TYPE_PERM' 'RSBOOT_SWAP_PERM'
Compare-Pair 'BOOT_SWAP_TYPE_TEST' 'RSBOOT_SWAP_TEST'

Write-Host ''
Write-Host 'status codes'
foreach ($name in 'BOOT_STATUS_OK', 'BOOT_STATUS_SWAPPED', 'BOOT_STATUS_CONFIRMED', 'BOOT_STATUS_REVERTED',
                  'BOOT_STATUS_ERR_IMAGE', 'BOOT_STATUS_ERR_WRITE', 'BOOT_STATUS_ERR_REQUEST',
                  'BOOT_STATUS_ERR_SWAP', 'BOOT_STATUS_ERR_CRC') {
    Compare-Pair $name ($name -replace '^BOOT_', 'RSBOOT_')
}

# ---------------------------------------------------------------------------------------------------- structure

Write-Host ''
Write-Host 'mailbox structure'

<#
    The two struct definitions must agree field for field, because the bootloader writes the acknowledge half and the
    application reads it. Comparing the field NAMES in order catches a reordering or a size change, which a value
    comparison cannot see.
#>
function Get-StructFields([string] $Text, [string] $Tag, [string] $TypeName) {
    $m = [regex]::Match($Text, "(?s)typedef\s+struct\s+$Tag\s*\{(.*?)\}\s*$TypeName\s*;")
    if (-not $m.Success) { return $null }

    $body = $m.Groups[1].Value -replace '(?s)/\*.*?\*/', '' -replace '(?m)//.*$', ''

    return ([regex]::Matches($body, '(?m)^\s*(?:const\s+)?\w+\s+(\w+)\s*(\[\s*\d+\s*\])?\s*;') |
        ForEach-Object { $_.Groups[1].Value + $_.Groups[2].Value }) -join ','
}

$blFields  = Get-StructFields $mailbox 'st_boot_mailbox'   'boot_mailbox_t'
$appFields = Get-StructFields $rsbootC 'st_rsboot_mailbox' 'rsboot_mailbox_t'

if (-not $blFields) {
    Write-Host '  could not parse boot_mailbox_t in the bootloader' -ForegroundColor Red
    $script:Failures++
}
elseif (-not $appFields) {
    Write-Host '  could not parse rsboot_mailbox_t in the application' -ForegroundColor Red
    $script:Failures++
}
elseif ($blFields -eq $appFields) {
    Write-Host "  fields match: $blFields" -ForegroundColor DarkGray
}
else {
    Write-Host '  MISMATCH' -ForegroundColor Red
    Write-Host "    bootloader : $blFields"  -ForegroundColor Red
    Write-Host "    application: $appFields" -ForegroundColor Red
    $script:Failures++
}

# ---------------------------------------------------------------------------------------------------- linker

Write-Host ''
Write-Host 'linker RAM reserve'

<#
    Both linker scripts must carve the SAME number of bytes off the top of RAM, and it must equal
    BOOT_MAILBOX_RESERVE - otherwise the mailbox lands somewhere the linker also handed to .bss or the stack, and
    startup quietly wipes the request. RASC regeneration is what usually breaks this.

    The application uses script/ota.ld rather than the generated script/fsp.ld precisely so that regeneration cannot
    revert the override; if that selection is ever lost, the missing reserve shows up here.
#>
$reserve = Get-CValue $script:blSide 'BOOT_MAILBOX_RESERVE'

foreach ($ld in @((Join-Path $here 'fsp.ld'),
                  (Join-Path $AppRoot 'script\ota.ld'))) {

    $proj  = Split-Path (Split-Path (Split-Path $ld -Parent) -Parent) -Leaf
    $label = "$proj/" + (Split-Path $ld -Leaf)

    if (-not (Test-Path -LiteralPath $ld)) {
        Write-Host ("  {0,-44} MISSING {1}" -f $label, $ld) -ForegroundColor Red
        $script:Failures++
        continue
    }

    $m = [regex]::Match((Get-Content -LiteralPath $ld -Raw), 'RAM_LENGTH\s*=\s*RAM_LENGTH\s*-\s*(0[xX][0-9a-fA-F]+)')

    if (-not $m.Success) {
        Write-Host ("  {0,-44} no 'RAM_LENGTH = RAM_LENGTH - ...' line - mailbox NOT reserved" -f $label) `
            -ForegroundColor Red
        $script:Failures++
    }
    else {
        $v = [uint32] ('0x' + $m.Groups[1].Value.Substring(2))
        Compare-Value $label $reserve $v
    }
}

# ---------------------------------------------------------------------------------------------------- link address

Write-Host ''
Write-Host 'application link address'

<#
    The application must be linked at the primary slot, not at 0 where the bootloader lives. A wrong value still
    links cleanly, so the only symptom is a board that does not come back up.
#>
$otaLd = Join-Path $AppRoot 'script\ota.ld'

if (-not (Test-Path -LiteralPath $otaLd)) {
    Write-Host '  script/ota.ld is missing - the image would link at the bootloader' -ForegroundColor Red
    $script:Failures++
}
else {
    $ldText = Get-Content -LiteralPath $otaLd -Raw
    foreach ($pair in @(@('FLASH_START', 'BOOT_PRIMARY_BASE'), @('FLASH_LENGTH', 'BOOT_PRIMARY_SIZE'))) {
        $m = [regex]::Match($ldText, "(?m)^\s*$($pair[0])\s*=\s*(0[xX][0-9a-fA-F]+)\s*;")
        if (-not $m.Success) {
            Write-Host ("  {0,-44} not set in ota.ld" -f $pair[0]) -ForegroundColor Red
            $script:Failures++
        }
        else {
            $v = [uint32] ('0x' + $m.Groups[1].Value.Substring(2))
            Compare-Value ("ota.ld " + $pair[0] + " == " + $pair[1]) (Get-CValue $script:blSide $pair[1]) $v
        }
    }
}

# ---------------------------------------------------------------------------------------------------- data flash

Write-Host ''
Write-Host 'data flash reservation'

<#
    The bootloader owns the first 128 bytes of data flash (boot record + swap log). The application's VEE instance
    stores BLE bonding data in the same device, and RM_VEE_FLASH_Open() FORMATS whatever window it is given - so a VEE
    window that starts too low erases the boot record on first use, on a board that was working a moment ago.
#>
$needed = [uint32] 0x80          # BOOT_RECORD_SIZE (64) + BOOT_SWAP_LOG_SIZE (64)
$cfg    = Join-Path $AppRoot 'configuration.xml'
$offset = $null                  # stays null if the XML cannot be read, so the cross-check below reports a mismatch

if (-not (Test-Path -LiteralPath $cfg)) {
    Write-Host '  configuration.xml not found - cannot check the VEE window' -ForegroundColor Red
    $script:Failures++
}
else {
    $cfgText = Get-Content -LiteralPath $cfg -Raw
    $m = [regex]::Match($cfgText,
        'rm_vee_flash\.start_addr"\s+value="\(?\s*BSP_FEATURE_FLASH_DATA_FLASH_START\s*(?:\+\s*(0[xX][0-9a-fA-F]+))?')

    if (-not $m.Success) {
        Write-Host '  could not read the VEE start address from configuration.xml' -ForegroundColor Red
        $script:Failures++
    }
    else {
        $offset = if ($m.Groups[1].Success) { [uint32] ('0x' + $m.Groups[1].Value.Substring(2)) } else { [uint32] 0 }

        if ($offset -ge $needed) {
            Write-Host ("  {0,-44} VEE starts at +0x{1:X}, needs >= 0x{2:X}  ok" -f 'vee start offset', $offset,
                $needed) -ForegroundColor DarkGray
        }
        else {
            Write-Host ("  {0,-44} VEE starts at +0x{1:X} and would FORMAT the boot record (needs >= 0x{2:X})" `
                    -f 'vee start offset', $offset, $needed) -ForegroundColor Red
            $script:Failures++
        }
    }
}

<#
    configuration.xml is only the intent. What actually reaches the flash is the generated g_vee_cfg, and the two
    disagree whenever the configuration has been edited but "Generate Project Content" has not been re-run. Checking
    only the XML would report a reservation that the built image does not honour.
#>
$gen = Join-Path $AppRoot 'ra_gen\ble_thread.c'

if (-not (Test-Path -LiteralPath $gen)) {
    Write-Host '  ra_gen\ble_thread.c not found - cannot check the generated VEE window' -ForegroundColor Red
    $script:Failures++
}
else {
    $genText = Get-Content -LiteralPath $gen -Raw
    $g = [regex]::Match($genText,
        '\.start_addr\s*=\s*\(?\s*BSP_FEATURE_FLASH_DATA_FLASH_START\s*(?:\+\s*(0[xX][0-9a-fA-F]+))?')

    if (-not $g.Success) {
        Write-Host '  could not read the VEE start address from ra_gen\ble_thread.c' -ForegroundColor Red
        $script:Failures++
    }
    else {
        $genOffset = if ($g.Groups[1].Success) { [uint32] ('0x' + $g.Groups[1].Value.Substring(2)) } else { [uint32] 0 }

        if ($genOffset -lt $needed) {
            Write-Host ("  {0,-44} generated VEE starts at +0x{1:X} and would FORMAT the boot record" `
                    -f 'vee generated offset', $genOffset) -ForegroundColor Red
            Write-Host '      run "Generate Project Content" in e2 studio to apply configuration.xml' -ForegroundColor Red
            $script:Failures++
        }
        elseif ($genOffset -ne $offset) {
            Write-Host ("  {0,-44} generated +0x{1:X} does not match configuration.xml +0x{2:X}" `
                    -f 'vee generated offset', $genOffset, $offset) -ForegroundColor Red
            $script:Failures++
        }
        else {
            Write-Host ("  {0,-44} generated VEE agrees with configuration.xml  ok" `
                    -f 'vee generated offset') -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------------------------------------------- result

Write-Host ''
if (0 -eq $script:Failures) {
    Write-Host 'contract OK - the application and the bootloader agree' -ForegroundColor Green
    exit 0
}

Write-Host "contract BROKEN - $($script:Failures) mismatch(es)" -ForegroundColor Red
Write-Host "The bootloader is the master. Update the OTA module's src/hal files to match." -ForegroundColor Yellow
exit 1
