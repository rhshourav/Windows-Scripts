#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Install Module
    Archive extraction, pnputil driver installation, vendor installer fallback, rollback
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# EXTRACTOR ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-Extractor {
    <#
    .SYNOPSIS Runs extractor.exe against an archive. Handles:
             1) PATH-WITH-SPACES: call operator (&) correctly quotes arguments
             2) CORRUPTED BINARY: detects [PYI-####:ERROR] and re-downloads once
    .PARAMETER ExtractorPath Path to extractor.exe
    .PARAMETER ArchivePath   Archive file to extract
    .PARAMETER OutputDir     Destination folder
    .OUTPUTS PSObject { Success, Output, ExitCode, IsBootstrapFailure }
    #>
    param(
        [string]$ExtractorPath,
        [string]$ArchivePath,
        [string]$OutputDir
    )

    $extractArgs = @('--file', $ArchivePath, '--output', $OutputDir, '--verify')

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $output   = @(& $ExtractorPath @extractArgs 2>&1)
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            return [pscustomobject]@{ Success = $true; Output = $output; ExitCode = 0; IsBootstrapFailure = $false }
        }

        $isBootstrapFailure = ($output -join "`n") -match '\[PYI-\d+:ERROR\]'

        if ($isBootstrapFailure -and $attempt -eq 1) {
            Write-Warn "Extractor self-extraction failed — binary may be corrupted. Re-downloading and retrying once..."
            try {
                Remove-Item -LiteralPath $ExtractorPath -Force -ErrorAction SilentlyContinue
                $extractorUrl = (Get-Command -Name 'Get-ExtractorUrl' -ErrorAction SilentlyContinue)
                $url = if ($extractorUrl) { & Get-ExtractorUrl } else {
                    'https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/extractor/extractor.exe'
                }
                Get-DriverFile -Url $url -Dest $ExtractorPath -Label 'extractor.exe'
                continue
            } catch {
                # Re-download itself failed — fall through
            }
        }

        return [pscustomobject]@{ Success = $false; Output = $output; ExitCode = $exitCode; IsBootstrapFailure = $isBootstrapFailure }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# DRIVER PACKAGE INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

function Install-DriverPackage {
    <#
    .SYNOPSIS Downloads, extracts, and installs a single driver package.
    Returns a PSObject: { Name, Success, Skipped, RebootRequired, Path, PartialFailure, PackagesAdded, PackagesTotal, FailedInfs }
    #>
    param(
        [object]$Driver,
        [string]$OutputRoot,
        [string]$ScratchDir,
        [string]$ExtractorPath,
        [bool]  $IsAdmin
    )

    $result = [pscustomobject]@{
        Name           = $Driver.DisplayName
        Success        = $false
        Skipped        = $false
        RebootRequired = $false
        Path           = ''
        PartialFailure = $false
        PackagesAdded  = 0
        PackagesTotal  = 0
        FailedInfs     = @()
    }

    $safeName = "$($Driver.Provider)_$($Driver.Category)_$($Driver.Version)_$($Driver.Arch)" `
                -replace '[\\/:*?"<>|]', '_' -replace '\s+', '_' -replace '_+', '_'
    $outDir   = Join-Path $OutputRoot $safeName
    $pkgTemp  = Join-Path $ScratchDir ([System.Guid]::NewGuid().ToString('N').Substring(0,8))

    try {
        New-Item -ItemType Directory -Force -Path $outDir  | Out-Null
        New-Item -ItemType Directory -Force -Path $pkgTemp | Out-Null
        $result.Path = $outDir

        if ($Driver.InstallStatus -eq 'CURRENT') {
            Write-Info "v$($Driver.Version) is already installed — reinstalling as requested (repair)."
        } elseif ($Driver.InstallStatus -eq 'NEWER') {
            Write-Warn "Installed v$($Driver.InstalledVersion) is newer than v$($Driver.Version) — proceeding anyway as requested (downgrade)."
        }

        # ── Download all parts ─────────────────────────────────────────────
        $partUrls  = @(Get-PartUrls -PrimaryUrl $Driver.PrimaryUrl -ZipParts $Driver.ZipParts)
        $firstPart = $null

        for ($pi = 0; $pi -lt @($partUrls).Count; $pi++) {
            $url      = $partUrls[$pi]
            $fileName = Split-Path $url -Leaf
            $dest     = Join-Path $pkgTemp $fileName
            if ($pi -eq 0) { $firstPart = $dest }

            Write-Sub "[$($pi+1)/$(@($partUrls).Count)] $fileName"
            Get-DriverFile -Url $url -Dest $dest -Label $fileName
        }

        # ── Extract ────────────────────────────────────────────────────────
        Write-Step "Extracting archive..."
        $extractResult = Invoke-Extractor -ExtractorPath $ExtractorPath -ArchivePath $firstPart -OutputDir $outDir
        if (-not $extractResult.Success) {
            $errLines = ($extractResult.Output | Select-Object -Last 5) -join ' | '
            $hint = if ($extractResult.IsBootstrapFailure) {
                " — this points to antivirus interference or a corrupted extractor download."
            } else { '' }
            throw "Extractor failed (exit $($extractResult.ExitCode))$hint — $errLines"
        }
        Write-OK "Extracted to: $outDir"

        # ── Manifest ───────────────────────────────────────────────────────
        @{
            driver_id       = $Driver.DriverId
            display_name    = $Driver.DisplayName
            provider        = $Driver.Provider
            category        = $Driver.Category
            version         = $Driver.Version
            arch            = $Driver.Arch
            matched_hwid    = $Driver.MatchedHWID
            sha256_parts    = @()
            installed_on    = (Get-Date -Format 'o')
            install_result  = 'pending'
            pnputil_exit    = $null
            reboot_required = $false
            generated_by    = "DriverDex v$((Get-Variable -Name 'Script:VERSION' -ValueOnly -ErrorAction SilentlyContinue))"
        } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir 'manifest.json') -Encoding UTF8

        # ── Install via pnputil ────────────────────────────────────────────
        $infs = @(Get-ChildItem -Path $outDir -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_ -ne $null })

        if (@($infs).Count -gt 0 -and $IsAdmin) {
            Write-Step "Installing $(@($infs).Count) INF package(s) via pnputil..."
            $pnpArgs = @('/add-driver', "$outDir\*.inf", '/subdirs', '/install')

            $pnpOutput = @(& "$env:SystemRoot\System32\pnputil.exe" @pnpArgs 2>&1)
            $exitCode  = $LASTEXITCODE

            $pnpOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

            $totalMatch = $pnpOutput | Select-String -Pattern 'Total driver packages:\s*(\d+)'
            $addedMatch = $pnpOutput | Select-String -Pattern 'Added driver packages:\s*(\d+)'
            $totalCount = if ($totalMatch) { [int]$totalMatch[0].Matches[0].Groups[1].Value } else { @($infs).Count }
            $addedCount = if ($addedMatch) { [int]$addedMatch[0].Matches[0].Groups[1].Value } else { 0 }

            $failedInfs = [System.Collections.Generic.List[string]]::new()
            for ($li = 0; $li -lt (@($pnpOutput).Count - 1); $li++) {
                if ($pnpOutput[$li] -match 'Adding driver package:\s*(.+\.inf)\s*$' -and
                    $pnpOutput[$li + 1] -match 'Failed to add driver package') {
                    $failedInfs.Add($Matches[1].Trim())
                }
            }

            $result.PackagesAdded = $addedCount
            $result.PackagesTotal = $totalCount
            $result.FailedInfs    = @($failedInfs)

            if ($exitCode -in @(0, 3010) -or ($totalCount -gt 0 -and $addedCount -eq $totalCount)) {
                Write-OK "pnputil succeeded — $addedCount/$totalCount package(s) added (exit $exitCode)"
                if ($exitCode -eq 3010) {
                    Write-Warn "Reboot required to complete driver installation."
                    $result.RebootRequired = $true
                }
                $result.Success = $true

            } elseif ($addedCount -gt 0) {
                $result.Success        = $true
                $result.PartialFailure = $true
                $infList = if ($failedInfs.Count -gt 0) { $failedInfs -join ', ' } else { 'one or more packages' }
                Write-Warn "Partially installed — $addedCount of $totalCount package(s) added. Not added: $infList"
                Write-Info "This is usually fine: the package that failed is often redundant or for a different architecture/Windows build."

            } else {
                $pnpMsg = switch ($exitCode) {
                    2    { "Driver may be incompatible with this Windows version." }
                    5    { "Access denied — check that you are running as Administrator." }
                    87   { "Invalid parameter passed to pnputil." }
                    default { "Unexpected pnputil exit code ($exitCode)." }
                }
                Write-Err -What "Driver install failed for $($Driver.DisplayName)" `
                          -Reason $pnpMsg `
                          -Fix    "Try the x86 variant or install manually via Device Manager at: $outDir"
            }

            Start-Sleep -Seconds 2
            if (Test-DriverInstalled -Provider $Driver.Provider -Version $Driver.Version) {
                Write-OK "Cross-check PASSED — driver registered in Win32_PnPSignedDriver."
            } else {
                Write-Warn "Cross-check: driver not yet reflected in system — a reboot may be required."
            }

        } elseif (@($infs).Count -gt 0 -and -not $IsAdmin) {
            Write-Warn "INF found but script is not elevated. Open Device Manager and point it at:"
            Write-Host "      $outDir" -ForegroundColor Cyan
            $result.Success = $true

        } else {
            # Fallback: vendor setup.exe / MSI
            $installer = @(Get-ChildItem -Path $outDir -Include 'setup.exe','*.msi' `
                                       -Recurse -ErrorAction SilentlyContinue |
                         Where-Object { $_ -ne $null }) | Select-Object -First 1
            if ($installer) {
                Write-Step "Vendor installer detected: $($installer.Name)"
                $run = Read-Input -Prompt "Run installer now?" -Default 'Y' `
                    -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'
                if ($run -match '^[Yy]') {
                    $iArgs = if ($installer.Extension -eq '.msi') { @('/i', $installer.FullName, '/qn') } else { @() }
                    Start-Process -FilePath $installer.FullName -ArgumentList $iArgs -Wait
                    Write-OK "Vendor installer completed."
                    $result.Success = $true
                }
            } else {
                Write-Warn "No INF or vendor installer found. Files are at: $outDir"
                $result.Success = $true
            }
        }

        # Update manifest with final result
        try {
            $manifestPath = Join-Path $outDir 'manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifest.install_result  = if ($result.PartialFailure) { 'partial' } elseif ($result.Success) { 'success' } else { 'failed' }
            $manifest.reboot_required = $result.RebootRequired
            $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
        } catch { <# manifest update is best-effort #> }

        return $result

    } catch {
        $errMsg = $_.Exception.Message -replace [regex]::Escape($_.Exception.GetType().FullName), '' -replace '^\s*:\s*', ''
        Write-Err -What "Failed to process $($Driver.DisplayName)" `
                  -Reason $errMsg `
                  -Fix    "Check the log file for the full stack trace and try re-running the script." `
                  -Err    $_
        $result.Success = $false
        return $result

    } finally {
        Remove-Item -Recurse -Force $pkgTemp -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# SEARCH MODE DOWNLOAD + INSTALL
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-SearchDownload {
    <#
    .SYNOPSIS Handles download (and optionally install) for a single search result.
    #>
    param(
        [object]$Item,
        [string]$OutRoot,
        [string]$ScratchDir,
        [string]$Extractor,
        [bool]  $IsAdmin,
        [string]$InstallMode = 'download'
    )

    $safeName = "$($Item.Provider)_$($Item.Category)_$($Item.Version)_$($Item.Arch)" `
                -replace '[\\/:*?"<>|]', '_' -replace '\s+', '_' -replace '_+', '_'
    if (-not $safeName.Trim('_')) { $safeName = "driver_$($Item.DriverId)" }
    $outDir   = Join-Path $OutRoot $safeName
    $pkgTemp  = Join-Path $ScratchDir ([System.Guid]::NewGuid().ToString('N').Substring(0,8))

    try {
        New-Item -ItemType Directory -Force -Path $outDir  | Out-Null
        New-Item -ItemType Directory -Force -Path $pkgTemp | Out-Null

        $partUrls  = @(Get-PartUrls -PrimaryUrl $Item.PrimaryUrl -ZipParts $Item.ZipParts)
        $firstPart = $null

        for ($pi = 0; $pi -lt @($partUrls).Count; $pi++) {
            $url      = $partUrls[$pi]
            $fileName = Split-Path $url -Leaf
            $dest     = Join-Path $pkgTemp $fileName
            if ($pi -eq 0) { $firstPart = $dest }
            Write-Sub "[$($pi+1)/$(@($partUrls).Count)] $fileName"
            Get-DriverFile -Url $url -Dest $dest -Label $fileName
        }

        Write-Step "Extracting..."
        $extractResult = Invoke-Extractor -ExtractorPath $Extractor -ArchivePath $firstPart -OutputDir $outDir
        if (-not $extractResult.Success) {
            $errLines = ($extractResult.Output | Select-Object -Last 3) -join ' | '
            $hint = if ($extractResult.IsBootstrapFailure) {
                " — looks like antivirus interference or a corrupted extractor download."
            } else { '' }
            throw "Extractor failed (exit $($extractResult.ExitCode))$hint — $errLines"
        }
        Write-OK "Extracted to: $outDir"

        if ($InstallMode -eq 'install') {
            $infs = @(Get-ChildItem -Path $outDir -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue |
                      Where-Object { $_ -ne $null })
            if (@($infs).Count -gt 0 -and $IsAdmin) {
                Write-Step "Installing via pnputil ($(@($infs).Count) INF)..."
                $pnpOutput = @(& "$env:SystemRoot\System32\pnputil.exe" `
                                '/add-driver' "$outDir\*.inf" '/subdirs' '/install' 2>&1)
                $exitCode  = $LASTEXITCODE
                $pnpOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

                $totalMatch = $pnpOutput | Select-String -Pattern 'Total driver packages:\s*(\d+)'
                $addedMatch = $pnpOutput | Select-String -Pattern 'Added driver packages:\s*(\d+)'
                $totalCount = if ($totalMatch) { [int]$totalMatch[0].Matches[0].Groups[1].Value } else { @($infs).Count }
                $addedCount = if ($addedMatch) { [int]$addedMatch[0].Matches[0].Groups[1].Value } else { 0 }

                if ($exitCode -in @(0,3010) -or ($totalCount -gt 0 -and $addedCount -eq $totalCount)) {
                    Write-OK "Driver installed successfully — $addedCount/$totalCount package(s)$(if ($exitCode -eq 3010) { ' — reboot required' } else { '' })"
                } elseif ($addedCount -gt 0) {
                    Write-Warn "Partially installed — $addedCount of $totalCount package(s) added."
                } else {
                    Write-Warn "pnputil returned exit code $exitCode — try Device Manager at: $outDir"
                }
            } elseif (@($infs).Count -gt 0 -and -not $IsAdmin) {
                Write-Warn "Not elevated. Point Device Manager to: $outDir"
            } else {
                $inst = @(Get-ChildItem -Path $outDir -Include 'setup.exe','*.msi' -Recurse `
                          -ErrorAction SilentlyContinue | Where-Object { $_ -ne $null }) | Select-Object -First 1
                if ($inst) {
                    Write-Step "Running vendor installer: $($inst.Name)"
                    $iArgs = if ($inst.Extension -eq '.msi') { @('/i', $inst.FullName, '/qn') } else { @() }
                    Start-Process $inst.FullName -ArgumentList $iArgs -Wait
                    Write-OK "Vendor installer completed."
                } else {
                    Write-Warn "No INF or setup.exe found — files at: $outDir"
                }
            }
        } else {
            Write-OK "Download complete. Files saved to:"
            Write-Host "      $outDir" -ForegroundColor Cyan
        }

    } catch {
        Write-Err -What "Failed to process $($Item.DisplayName)" -Reason $_.Exception.Message `
                  -Fix "Check the log and try again."
    } finally {
        Remove-Item -Recurse -Force $pkgTemp -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# REBOOT PROMPT
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-RebootPrompt {
    <#
    .SYNOPSIS Prompts for reboot only if at least one driver flagged pnputil exit 3010.
    #>
    param([object[]]$Results)
    $needsReboot = @($Results | Where-Object { $_.RebootRequired })
    if (@($needsReboot).Count -eq 0) { return }

    Write-Warn "$(@($needsReboot).Count) driver(s) require a reboot to activate."
    Write-Host ""
    $choice = Read-Input -Prompt 'Restart now to apply all drivers?' -Default 'N' `
        -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'

    if ($choice -match '^[Yy]') {
        Write-Warn "Restarting in 10 seconds... Press Ctrl+C to cancel."
        for ($i = 10; $i -ge 1; $i--) {
            Write-Host "`r    $i second(s) remaining...  " -NoNewline -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
        Write-Host ""
        Restart-Computer -Force
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Invoke-Extractor'
    'Install-DriverPackage'
    'Invoke-SearchDownload'
    'Invoke-RebootPrompt'
)