#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Download Module
    Download engine with retry, progress bars, Git LFS resolution, SHA-256 verification
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# MULTI-PART URL BUILDER
# ═══════════════════════════════════════════════════════════════════════════════

function Get-PartUrls {
    <#
    .SYNOPSIS Builds multi-part archive URL list from primary_url + zip_parts count.
    .PARAMETER PrimaryUrl  URL ending in .0001 (or the single file URL)
    .PARAMETER ZipParts    Number of parts (1 = single file)
    #>
    param([string]$PrimaryUrl, [int]$ZipParts)
    if ($ZipParts -le 1) { return ,@($PrimaryUrl) }
    $base = $PrimaryUrl -replace '\.0001$', ''
    return @(1..$ZipParts | ForEach-Object { '{0}.{1:D4}' -f $base, $_ })
}

# ═══════════════════════════════════════════════════════════════════════════════
# GIT LFS POINTER RESOLUTION
# ═══════════════════════════════════════════════════════════════════════════════

function Resolve-LFSPointer {
    <#
    .SYNOPSIS Resolves a Git LFS pointer file to a real download URL.
    .PARAMETER PointerPath  Local path to the downloaded pointer file
    .PARAMETER LfsBatchUrl  LFS batch endpoint URL
    #>
    param(
        [string]$PointerPath,
        [string]$LfsBatchUrl = 'https://github.com/rhshourav/driverdex.git/info/lfs/objects/batch'
    )

    $oid = ''; $size = ''
    Get-Content -LiteralPath $PointerPath | ForEach-Object {
        $t = $_.Trim()
        if ($t -like 'oid sha256:*') { $oid  = $t.Substring($t.IndexOf(':') + 1).Trim() }
        elseif ($t -like 'size *')   { $size = $t.Substring(5).Trim() }
    }
    if (-not $oid -or -not $size) { throw 'Malformed Git LFS pointer: missing oid or size.' }

    $body = @{
        operation = 'download'
        transfers = @('basic')
        objects   = @(@{ oid = $oid; size = [long]$size })
    } | ConvertTo-Json -Depth 5

    $batch = Invoke-RestMethod -Uri $LfsBatchUrl -Method Post `
             -Body $body -ContentType 'application/vnd.git-lfs+json' `
             -Headers @{ Accept = 'application/vnd.git-lfs+json' } -ErrorAction Stop

    $obj = $batch.objects[0]
    if ($obj.error) { throw "Git LFS error: $($obj.error.message)" }
    $href = $obj.actions.download.href
    if (-not $href) { throw 'Git LFS returned no download URL.' }

    $dlHeaders = @{}
    if ($obj.actions.download.header) {
        $obj.actions.download.header.PSObject.Properties |
            ForEach-Object { $dlHeaders[$_.Name] = $_.Value }
    }
    return @{ Href = $href; Headers = $dlHeaders }
}

# ═══════════════════════════════════════════════════════════════════════════════
# FILE DOWNLOAD WITH PROGRESS, RETRY, LFS, SHA-256
# ═══════════════════════════════════════════════════════════════════════════════

function Get-DriverFile {
    <#
    .SYNOPSIS Downloads a file with real-time progress, LFS resolution, retry logic, and SHA-256 verify.
    .PARAMETER Url            Source URL
    .PARAMETER Dest           Local destination path
    .PARAMETER Label          Display name for progress lines
    .PARAMETER ExpectedSha256 If provided, hard-fail on hash mismatch
    .PARAMETER MaxRetries     Number of download attempts (default 3)
    .PARAMETER LfsBatchUrl    LFS batch endpoint (for testability)
    #>
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Label          = '',
        [string]$ExpectedSha256 = '',
        [int]   $MaxRetries     = 3,
        [string]$LfsBatchUrl    = 'https://github.com/rhshourav/driverdex.git/info/lfs/objects/batch'
    )

    $delays = @(2, 4, 8)
    $sw     = [System.Diagnostics.Stopwatch]::new()

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $sw.Restart()
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method  = 'GET'
            $req.Timeout = 30000
            $req.ReadWriteTimeout = 60000
            $resp = $req.GetResponse()
            $totalBytes = $resp.ContentLength

            $stream    = $resp.GetResponseStream()
            $outStream = [System.IO.File]::OpenWrite($Dest)
            $buf       = New-Object byte[] 65536
            $downloaded = [long]0
            $barW       = 20
            $displayLabel = if ($Label) { $Label } else { Split-Path $Url -Leaf }

            try {
                while ($true) {
                    $read = $stream.Read($buf, 0, $buf.Length)
                    if ($read -le 0) { break }
                    $outStream.Write($buf, 0, $read)
                    $downloaded += $read

                    if ($totalBytes -gt 0) {
                        Show-ProgressBar -Current ([int]($downloaded / 1MB)) `
                                         -Total ([int]($totalBytes / 1MB)) `
                                         -Label "↓ $displayLabel" `
                                         -Width $barW
                    } else {
                        $f = $Script:SpinnerFrames[$Script:SpinIdx++ % $Script:SpinnerFrames.Count]
                        $dlMB = [Math]::Round($downloaded / 1MB, 1)
                        Write-Host "`r  $f $displayLabel  ${dlMB} MB downloaded" -NoNewline -ForegroundColor Cyan
                    }
                }
            } finally {
                $outStream.Close()
                $stream.Close()
                $resp.Close()
            }
            Clear-ProgressLine

            # ── Git LFS pointer detection ──────────────────────────────────
            $fi = Get-Item -LiteralPath $Dest
            if ($fi.Length -le 1024) {
                try {
                    $firstLine = Get-Content -LiteralPath $Dest -TotalCount 1 -ErrorAction Stop
                    if ($firstLine -like 'version https://git-lfs.github.com/spec/*') {
                        Write-Sub "LFS pointer detected — resolving real file..."
                        $lfs   = Resolve-LFSPointer -PointerPath $Dest -LfsBatchUrl $LfsBatchUrl
                        $sw.Restart()
                        Invoke-WebRequest -Uri $lfs.Href -OutFile $Dest `
                            -UseBasicParsing -Headers $lfs.Headers -ErrorAction Stop
                        $fi = Get-Item -LiteralPath $Dest
                    }
                } catch [System.IO.IOException] { <# binary, not LFS — fine #> }
            }

            $elapsed = $sw.Elapsed.TotalSeconds
            $sizeMB  = [Math]::Round($fi.Length / 1MB, 2)

            # ── SHA-256 verification ───────────────────────────────────────
            $hashResult = 'SKIPPED'
            if ($ExpectedSha256) {
                $actual = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash.ToLower()
                if ($actual -ne $ExpectedSha256.ToLower()) {
                    Remove-Item $Dest -Force -ErrorAction SilentlyContinue
                    throw "SHA-256 mismatch. Expected: $ExpectedSha256 | Got: $actual"
                }
                $hashResult = 'OK'
                Write-Log -Level INFO -Msg "SHA256 verified for $displayLabel"
            }

            Write-OK "$displayLabel  ·  $sizeMB MB  ·  $($elapsed.ToString('F1'))s  ·  SHA256 $hashResult"
            return

        } catch {
            Clear-ProgressLine
            $reason = $_.Exception.Message
            if ($attempt -lt $MaxRetries) {
                $d = $delays[$attempt - 1]
                Write-Host "  ↻ Retry $attempt/$MaxRetries in ${d}s — $reason" -ForegroundColor DarkYellow
                Write-Log -Level WARN -Msg "Download retry $attempt for ${Url}: $reason"
                Start-Sleep -Seconds $d
            } else {
                Write-Log -Level ERROR -Msg "Download failed after $MaxRetries attempts for ${Url}: $reason" -Err $_
                throw "Download failed after $MaxRetries attempts: $reason"
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Get-PartUrls'
    'Resolve-LFSPointer'
    'Get-DriverFile'
)