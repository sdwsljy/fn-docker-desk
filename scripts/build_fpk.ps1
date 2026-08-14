# Build fn-docker-desk .fpk — matches Python tarfile.PAX_FORMAT + gzip (flags=0x08|FNAME,XFL=0x02,OS=255)
# Reference: v1.1.17 .fpk actually installed & running on fnOS NAS
$ErrorActionPreference = "Stop"

$ROOT = Resolve-Path "$PSScriptRoot\.."
$PKG  = Join-Path $ROOT "pkg"
$FNOS = Join-Path $PKG "fnos"
$FILES = Join-Path $PKG "files"
$DIST = Join-Path $ROOT "dist"

# ---- version ----
$manifestLines = Get-Content (Join-Path $FNOS "manifest") -Encoding UTF8
$version = $null
foreach ($line in $manifestLines) {
    if ($line -match '^\s*version\s*=\s*(.+)$') { $version = $matches[1].Trim(); break }
}
if (-not $version) { throw "version not found in pkg/fnos/manifest" }
$fpkBasename = "fn-docker-desk_${version}_all.fpk"
Write-Host "Building $fpkBasename"
if (-not (Test-Path $DIST)) { New-Item -ItemType Directory -Path $DIST | Out-Null }

# ============================================================
# Section 1. CRC32 + Custom GZip writer (match Python gzip header)
# ============================================================
# Standard CRC-32 (IEEE polynomial 0xEDB88320, reflected) — lookup table
$script:Crc32Table = New-Object uint32[] 256
for ($i = 0; $i -lt 256; $i++) {
    [uint32]$c = $i
    for ($k = 0; $k -lt 8; $k++) {
        if ($c -band 1) { $c = (0xEDB88320 -bxor ($c -shr 1)) }
        else { $c = $c -shr 1 }
    }
    $script:Crc32Table[$i] = $c
}
function Update-Crc32([uint32]$crc, [byte[]]$buf, [int]$offset, [int]$count) {
    [uint32]$c = $crc -bxor 0xFFFFFFFF
    for ($i = 0; $i -lt $count; $i++) {
        $c = $script:Crc32Table[($c -bxor $buf[$offset+$i]) -band 0xFF] -bxor ($c -shr 8)
    }
    return ($c -bxor 0xFFFFFFFF)
}

# Produce GZip bytes exactly matching Python gzip.GzipFile(fname, compresslevel=9):
#   header: magic(2)+CM(1)+FLG(1)=0x08+MTIME(4 LE)+XFL(1)=0x02+OS(1)=255 + FNAME (ASCIIZ)
#   body:   raw deflate stream (no zlib wrapper)
#   trailer: CRC32(4 LE) + ISIZE(4 LE) = originalSize mod 2^32
function Compress-GzipCustom {
    param(
        [byte[]]$OriginalBytes,
        [string]$Fname,          # original filename (FNAME field)
        [uint32]$Mtime = 0       # Unix timestamp; 0 = current time
    )
    if ($Mtime -eq 0) {
        $epoch = New-Object DateTimeOffset(1970,1,1,0,0,0,[TimeSpan]::Zero)
        $Mtime = [uint32]([Math]::Floor([DateTimeOffset]::UtcNow.Subtract($epoch).TotalSeconds))
    }
    $fnameBytes = [System.Text.Encoding]::ASCII.GetBytes($Fname)

    # ----------- Build header -----------
    $headerSize = 10 + $fnameBytes.Length + 1  # 10 fixed + fname + '\0'
    $header = New-Object byte[] $headerSize
    $header[0] = 0x1F; $header[1] = 0x8B       # magic
    $header[2] = 0x08                           # CM = deflate
    $header[3] = 0x08                           # FLG = FNAME only
    [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$Mtime), 0, $header, 4, 4)  # MTIME LE
    $header[8] = 0x02                           # XFL = best compression
    $header[9] = 0xFF                           # OS = unknown
    [Array]::Copy($fnameBytes, 0, $header, 10, $fnameBytes.Length)
    $header[10 + $fnameBytes.Length] = 0

    # ----------- Body: raw deflate + CRC -----------
    $crc = [uint32]0
    $crc = Update-Crc32 $crc $OriginalBytes 0 $OriginalBytes.Length
    $isize = [uint32]($OriginalBytes.Length -band 0xFFFFFFFF)

    $msBody = New-Object System.IO.MemoryStream
    # Write header first to output stream
    $msOutput = New-Object System.IO.MemoryStream
    $msOutput.Write($header, 0, $header.Length)
    # Deflate: use Optimal. IMPORTANT: DeflateStream must leave stream open so we can append trailer.
    # .NET DeflateStream with leaveOpen = true.
    $ds = New-Object System.IO.Compression.DeflateStream($msOutput, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $ds.Write($OriginalBytes, 0, $OriginalBytes.Length)
    $ds.Close()
    # Trailer: CRC32 LE, ISIZE LE
    $trailer = New-Object byte[] 8
    [Buffer]::BlockCopy([BitConverter]::GetBytes($crc), 0, $trailer, 0, 4)
    [Buffer]::BlockCopy([BitConverter]::GetBytes($isize), 0, $trailer, 4, 4)
    $msOutput.Write($trailer, 0, 8)
    $result = $msOutput.ToArray()
    $msOutput.Close(); $msBody.Close()
    return $result
}

# ============================================================
# Section 2. Tar helpers: build via tar.exe --format=pax, then patch mode/checksum
# ============================================================
function ConvertTo-Octal([int64]$val) {
    if ($val -eq 0) { return '0' }
    $s = ''; $v = $val
    while ($v -gt 0) { $s = [string]($v % 8) + $s; $v = [math]::Floor($v / 8) }
    return $s
}
function Set-OctalField([byte[]]$buf, [int]$offset, [int]$len, [int64]$val) {
    $s = ConvertTo-Octal $val
    $maxDigits = $len - 1
    if ($s.Length -gt $maxDigits) { $s = $s.Substring($s.Length - $maxDigits) }
    $padded = $s.PadLeft($maxDigits, '0')
    for ($i = 0; $i -lt $maxDigits; $i++) { $buf[$offset + $i] = [byte][char]$padded[$i] }
    $buf[$offset + $maxDigits] = 0
}
function Get-TarChecksum([byte[]]$hdr512) {
    $sum = 0
    for ($i = 0; $i -lt 512; $i++) {
        $sum += if ($i -ge 148 -and $i -lt 156) { 0x20 } else { $hdr512[$i] }
    }
    return $sum
}

# Add single file to tar using tar.exe --format=pax (ustar magic + PaxHeader 'x' before each entry)
# -cf on first call, -rf on subsequent (single entry per call for order control)
function Add-TarEntry {
    param(
        [string]$TarPath,
        [string]$BaseDir,
        [string]$RelPath,
        [bool]$IsFirst
    )
    $op = if ($IsFirst) { '-c' } else { '-r' }
    & tar "${op}f" $TarPath --format=pax -C $BaseDir $RelPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "tar ${op}f --format=pax failed for '$RelPath' (exit=$LASTEXITCODE)" }
}

# Walk a directory, return files sorted by forward-slash relative arc name
function Get-AlphaEntries([string]$DirUnderBase, [string]$Stage) {
    $target = Join-Path $Stage $DirUnderBase
    if (-not (Test-Path $target)) { return @() }
    $stageFull = (Get-Item $Stage).FullName
    $files = Get-ChildItem -Path $target -Recurse -File
    $list = foreach ($f in $files) {
        $relNative = $f.FullName.Substring($stageFull.Length + 1)
        $relArc = $relNative -replace '\\', '/'
        [pscustomobject]@{ RelNative = $relNative; Arc = $relArc }
    }
    return ($list | Sort-Object Arc)
}

# Patch PaxHeader entries produced by bsdtar --format=pax to match Python tarfile.PAX_FORMAT
# convention that fnOS expects: name='././@PaxHeader', mode=0, mtime=0, payload=single line "N mtime=<epoch.frac>\n"
function Patch-PaxHeaders {
    param([byte[]]$TarBytes)
    function Get-Name([byte[]]$b, [int]$off) {
        $len = 0
        for ($i = 0; $i -lt 100; $i++) { if ($b[$off+$i] -eq 0) { $len = $i; break } }
        [System.Text.Encoding]::ASCII.GetString($b, $off, $len)
    }
    function Get-Size([byte[]]$b, [int]$off) {
        $raw = [System.Text.Encoding]::ASCII.GetString($b, ($off+124), 12)
        return [Convert]::ToInt64(($raw -replace '\0','').Trim(), 8)
    }
    function Is-Zero([byte[]]$b, [int]$off) {
        for ($i = 0; $i -lt 512; $i++) { if ($b[$off+$i] -ne 0) { return $false } }
        return $true
    }
    # Build a PAX one-line mtime record. Length-prefix includes length-digits count itself.
    # E.g. lenStr="27" + " " + "mtime=1786650251.565991\n" = total 27 bytes
    function Build-PaxMtime([string]$mtimeVal) {
        $body = "mtime=$mtimeVal`n"
        # Try length from 1 digit up to 5: record len = d (digits) + 1 (space) + body.Length
        for ($d = 1; $d -lt 6; $d++) {
            $totalLen = $d + 1 + $body.Length
            $lenStr = [string]$totalLen
            if ($lenStr.Length -ne $d) { continue }  # need more/less digits
            $candidate = "$lenStr $body"
            if ($candidate.Length -eq $totalLen) {
                return [System.Text.Encoding]::ASCII.GetBytes($candidate)
            }
        }
        # fallback
        $totalLen = 2 + $body.Length
        return [System.Text.Encoding]::ASCII.GetBytes("$([string]$totalLen) $body")
    }

    $offset = 0
    while ($offset + 511 -lt $TarBytes.Length) {
        if (Is-Zero $TarBytes $offset) { break }
        $name = Get-Name $TarBytes $offset
        $typeflag = [char]$TarBytes[$offset+156]
        $sizeVal = Get-Size $TarBytes $offset
        $dataBlocks = [math]::Ceiling($sizeVal / 512)

        if ($typeflag -eq 'x') {
            # --- 1. Extract mtime from bsdtar payload (find last 'mtime=' line)
            $dataOff = $offset + 512
            $paxRaw = if ($sizeVal -gt 0) { [System.Text.Encoding]::ASCII.GetString($TarBytes, $dataOff, [Math]::Min([int]$sizeVal, 512)) } else { '' }
            $mtimeVal = "0"
            foreach ($line in ($paxRaw -split "`n")) {
                if ($line -match '^\d+ mtime=(.+)\s*$') { $mtimeVal = $matches[1]; break }
            }
            $newPayload = Build-PaxMtime $mtimeVal
            $newSize = $newPayload.Length

            # --- 2. Patch name field (0-99): '././@PaxHeader' + zeros
            for ($i = 0; $i -lt 100; $i++) { $TarBytes[$offset+$i] = 0 }
            $nm = [System.Text.Encoding]::ASCII.GetBytes('././@PaxHeader')
            [Array]::Copy($nm, 0, $TarBytes, $offset, $nm.Length)

            # --- 3. Patch mode to '0000000 '
            Set-OctalField $TarBytes ($offset+100) 8 0

            # --- 4. Patch size
            Set-OctalField $TarBytes ($offset+124) 12 $newSize

            # --- 5. Patch mtime field to '00000000000 ' (epoch)
            Set-OctalField $TarBytes ($offset+136) 12 0

            # --- 6. Zero data block, write new payload
            for ($i = 0; $i -lt ($dataBlocks*512); $i++) { $TarBytes[$dataOff+$i] = 0 }
            [Array]::Copy($newPayload, 0, $TarBytes, $dataOff, $newPayload.Length)

            # --- 7. Recalculate checksum
            for ($ci = 148; $ci -lt 156; $ci++) { $TarBytes[$offset+$ci] = 0x20 }
            $hdr = New-Object byte[] 512
            [Array]::Copy($TarBytes, $offset, $hdr, 0, 512)
            $chk = Get-TarChecksum $hdr
            $ch = (ConvertTo-Octal $chk).PadLeft(6, '0')
            for ($ci = 0; $ci -lt 6; $ci++) { $TarBytes[$offset+148+$ci] = [byte][char]$ch[$ci] }
            $TarBytes[$offset+154] = 0x00
            $TarBytes[$offset+155] = 0x20

            $dataBlocks = [math]::Ceiling($newSize / 512)
        }
        $offset += 512 + $dataBlocks * 512
    }
}

# Patch tar bytes: only FILE entries (type='0') get mode corrected.
# Exec list (0755): bin/fn-docker-desk, web.py, ui/index.cgi, anything under cmd/
# Non-exec (0644): manifest, ICONs, app.tgz, config/*, desktop-inject.js, ui/* except index.cgi
function Patch-TarModes {
    param([byte[]]$TarBytes, [string]$ExecRegex)

    function Get-Name([byte[]]$b, [int]$off) {
        $len = 0
        for ($i = 0; $i -lt 100; $i++) { if ($b[$off+$i] -eq 0) { $len = $i; break } }
        [System.Text.Encoding]::ASCII.GetString($b, $off, $len)
    }
    function Get-Size([byte[]]$b, [int]$off) {
        $raw = [System.Text.Encoding]::ASCII.GetString($b, ($off+124), 12)
        return [Convert]::ToInt64(($raw -replace '\0','').Trim(), 8)
    }
    function Is-Zero([byte[]]$b, [int]$off) {
        for ($i = 0; $i -lt 512; $i++) { if ($b[$off+$i] -ne 0) { return $false } }
        return $true
    }

    $offset = 0
    while ($offset + 511 -lt $TarBytes.Length) {
        if (Is-Zero $TarBytes $offset) { break }
        $name = Get-Name $TarBytes $offset
        $typeflag = [char]$TarBytes[$offset+156]
        $sizeVal = Get-Size $TarBytes $offset
        $dataBlocks = [math]::Ceiling($sizeVal / 512)

        if ($typeflag -eq '0') {
            # regular file entry — patch mode
            $isExec = [bool]($name -match $ExecRegex)
            $mode = if ($isExec) { 493 } else { 420 }   # 0o755 / 0o644
            Set-OctalField $TarBytes ($offset+100) 8 $mode

            # Recalculate header checksum
            for ($ci = 148; $ci -lt 156; $ci++) { $TarBytes[$offset+$ci] = 0x20 }
            $hdr = New-Object byte[] 512
            [Array]::Copy($TarBytes, $offset, $hdr, 0, 512)
            $chk = Get-TarChecksum $hdr
            $ch = (ConvertTo-Octal $chk).PadLeft(6, '0')
            for ($ci = 0; $ci -lt 6; $ci++) { $TarBytes[$offset+148+$ci] = [byte][char]$ch[$ci] }
            $TarBytes[$offset+154] = 0x00
            $TarBytes[$offset+155] = 0x20
        }
        # else: type='x' (PaxHeader) → skip
        $offset += 512 + $dataBlocks * 512
    }
}

# ============================================================
# Section 3. Build inner app.tgz
# ============================================================
$appStage = Join-Path $env:TEMP ("fn-app." + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $appStage "bin") -Force | Out-Null
Copy-Item (Join-Path $FILES "fn-docker-desk.sh") (Join-Path $appStage "bin\fn-docker-desk") -Force
Copy-Item (Join-Path $FILES "web.py") (Join-Path $appStage "web.py") -Force
Copy-Item (Join-Path $FILES "desktop-inject.js") (Join-Path $appStage "desktop-inject.js") -Force
if (Test-Path (Join-Path $FNOS "ui")) { Copy-Item (Join-Path $FNOS "ui") (Join-Path $appStage "ui") -Recurse -Force }

$appTarPath = Join-Path $env:TEMP ("fn-app-tar." + [guid]::NewGuid().ToString("N") + ".tar")
try {
    # Order: bin/fn-docker-desk → web.py → desktop-inject.js → ui/** (alpha)
    $ordered = @()
    $ordered += [pscustomobject]@{ RelNative = "bin\fn-docker-desk"; Arc = "bin/fn-docker-desk" }
    $ordered += [pscustomobject]@{ RelNative = "web.py"; Arc = "web.py" }
    $ordered += [pscustomobject]@{ RelNative = "desktop-inject.js"; Arc = "desktop-inject.js" }
    $ordered += @(Get-AlphaEntries "ui" $appStage)
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        Add-TarEntry -TarPath $appTarPath -BaseDir $appStage -RelPath $ordered[$i].RelNative -IsFirst ($i -eq 0)
    }
    $appTarBytes = [System.IO.File]::ReadAllBytes($appTarPath)
} finally {
    Remove-Item $appTarPath -Force -ErrorAction SilentlyContinue
    Remove-Item $appStage -Recurse -Force -ErrorAction SilentlyContinue
}
# Patch PaxHeaders, then patch modes (exec: bin/fn-docker-desk, web.py, ui/index.cgi)
Patch-PaxHeaders $appTarBytes
Patch-TarModes $appTarBytes '^bin/fn-docker-desk$|^web\.py$|^ui/index\.cgi$'
# Gzip with custom header FNAME='app.tgz'
$appTgzBytes = Compress-GzipCustom $appTarBytes -Fname "app.tgz"
$appTgzPath = Join-Path $env:TEMP ("fn-app." + [guid]::NewGuid().ToString("N") + ".tgz")
[System.IO.File]::WriteAllBytes($appTgzPath, $appTgzBytes)
Write-Host ("app.tgz: entries={0}, tar_size={1}, tgz_size={2}" -f $ordered.Count, $appTarBytes.Length, $appTgzBytes.Length)

# ============================================================
# Section 4. Build outer .fpk
# ============================================================
$fpkStage = Join-Path $env:TEMP ("fn-fpk." + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fpkStage -Force | Out-Null
try {
    Copy-Item (Join-Path $FNOS "manifest") (Join-Path $fpkStage "manifest") -Force
    Copy-Item (Join-Path $FNOS "ICON.PNG") (Join-Path $fpkStage "ICON.PNG") -Force
    Copy-Item (Join-Path $FNOS "ICON_256.PNG") (Join-Path $fpkStage "ICON_256.PNG") -Force
    Copy-Item $appTgzPath (Join-Path $fpkStage "app.tgz") -Force
    if (Test-Path (Join-Path $FNOS "cmd")) { Copy-Item (Join-Path $FNOS "cmd") (Join-Path $fpkStage "cmd") -Recurse -Force }
    if (Test-Path (Join-Path $FNOS "config")) { Copy-Item (Join-Path $FNOS "config") (Join-Path $fpkStage "config") -Recurse -Force }

    # Build ordered list — strict order: manifest → ICON.PNG → ICON_256.PNG → app.tgz → cmd/** → config/**
    $ordered = @()
    $ordered += [pscustomobject]@{ RelNative = "manifest"; Arc = "manifest" }
    $ordered += [pscustomobject]@{ RelNative = "ICON.PNG"; Arc = "ICON.PNG" }
    $ordered += [pscustomobject]@{ RelNative = "ICON_256.PNG"; Arc = "ICON_256.PNG" }
    $ordered += [pscustomobject]@{ RelNative = "app.tgz"; Arc = "app.tgz" }
    $ordered += @(Get-AlphaEntries "cmd" $fpkStage)
    $ordered += @(Get-AlphaEntries "config" $fpkStage)

    $fpkTarPath = Join-Path $env:TEMP ("fn-fpk-tar." + [guid]::NewGuid().ToString("N") + ".tar")
    try {
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            Add-TarEntry -TarPath $fpkTarPath -BaseDir $fpkStage -RelPath $ordered[$i].RelNative -IsFirst ($i -eq 0)
        }
        $fpkTarBytes = [System.IO.File]::ReadAllBytes($fpkTarPath)
    } finally {
        Remove-Item $fpkTarPath -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item $fpkStage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $appTgzPath -Force -ErrorAction SilentlyContinue
}
# Patch outer PaxHeaders, then patch modes (exec = ^cmd/ ... everything else 0644)
Patch-PaxHeaders $fpkTarBytes
Patch-TarModes $fpkTarBytes '^cmd/'
# Gzip with custom header FNAME=fn-docker-desk_X.Y.Z_all.fpk
$fpkBytes = Compress-GzipCustom $fpkTarBytes -Fname $fpkBasename
$fpkOut = Join-Path $DIST $fpkBasename
[System.IO.File]::WriteAllBytes($fpkOut, $fpkBytes)
Write-Host ("Built: {0} ({1} bytes)" -f $fpkOut, $fpkBytes.Length)
return $fpkOut
