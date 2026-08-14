# Compare known-good reference fpk (v1.0.6, Python-built) against my current build
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

    $offset = 0; $entry = 0
    while ($offset + 511 -lt $TarBytes.Length) {
        if (Is-ZeroBlock $TarBytes $offset) { Write-Host "[$entry] (end zero block at $offset)"; break }
        $name = Get-Name $TarBytes $offset
        $mode = Get-OctalStr $TarBytes ($offset+100) 8
        $uid = Get-OctalStr $TarBytes ($offset+108) 8
        $gid = Get-OctalStr $TarBytes ($offset+116) 8
        $sizeStr = Get-OctalStr $TarBytes ($offset+124) 12
        $mtime = Get-OctalStr $TarBytes ($offset+136) 12
        $chk = Get-OctalStr $TarBytes ($offset+148) 8
        $typeflag = [char]$TarBytes[$offset+156]
        $linkname = Get-Name $TarBytes ($offset+157)  # 157-256
        $magic = Hex $TarBytes[($offset+257)..($offset+262)]
        $version = Hex $TarBytes[($offset+263)..($offset+264)]
        $uname = Get-Name $TarBytes ($offset+265)  # 265-296
        $gname = Get-Name $TarBytes ($offset+297)  # 297-328
        $devmajor = Get-OctalStr $TarBytes ($offset+329) 8
        $devminor = Get-OctalStr $TarBytes ($offset+337) 8
        $prefixLen = 0
        for ($i = 345; $i -lt 500; $i++) { if ($TarBytes[$offset+$i] -eq 0) { $prefixLen = $i-345; break } }
        $prefix = [System.Text.Encoding]::ASCII.GetString($TarBytes, ($offset+345), $prefixLen)
        $sizeVal = [Convert]::ToInt64($sizeStr.Trim(), 8)
        $dataBlocks = [math]::Ceiling($sizeVal / 512)
        $mtimeVal = if ($mtime.Trim() -eq '') { 0 } else { [Convert]::ToInt64($mtime.Trim(), 8) }
        $mtimeDate = if ($mtimeVal -gt 0) { ([DateTimeOffset]::FromUnixTimeSeconds($mtimeVal).LocalDateTime).ToString() } else { 'EPOCH' }

        Write-Host "[$entry] '$name'"
        Write-Host "    type='$typeflag' size=$sizeVal dataBlocks=$dataBlocks next=`$$($offset+512+$dataBlocks*512)"
        Write-Host "    mode='$mode' uid='$uid' gid='$gid' uname='$uname' gname='$gname'"
        Write-Host "    mtime='$mtime'  → $mtimeDate"
        Write-Host "    chk='$chk' magic=[$magic] version=[$version]"
        if ($linkname) { Write-Host "    linkname='$linkname'" }
        if ($prefix)   { Write-Host "    prefix='$prefix'" }
        if ($devmajor.Trim() -ne '0') { Write-Host "    devmajor='$devmajor' devminor='$devminor'" }
        # Check padding bytes after the entry name
        $padTest = ""
        for ($i = 0; $i -lt 20; $i++) { $v = $TarBytes[$offset+345+$i]; if ($v -ne 0) { $padTest += "$($v.ToString('X2')) " } }
        if ($padTest) { Write-Host "    prefix raw non-zero: $padTest" }

        $offset += 512 + $dataBlocks * 512
        $entry++
    }
    Write-Host ""
}

function Analyze-GzipHeader([byte[]]$GzBytes, [string]$Label) {
    Write-Host "---- GZip header: $Label ----"
    $magic1 = $GzBytes[0].ToString('X2'); $magic2 = $GzBytes[1].ToString('X2')
    $cm = $GzBytes[2].ToString('X2')
    $flags = $GzBytes[3]
    $flgNames = @()
    if ($flags -band 0x01) { $flgNames += 'FTEXT' }
    if ($flags -band 0x02) { $flgNames += 'FHCRC' }
    if ($flags -band 0x04) { $flgNames += 'FEXTRA' }
    if ($flags -band 0x08) { $flgNames += 'FNAME' }
    if ($flags -band 0x10) { $flgNames += 'FCOMMENT' }
    $mtimeBytes = $GzBytes[4..7]
    $mtimeUnix = [BitConverter]::ToUInt32($mtimeBytes, 0)  # little-endian
    $xfl = $GzBytes[8].ToString('X2')
    $os = $GzBytes[9]
    $osName = switch ($os) {
        0 { 'FAT filesystem (MS-DOS, OS/2, NT/Win32)' }
        1 { 'Amiga' } 2 { 'VMS (or OpenVMS)' } 3 { 'Unix' }
        4 { 'VM/CMS' } 5 { 'Atari TOS' } 6 { 'HPFS filesystem (OS/2, NT)' }
        7 { 'Macintosh' } 8 { 'Z-System' } 9 { 'CP/M' }
        10 { 'TOPS-20' } 11 { 'NTFS filesystem (NT)' }
        12 { 'QDOS' } 13 { 'Acorn RISCOS' } 255 { 'unknown' }
        default { "?($os)" }
    }
    $mtimeDate = if ($mtimeUnix -gt 0) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$mtimeUnix).LocalDateTime).ToString() } else { 'NOT SET' }

    Write-Host "  magic: $magic1 $magic2  (expected 1F 8B)"
    Write-Host "  CM: $cm  (08 = deflate)"
    Write-Host "  flags: 0x$($flags.ToString('X2'))  →  $($flgNames -join ', ')"
    Write-Host "  mtime: $mtimeUnix  →  $mtimeDate"
    Write-Host "  XFL: $xfl  (02=best, 04=fastest)"
    Write-Host "  OS: $os  →  $osName"

    # Parse optional fields (FNAME: read original filename)
    $pos = 10
    if ($flags -band 0x04) {
        $xlen = [BitConverter]::ToUInt16($GzBytes, $pos); $pos += 2; $pos += $xlen
        Write-Host "  (FEXTRA: skipped $xlen bytes)"
    }
    if ($flags -band 0x08) {
        $fnameEnd = $pos
        while ($GzBytes[$fnameEnd] -ne 0 -and $fnameEnd -lt $GzBytes.Length) { $fnameEnd++ }
        $fname = [System.Text.Encoding]::ASCII.GetString($GzBytes, $pos, $fnameEnd - $pos)
        Write-Host "  FNAME (original): '$fname'"
        $pos = $fnameEnd + 1
    }
    if ($flags -band 0x10) {
        $fcomEnd = $pos
        while ($GzBytes[$fcomEnd] -ne 0 -and $fcomEnd -lt $GzBytes.Length) { $fcomEnd++ }
        $fcom = [System.Text.Encoding]::ASCII.GetString($GzBytes, $pos, $fcomEnd - $pos)
        Write-Host "  FCOMMENT: '$fcom'"
        $pos = $fcomEnd + 1
    }
    if ($flags -band 0x02) {
        $crc = [BitConverter]::ToUInt16($GzBytes, $pos)
        Write-Host "  FHCRC: CRC16=$crc"; $pos += 2
    }

    # GZip trailer (last 8 bytes): CRC32 (4) + ISIZE (4)
    $trailer = $GzBytes[($GzBytes.Length-8)..($GzBytes.Length-1)]
    $crc32 = [BitConverter]::ToUInt32($trailer, 0)
    $isize = [BitConverter]::ToUInt32($trailer, 4)
    Write-Host "  trailer CRC32=$crc32 ISIZE=$isize (original size mod 2^32)"
    Write-Host ""
}

$ref = [System.IO.File]::ReadAllBytes("c:\Users\Administrator\Desktop\github\fn-docker-desk\dist\_ref_v1.0.6.fpk")
$cur = [System.IO.File]::ReadAllBytes("c:\Users\Administrator\Desktop\github\fn-docker-desk\dist\fn-docker-desk_1.1.18_all.fpk")

# --- GZip headers ---
Analyze-GzipHeader $ref "REFERENCE v1.0.6 (49 downloads, works)"
Analyze-GzipHeader $cur "CURRENT v1.1.18 (rejected)"

# --- Outer tar entries ---
$refTar = Decompress-Gzip $ref
$curTar = Decompress-Gzip $cur
Read-TarEntries $refTar "REFERENCE: v1.0.6 outer tar (before gzip)"
Read-TarEntries $curTar "CURRENT: v1.1.18 outer tar (before gzip)"

# --- Inner app.tgz tar entries ---
function Extract-EntryContent([byte[]]$TarBytes, [string]$EntryName) {
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
    Write-Warning "Entry '$EntryName' not found"
    return $null
}

$refAppTgz = Extract-EntryContent $refTar "app.tgz"
$curAppTgz = Extract-EntryContent $curTar "app.tgz"
if ($refAppTgz) {
    Analyze-GzipHeader $refAppTgz "REFERENCE app.tgz gzip header"
    $refAppTar = Decompress-Gzip $refAppTgz
    Read-TarEntries $refAppTar "REFERENCE: app.tgz inner tar"
}
if ($curAppTgz) {
    Analyze-GzipHeader $curAppTgz "CURRENT app.tgz gzip header"
    $curAppTar = Decompress-Gzip $curAppTgz
    Read-TarEntries $curAppTar "CURRENT: app.tgz inner tar"
}

Write-Host "=== DONE ==="
