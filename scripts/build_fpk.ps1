# Build fn-docker-desk .fpk package using PowerShell + manual USTAR tar construction
# Equivalent to scripts/build_fpk.py
# Windows PowerShell 5.1 compatible (no TarFile class available)

$ErrorActionPreference = "Stop"

$ROOT = Resolve-Path "$PSScriptRoot\.."
$PKG  = Join-Path $ROOT "pkg"
$FNOS = Join-Path $PKG "fnos"
$FILES = Join-Path $PKG "files"
$DIST = Join-Path $ROOT "dist"

# Read version from manifest
$manifest = Get-Content (Join-Path $FNOS "manifest") -Encoding UTF8
$version = ($manifest | Where-Object { $_ -match '^\s*version\s*=' } | ForEach-Object { ($_ -split '=', 2)[1].Trim() }) | Select-Object -First 1
if (-not $version) { throw "version not found in pkg/fnos/manifest" }
Write-Host "Building fn-docker-desk v$version"

if (-not (Test-Path $DIST)) { New-Item -ItemType Directory -Path $DIST | Out-Null }

# ---------- USTAR tar helpers ----------
# Returns a 512-byte header for a single file entry.
function New-TarHeader {
    param(
        [string]$Name,     # arcname (relative path, forward slashes)
        [int64]$Size,
        [int]$Mode = 420,  # 0o644
        [int64]$Mtime = 0,
        [bool]$IsExec = $false
    )
    $realMode = if ($IsExec) { 493 } else { $Mode }  # 0o755 vs 0o644

    $header = New-Object byte[] 512
    # helper: convert int64 to octal string (PowerShell 5.1 has no :o format)
    function ConvertTo-Octal([int64]$val) {
        if ($val -eq 0) { return '0' }
        $s = ''
        $v = $val
        while ($v -gt 0) {
            $s = [string]($v % 8) + $s
            $v = [math]::Floor($v / 8)
        }
        return $s
    }
    # helper: write octal-padded ASCII field
    function Set-OctalField([byte[]]$buf, [int]$offset, [int]$len, [int64]$val) {
        # octal string, right-padded with NUL, with one trailing space before NULs (classic ustar)
        $s = ConvertTo-Octal $val
        # field layout: <spaces? no> <octal digits> <NUL> OR <octal digits> <space> <NULs>
        # Standard: digits followed by a NUL (or space + NUL). Use digits + NUL, zero-padded on left.
        $maxDigits = $len - 1  # leave 1 byte for NUL
        if ($s.Length -gt $maxDigits) { $s = $s.Substring($s.Length - $maxDigits) }
        $padded = $s.PadLeft($maxDigits, '0')
        for ($i = 0; $i -lt $maxDigits; $i++) {
            $buf[$offset + $i] = [byte][char]$padded[$i]
        }
        $buf[$offset + $maxDigits] = 0  # NUL terminator
    }
    function Set-StringField([byte[]]$buf, [int]$offset, [int]$len, [string]$s) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($s)
        $copyLen = [Math]::Min($bytes.Length, $len)
        [Array]::Copy($bytes, 0, $buf, $offset, $copyLen)
        # remaining bytes already 0 (header initialized with zeros)
    }

    # 0-99: name
    Set-StringField $header 0 100 $Name
    # 100-107: mode (octal, e.g. '0000644\0')
    Set-OctalField $header 100 8 $realMode
    # 108-115: uid (0)
    Set-OctalField $header 108 8 0
    # 116-123: gid (0)
    Set-OctalField $header 116 8 0
    # 124-135: size (octal)
    Set-OctalField $header 124 12 $Size
    # 136-147: mtime (octal)
    Set-OctalField $header 136 12 $Mtime
    # 148-155: checksum (compute below; first fill with spaces)
    for ($i = 148; $i -lt 156; $i++) { $header[$i] = [byte][char]' ' }
    # 156: typeflag ('0' = regular file)
    $header[156] = [byte][char]'0'
    # 157-256: linkname (empty)
    # 257-262: magic 'ustar\0'
    $magic = [System.Text.Encoding]::ASCII.GetBytes('ustar')
    [Array]::Copy($magic, 0, $header, 257, 5)
    $header[262] = 0
    # 263-264: version '00'
    $header[263] = [byte][char]'0'
    $header[264] = [byte][char]'0'
    # 265-296: uname ('root')
    Set-StringField $header 265 32 'root'
    # 297-328: gname ('root')
    Set-StringField $header 297 32 'root'
    # 329-336: devmajor
    # 337-344: devminor
    # 345-499: prefix
    # 500-511: padding
    # Compute checksum: sum of all bytes (checksum field treated as 8 spaces, already set)
    $sum = 0
    foreach ($b in $header) { $sum += $b }
    # Write checksum as 6-digit octal + NUL + space (common format)
    $chk = (ConvertTo-Octal $sum).PadLeft(6, '0')
    $chkBytes = [System.Text.Encoding]::ASCII.GetBytes($chk)
    [Array]::Copy($chkBytes, 0, $header, 148, 6)
    $header[154] = 0
    $header[155] = [byte][char]' '
    return $header
}

# Pad content to 512-byte boundary
function Get-PaddedContent([byte[]]$data) {
    $mod = $data.Length % 512
    if ($mod -eq 0) { return $data }
    $padded = New-Object byte[] ($data.Length + (512 - $mod))
    [Array]::Copy($data, $padded, $data.Length)
    return $padded
}

# Build a tar (uncompressed) from a list of {Path, ArcName, IsExec}
function Build-Tar {
    param([array]$Entries)
    $ms = New-Object System.IO.MemoryStream
    foreach ($e in $Entries) {
        $bytes = [System.IO.File]::ReadAllBytes($e.Path)
        $hdr = New-TarHeader -Name $e.ArcName -Size $bytes.Length -IsExec $e.IsExec
        $ms.Write($hdr, 0, $hdr.Length)
        $padded = Get-PaddedContent $bytes
        $ms.Write($padded, 0, $padded.Length)
    }
    # End-of-archive: two 512-byte zero blocks
    $zeros = New-Object byte[] 1024
    $ms.Write($zeros, 0, 1024)
    return $ms.ToArray()
}

# GZip a byte array
function Compress-Gzip([byte[]]$data) {
    $ms = New-Object System.IO.MemoryStream
    $gs = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionLevel]::Optimal)
    $gs.Write($data, 0, $data.Length)
    $gs.Close()
    $result = $ms.ToArray()
    $ms.Close()
    return $result
}

# Collect files from a directory tree, returning array of {Path, ArcName, IsExec}
function Get-TreeEntries {
    param([string]$BaseDir, [string]$ArcPrefix, [bool]$DefaultExec = $false)
    $entries = @()
    $baseFull = (Get-Item $BaseDir).FullName
    $files = Get-ChildItem -Path $BaseDir -Recurse -File | Where-Object { $_.FullName -notmatch '__pycache__' }
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($baseFull.Length + 1) -replace '\\','/'
        $arcName = if ($ArcPrefix) { "$ArcPrefix/$rel" } else { $rel }
        # Detect shebang
        $first2 = $null
        try {
            $fs = [System.IO.File]::OpenRead($f.FullName)
            $buf = New-Object byte[] 2
            $read = $fs.Read($buf, 0, 2)
            $fs.Close()
            if ($read -ge 2 -and $buf[0] -eq 0x23 -and $buf[1] -eq 0x21) {
                $first2 = $buf
            }
        } catch {}
        $isExec = $DefaultExec -or ($first2 -ne $null)
        $entries += [pscustomobject]@{ Path = $f.FullName; ArcName = $arcName; IsExec = $isExec }
    }
    return $entries
}

# ---------- Build app.tgz ----------
$appEntries = @()
$appEntries += [pscustomobject]@{ Path = Join-Path $FILES "fn-docker-desk.sh"; ArcName = "bin/fn-docker-desk"; IsExec = $true }
$appEntries += [pscustomobject]@{ Path = Join-Path $FILES "web.py"; ArcName = "web.py"; IsExec = $true }
$appEntries += [pscustomobject]@{ Path = Join-Path $FILES "desktop-inject.js"; ArcName = "desktop-inject.js"; IsExec = $false }
$appEntries += Get-TreeEntries (Join-Path $FNOS "ui") "ui" $false

$appTar = Build-Tar $appEntries
$appTgzBytes = Compress-Gzip $appTar
Write-Host ("app.tgz: {0} entries, {1} bytes" -f $appEntries.Count, $appTgzBytes.Length)

# Write app.tgz to a temp file (so we can re-read as bytes for the fpk tar)
$appTgzPath = Join-Path $env:TEMP ("app." + [System.Guid]::NewGuid().ToString("N") + ".tgz")
[System.IO.File]::WriteAllBytes($appTgzPath, $appTgzBytes)

# ---------- Build .fpk ----------
$fpkEntries = @()
$fpkEntries += [pscustomobject]@{ Path = Join-Path $FNOS "manifest"; ArcName = "manifest"; IsExec = $false }
$fpkEntries += [pscustomobject]@{ Path = Join-Path $FNOS "ICON.PNG"; ArcName = "ICON.PNG"; IsExec = $false }
$fpkEntries += [pscustomobject]@{ Path = Join-Path $FNOS "ICON_256.PNG"; ArcName = "ICON_256.PNG"; IsExec = $false }
$fpkEntries += [pscustomobject]@{ Path = $appTgzPath; ArcName = "app.tgz"; IsExec = $false }
$fpkEntries += Get-TreeEntries (Join-Path $FNOS "cmd") "cmd" $true
$fpkEntries += Get-TreeEntries (Join-Path $FNOS "config") "config" $true

$fpkTar = Build-Tar $fpkEntries
$fpkBytes = Compress-Gzip $fpkTar

$fpkOut = Join-Path $DIST "fn-docker-desk_${version}_all.fpk"
[System.IO.File]::WriteAllBytes($fpkOut, $fpkBytes)
Remove-Item $appTgzPath -Force -ErrorAction SilentlyContinue

Write-Host ("Built: {0} ({1} bytes)" -f $fpkOut, $fpkBytes.Length)
return $fpkOut
