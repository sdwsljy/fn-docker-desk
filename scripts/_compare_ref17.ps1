# Compare reference v1.1.17 (actually installed & running on NAS) against current build
$ErrorActionPreference = "Stop"

function Decompress-Gzip([byte[]]$GzBytes) {
    $msIn = New-Object System.IO.MemoryStream(,$GzBytes)
    $gz = New-Object System.IO.Compression.GZipStream($msIn, [System.IO.Compression.CompressionMode]::Decompress)
    $msOut = New-Object System.IO.MemoryStream
    $gz.CopyTo($msOut)
    $gz.Close(); $msIn.Close()
    $r = $msOut.ToArray(); $msOut.Close()
    return $r
}

function Read-TarEntries([byte[]]$TarBytes, [string]$Label) {
    Write-Host "========== $Label =========="
    function Get-Name([byte[]]$b, [int]$off) {
        $len = 0
        for ($i = 0; $i -lt 100; $i++) { if ($b[$off+$i] -eq 0) { $len = $i; break } }
        [System.Text.Encoding]::ASCII.GetString($b, $off, $len)
    }
    function Get-OctalStr([byte[]]$b, [int]$off, [int]$len) {
        [System.Text.Encoding]::ASCII.GetString($b, $off, $len) -replace '\0',' '
    }
    function Hex([byte[]]$bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }
    function Is-ZeroBlock([byte[]]$b, [int]$off) {
        for ($i = 0; $i -lt 512; $i++) { if ($b[$off+$i] -ne 0) { return $false } }
        return $true
    }
    function Dump-PaxPayload([byte[]]$b, [int]$dataOff, [int]$size) {
        if ($size -le 0) { return '' }
        $cap = [Math]::Min($size, 200)
        $bytes = New-Object -TypeName 'byte[]' -ArgumentList $cap
        [Array]::Copy($b, $dataOff, $bytes, 0, $cap)
        $s = ''
        foreach ($by in $bytes) {
            if ($by -ge 0x20 -and $by -lt 0x7F) { $s += [char]$by }
            elseif ($by -eq 10) { $s += '\n' }
            elseif ($by -eq 0) { $s += '.' }
            else { $s += '?' }
        }
        return $s
    }

    $offset = 0; $entry = 0
    while ($offset + 511 -lt $TarBytes.Length) {
        if (Is-ZeroBlock $TarBytes $offset) { Write-Host "[$entry] (end zero block at $offset)"; break }
        $name = Get-Name $TarBytes $offset
        $mode = Get-OctalStr $TarBytes ($offset+100) 8
        $sizeStr = Get-OctalStr $TarBytes ($offset+124) 12
        $mtime = Get-OctalStr $TarBytes ($offset+136) 12
        $chk = Get-OctalStr $TarBytes ($offset+148) 8
        $typeflag = [char]$TarBytes[$offset+156]
        $magic = Hex $TarBytes[($offset+257)..($offset+262)]
        $version = Hex $TarBytes[($offset+263)..($offset+264)]
        $uname = Get-Name $TarBytes ($offset+265)
        $gname = Get-Name $TarBytes ($offset+297)
        $sizeVal = [Convert]::ToInt64($sizeStr.Trim(), 8)
        $dataBlocks = [math]::Ceiling($sizeVal / 512)
        $mtimeVal = if ($mtime.Trim() -eq '') { 0 } else { [Convert]::ToInt64($mtime.Trim(), 8) }
        $mtimeDate = if ($mtimeVal -gt 0) { ([DateTimeOffset]::FromUnixTimeSeconds($mtimeVal).LocalDateTime).ToString() } else { 'EPOCH' }
        $typeName = switch ($typeflag) {
            '0' { 'file' }; '1' { 'link' }; '2' { 'symlink' }; '3' { 'chr' }; '4' { 'blk' }
            '5' { 'dir' }; '6' { 'fifo' }; '7' { 'contig' }; 'x' { 'PaxHeader(x)' }; 'g' { 'PaxHeader(g)' }
            'L' { 'GNU-longname' }; 'K' { 'GNU-longlink' }
            default { "?($typeflag)" }
        }

        Write-Host "[$entry] '$name'  [$typeName]"
        Write-Host "    mode='$mode' size=$sizeVal blocks=$dataBlocks"
        Write-Host "    mtime='$mtime'  → $mtimeDate"
        Write-Host "    chk='$chk' magic=[$magic] ver=[$version]"
        Write-Host "    uname='$uname' gname='$gname'"
        if ($typeflag -eq 'x' -or $typeflag -eq 'g') {
            $payload = Dump-PaxPayload $TarBytes ($offset+512) $sizeVal
            Write-Host "    PAX payload: $payload"
        }

        $offset += 512 + $dataBlocks * 512
        $entry++
    }
    Write-Host ""
}

function Analyze-GzipHeader([byte[]]$GzBytes, [string]$Label) {
    Write-Host "---- GZip header: $Label ----"
    Write-Host ("  magic: {0:X2} {1:X2}" -f $GzBytes[0], $GzBytes[1])
    $flags = $GzBytes[3]
    $flgNames = @()
    if ($flags -band 0x01) { $flgNames += 'FTEXT' }
    if ($flags -band 0x02) { $flgNames += 'FHCRC' }
    if ($flags -band 0x04) { $flgNames += 'FEXTRA' }
    if ($flags -band 0x08) { $flgNames += 'FNAME' }
    if ($flags -band 0x10) { $flgNames += 'FCOMMENT' }
    $mtimeUnix = [BitConverter]::ToUInt32($GzBytes, 4)
    $os = $GzBytes[9]
    $osName = switch ($os) {
        0 { 'FAT' }; 3 { 'Unix' }; 11 { 'NTFS' }; 255 { 'unknown' }; default { "?($os)" }
    }
    $mtimeDate = if ($mtimeUnix -gt 0) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$mtimeUnix).LocalDateTime).ToString() } else { 'NOT SET' }
    Write-Host "  CM: 0x$($GzBytes[2].ToString('X2'))  flags=0x$($flags.ToString('X2')) →  $($flgNames -join ', ')"
    Write-Host "  mtime: $mtimeUnix → $mtimeDate"
    Write-Host "  XFL: 0x$($GzBytes[8].ToString('X2'))  OS: $os → $osName"
    $pos = 10
    if ($flags -band 0x04) { $xl = [BitConverter]::ToUInt16($GzBytes, $pos); $pos += 2 + $xl }
    if ($flags -band 0x08) {
        $end = $pos; while ($GzBytes[$end] -ne 0) { $end++ }
        $fname = [System.Text.Encoding]::ASCII.GetString($GzBytes, $pos, $end - $pos)
        Write-Host "  FNAME: '$fname'"
        $pos = $end + 1
    }
    if ($flags -band 0x10) {
        $end = $pos; while ($GzBytes[$end] -ne 0) { $end++ }
        $fcom = [System.Text.Encoding]::ASCII.GetString($GzBytes, $pos, $end - $pos)
        Write-Host "  FCOMMENT: '$fcom'"
        $pos = $end + 1
    }
    if ($flags -band 0x02) { Write-Host "  FHCRC: 0x$([BitConverter]::ToUInt16($GzBytes, $pos).ToString('X4'))" }
    $tr = $GzBytes[($GzBytes.Length-8)..($GzBytes.Length-1)]
    Write-Host ("  trailer: CRC32={0}  ISIZE={1}" -f [BitConverter]::ToUInt32($tr,0), [BitConverter]::ToUInt32($tr,4))
    Write-Host ""
}

function Extract-EntryBytes([byte[]]$TarBytes, [string]$EntryName) {
    function Get-Name([byte[]]$b, [int]$off) {
        $len = 0
        for ($i = 0; $i -lt 100; $i++) { if ($b[$off+$i] -eq 0) { $len = $i; break } }
        [System.Text.Encoding]::ASCII.GetString($b, $off, $len)
    }
    $offset = 0
    while ($offset + 511 -lt $TarBytes.Length) {
        $name = Get-Name $TarBytes $offset
        if ($name -eq $EntryName) {
            $sizeStr = [System.Text.Encoding]::ASCII.GetString($TarBytes, ($offset+124), 12)
            $sizeVal = [Convert]::ToInt64(($sizeStr -replace '\0','').Trim(), 8)
            $data = New-Object byte[] $sizeVal
            [Array]::Copy($TarBytes, ($offset+512), $data, 0, $sizeVal)
            return $data
        }
        $sz = [Convert]::ToInt64((([System.Text.Encoding]::ASCII.GetString($TarBytes, ($offset+124), 12) -replace '\0','').Trim()), 8)
        $offset += 512 + [math]::Ceiling($sz/512)*512
    }
    return $null
}

$ref = [System.IO.File]::ReadAllBytes("c:\Users\Administrator\Desktop\github\fn-docker-desk\dist\_ref_v1.1.17.fpk")
$cur = [System.IO.File]::ReadAllBytes("c:\Users\Administrator\Desktop\github\fn-docker-desk\dist\fn-docker-desk_1.1.18_all.fpk")

Write-Host "=== SIZE ==="; Write-Host "  REF v1.1.17: $($ref.Length) bytes"; Write-Host "  CUR v1.1.18: $($cur.Length) bytes"; Write-Host ""

Analyze-GzipHeader $ref "REF v1.1.17 outer fpk"
Analyze-GzipHeader $cur "CUR v1.1.18 outer fpk"

$refTar = Decompress-Gzip $ref
$curTar = Decompress-Gzip $cur
Read-TarEntries $refTar "REF v1.1.17 — outer tar (UNCOMPRESSED inside gzip)"
Read-TarEntries $curTar "CUR v1.1.18 — outer tar (UNCOMPRESSED inside gzip)"

$refAppTgz = Extract-EntryBytes $refTar "app.tgz"
$curAppTgz = Extract-EntryBytes $curTar "app.tgz"
if ($refAppTgz) {
    Analyze-GzipHeader $refAppTgz "REF v1.1.17 app.tgz gzip"
    $refAppTar = Decompress-Gzip $refAppTgz
    Read-TarEntries $refAppTar "REF v1.1.17 — app.tgz inner tar"
}
if ($curAppTgz) {
    Analyze-GzipHeader $curAppTgz "CUR v1.1.18 app.tgz gzip"
    $curAppTar = Decompress-Gzip $curAppTgz
    Read-TarEntries $curAppTar "CUR v1.1.18 — app.tgz inner tar"
}

Write-Host "=== DONE ==="
