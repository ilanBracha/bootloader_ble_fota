<#
.SYNOPSIS
    Shared J-Link helpers for the OTA verification scripts.

.NOTES
    J-Link's "connect" halts the core, so a fresh session never sees the effect of a boot. Anything that
    depends on the bootloader having run (the RAM mailbox acknowledge, a completed swap) must therefore
    reset, run, wait and read inside a SINGLE commander session - see Invoke-BootAndRead.
#>

function Get-JLinkExe([string] $Explicit = '') {
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }

    $candidates = @("C:\Program Files\SEGGER\JLink\JLink.exe", "C:\Program Files (x86)\SEGGER\JLink\JLink.exe") |
        Where-Object { Test-Path $_ }

    if (-not $candidates) {
        $candidates = Get-ChildItem "C:\Program Files*\SEGGER\JLink*\JLink.exe" -ErrorAction SilentlyContinue |
            Sort-Object VersionInfo.FileVersion, Name -Descending |
            ForEach-Object { $_.FullName }
    }

    $exe = $candidates | Select-Object -First 1
    if (-not $exe) { throw "JLink.exe not found." }
    return $exe
}

<#
    Runs a J-Link commander script and returns its stdout. $Body is an array of commander commands;
    connect/close are added automatically.
#>
function Invoke-JLink {
    param(
        [string[]] $Body,
        [string]   $JLinkExe,
        [string]   $Device = 'R7FA6E2BB',
        [int]      $Speed = 4000
    )

    $lines = @("si SWD", "speed $Speed", "device $Device", "connect") + $Body + @('qc')
    $file  = Join-Path $env:TEMP ("ota_v_{0}.jlink" -f [guid]::NewGuid().ToString('N'))
    $lines | Set-Content -Path $file -Encoding ASCII

    $out = & $JLinkExe -AutoConnect 1 -NoGui 1 -CommanderScript $file 2>&1 | Out-String
    Remove-Item $file -Force -ErrorAction SilentlyContinue
    return $out
}

<#
    Parses every "ADDRESS = XX XX ..." line of J-Link output into a hashtable of address -> byte[].
    Both mem8 and mem32 output is handled; mem32 words are expanded little-endian first.
#>
function ConvertFrom-JLinkDump([string] $Text) {
    $map = @{}

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^\s*([0-9A-Fa-f]{6,8})\s*=\s*(.+?)\s*$') { continue }

        $addr   = [Convert]::ToUInt32($Matches[1], 16)
        $tokens = $Matches[2] -split '\s+'
        $bytes  = New-Object System.Collections.Generic.List[byte]

        foreach ($tok in $tokens) {
            if ($tok -match '^[0-9A-Fa-f]{2}$') {
                $bytes.Add([Convert]::ToByte($tok, 16)) | Out-Null
            } elseif ($tok -match '^[0-9A-Fa-f]{8}$') {
                $w = [Convert]::ToUInt32($tok, 16)
                $bytes.Add([byte]($w -band 0xFF)) | Out-Null
                $bytes.Add([byte](($w -shr 8) -band 0xFF)) | Out-Null
                $bytes.Add([byte](($w -shr 16) -band 0xFF)) | Out-Null
                $bytes.Add([byte](($w -shr 24) -band 0xFF)) | Out-Null
            }
        }

        if ($bytes.Count -gt 0) { $map[$addr] = $bytes.ToArray() }
    }

    return $map
}

<#
    Resets the target, lets it run for $RunMs, halts it and performs the requested reads - all in one
    session, so the reads observe a board that has actually booted.

    $Reads is an array of @{ Address = <uint32>; Count = <int>; Width = <8|32> }. Width defaults to 8;
    use 32 for peripheral registers that ignore byte-wide accesses (they read back as zero).
    Returns the hashtable produced by ConvertFrom-JLinkDump.
#>
function Invoke-BootAndRead {
    param(
        [hashtable[]] $Reads,
        [int]         $RunMs = 1500,
        [string]      $JLinkExe,
        [string]      $Device = 'R7FA6E2BB'
    )

    $body = @('r', 'g', "sleep $RunMs", 'h')

    foreach ($r in $Reads) {
        $cmd   = if (32 -eq $r.Width) { 'mem32' } else { 'mem8' }
        $body += ("{0} 0x{1:X}, 0x{2:X}" -f $cmd, [uint32]$r.Address, [int]$r.Count)
    }

    $out = Invoke-JLink -Body $body -JLinkExe $JLinkExe -Device $Device
    return ConvertFrom-JLinkDump $out
}

<#
    Picks $Count bytes starting at $Address out of a parsed dump, following the 16-byte-per-line layout
    J-Link uses.
#>
function Get-DumpBytes {
    param([hashtable] $Map, [uint32] $Address, [int] $Count = 1)

    $result = New-Object System.Collections.Generic.List[byte]

    for ($i = 0; $i -lt $Count; $i++) {
        $want  = [uint32]($Address + $i)
        $found = $false

        foreach ($key in $Map.Keys) {
            $arr = $Map[$key]
            if (($want -ge $key) -and ($want -lt ($key + $arr.Length))) {
                $result.Add($arr[$want - $key]) | Out-Null
                $found = $true
                break
            }
        }

        if (-not $found) { return $null }
    }

    return $result.ToArray()
}

function Get-DumpU32 {
    param([hashtable] $Map, [uint32] $Address)

    $b = Get-DumpBytes -Map $Map -Address $Address -Count 4
    if ($null -eq $b) { return $null }
    return [uint32] ([uint32]$b[0] -bor ([uint32]$b[1] -shl 8) -bor ([uint32]$b[2] -shl 16) -bor ([uint32]$b[3] -shl 24))
}

<#
    Finds the byte offset of the application build tag letter inside a raw .bin.
#>
function Get-BuildTagOffset([string] $BinPath) {
    $bytes  = [System.IO.File]::ReadAllBytes($BinPath)
    $prefix = [System.Text.Encoding]::ASCII.GetBytes('OTA-BUILD:')

    for ($i = 0; $i -le ($bytes.Length - $prefix.Length - 1); $i++) {
        $match = $true
        for ($j = 0; $j -lt $prefix.Length; $j++) {
            if ($bytes[$i + $j] -ne $prefix[$j]) { $match = $false; break }
        }
        if ($match) { return $i + $prefix.Length }
    }

    throw "Build tag not found in $BinPath"
}