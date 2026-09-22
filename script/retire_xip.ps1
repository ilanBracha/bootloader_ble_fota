# Retires the artefacts of the old direct-XIP (two-slot) design.
#
# The application is now linked once at the primary slot base, so the per-slot build configurations and the
# slot-oriented verification scripts no longer describe the system. Anything removed here is reconstructible
# from git history.

$ErrorActionPreference = 'Stop'

$app  = 'C:\Users\a5133422\devbox\704_pes_fota\ota_fw_app_ra6e2'
$boot = 'C:\Users\a5133422\devbox\704_pes_fota\ota_fw_bootloader'

$removed = @()

foreach ($dir in @("$app\Debug_Slot0", "$app\Debug_Slot1")) {
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force
        $removed += $dir
    }
}

# Slot-based tooling superseded by stage_secondary.ps1 / verify_swap.ps1.
$obsolete = @(
    "$boot\script\boot_slot.ps1",
    "$boot\script\verify_boot.ps1",
    "$boot\script\verify_mailbox.ps1",
    "$boot\script\verify_misplaced.ps1",
    "$boot\script\verify_reject.ps1",
    "$boot\script\make_record.ps1"
)

foreach ($file in $obsolete) {
    if (Test-Path $file) {
        Remove-Item $file -Force
        $removed += $file
    }
}

# Stale build outputs from the old layout.
foreach ($pattern in @("$boot\Debug\boot_record_slot*.bin", "$boot\Debug\factory.bin", "$boot\Debug\*.log")) {
    Get-ChildItem $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force
        $script:removed += $_.FullName
    }
}

if ($removed.Count -eq 0) {
    Write-Output 'nothing to remove'
} else {
    $removed | ForEach-Object { Write-Output "removed $_" }
}
