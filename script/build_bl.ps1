$ErrorActionPreference = 'Continue'
Set-Location 'C:\Users\a5133422\devbox\704_pes_fota\ota_fw_bootloader\Debug'

# The e2 studio toolchain is not on the interactive PATH; the generated makefile adds it itself.
$gccRoot = Get-ChildItem 'C:\Users\a5133422\AppData\Local\Programs\Renesas\RA' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'toolchains\gcc_arm' } |
    Where-Object { Test-Path $_ } |
    Get-ChildItem -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'bin' } |
    Where-Object { Test-Path (Join-Path $_ 'arm-none-eabi-objdump.exe') } |
    Select-Object -First 1

$objdump = Join-Path $gccRoot 'arm-none-eabi-objdump.exe'
$nm      = Join-Path $gccRoot 'arm-none-eabi-nm.exe'

& make all 2>&1 | Out-File -FilePath 'build_swap.log' -Encoding utf8
Write-Output '===== ERRORS / WARNINGS ====='
Select-String -Path 'build_swap.log' -Pattern 'error|warning|undefined|overflow|will not fit' | ForEach-Object { $_.Line }
Write-Output ''
Write-Output '===== SIZE ====='
Get-Content 'build_swap.log' -Tail 6
Write-Output ''
Write-Output '===== SECTION PLACEMENT (VMA / LMA) ====='
& $objdump -h ota_fw_bootloader.elf 2>&1 |
    Select-String -Pattern 'ram_from_flash|\.text|\.data|\.bss' | ForEach-Object { $_.Line }
Write-Output ''
Write-Output '===== FLASH DRIVER SYMBOLS (expect 0x2000xxxx = RAM) ====='
& $nm -n ota_fw_bootloader.elf 2>&1 |
    Select-String -Pattern 'R_FLASH_HP_(Open|Erase|Write|Close|BlankCheck)$' | ForEach-Object { $_.Line }