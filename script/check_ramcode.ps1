$gccRoot = Get-ChildItem 'C:\Users\a5133422\AppData\Local\Programs\Renesas\RA' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'toolchains\gcc_arm' } |
    Where-Object { Test-Path $_ } |
    Get-ChildItem -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'bin' } |
    Where-Object { Test-Path (Join-Path $_ 'arm-none-eabi-nm.exe') } |
    Select-Object -First 1
$nm = Join-Path $gccRoot 'arm-none-eabi-nm.exe'

Set-Location 'C:\Users\a5133422\devbox\704_pes_fota\ota_fw_bootloader\Debug'

Write-Output '===== CODE EXECUTING FROM RAM (0x2000xxxx, type t/T) ====='
& $nm -n ota_fw_bootloader.elf |
    Where-Object { $_ -match '^2000[0-9a-f]{4}\s+[tT]\s' } |
    ForEach-Object { $_ }
