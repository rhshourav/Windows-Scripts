<# 
.SYNOPSIS
  Windows Scripts - Registry + folder migration tool

.DESCRIPTION
  Interactive backup/restore tool for:
  - selected registry keys
  - one chosen folder tree

  Hardened with:
  - self-elevation
  - strict mode
  - black console theme
  - single safe logger
  - manifest output
  - robocopy exit-code handling
  - registry validation
  - interactive mode and folder selection

.AUTHOR
  rhshourav

.PACKAGE
  Part of Windows Scripts
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolName = 'Windows Scripts - Registry Migration'
$script:Author   = 'rhshourav'
$script:Version  = '1.1.0'
$script:LogFile  = $null
$script:SessionRoot = $null

function Set-ConsoleBlackTheme {
    try {
        if ($Host.UI -and $Host.UI.RawUI) {
            $Host.UI.RawUI.BackgroundColor = 'Black'
            $Host.UI.RawUI.ForegroundColor = 'White'
            Clear-Host
        }
    } catch {
        # Ignore if host does not support RawUI
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Administrator {
    if (Test-IsAdministrator) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "This script must be run as Administrator."
    }

    Write-Host "Restarting elevated..."
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runas"
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    exit
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $stamp, $Level, $Message

    Write-Host $line

    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText(
                $script:LogFile,
                $line + [Environment]::NewLine,
                [System.Text.Encoding]::UTF8
            )
        } catch {
            # Logging should never stop the migration
        }
    }
}

function Sanitize-Name {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    return $safe.Trim().TrimEnd('.')
}

function Prompt-MenuChoice {
    Write-Host ""
    Write-Host "Select mode:"
    Write-Host "  1) Backup"
    Write-Host "  2) Restore"
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter 1 or 2"
        switch ($choice.Trim()) {
            '1' { return 'Backup' }
            '2' { return 'Restore' }
            default {
                Write-Host "Invalid choice. Please enter 1 or 2."
            }
        }
    }
}

function Select-Folder {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [string]$InitialPath = $env:USERPROFILE
    )

    try {
        $canUseGui = $false
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            if ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
                $canUseGui = $true
            }
        } catch {
            $canUseGui = $false
        }

        if ($canUseGui) {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = $Title
            $dlg.UseDescriptionForTitle = $true

            if (Test-Path -LiteralPath $InitialPath) {
                $dlg.SelectedPath = $InitialPath
            }

            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                return $dlg.SelectedPath
            }

            throw "Folder selection cancelled."
        }

        Write-Host ""
        Write-Host $Title
        Write-Host "Enter a full folder path and press Enter."
        $p = Read-Host "Path"

        if ([string]::IsNullOrWhiteSpace($p)) {
            throw "No folder selected."
        }

        return $p.Trim()
    }
    catch {
        throw "Folder selection failed: $($_.Exception.Message)"
    }
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    return $Path
}

function Get-RegistryPathsFromUser {
    $defaultPaths = @(
        'HKLM\SOFTWARE\INA',
        'HKCU\SOFTWARE\INA'
    )

    Write-Host ""
    Write-Host "Use default INA registry paths?"
    Write-Host "  1) Yes"
    Write-Host "  2) No, enter custom paths"
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter 1 or 2"
        switch ($choice.Trim()) {
            '1' {
                return $defaultPaths
            }
            '2' {
                $raw = Read-Host "Enter registry paths separated by semicolon"
                if ([string]::IsNullOrWhiteSpace($raw)) {
                    throw "No registry paths entered."
                }

                $items = $raw.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                if ($items.Count -eq 0) {
                    throw "No valid registry paths entered."
                }

                return @($items)
            }
            default {
                Write-Host "Invalid choice. Please enter 1 or 2."
            }
        }
    }
}

function Get-ExistingRegistryPaths {
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths
    )

    $valid = New-Object System.Collections.Generic.List[string]

    foreach ($regPath in $Paths) {
        & reg.exe query $regPath *> $null
        if ($LASTEXITCODE -eq 0) {
            $valid.Add($regPath) | Out-Null
        } else {
            Write-Log "Registry path not found, skipping: $regPath" "WARN"
        }
    }

    return $valid.ToArray()
}

function Export-RegistryKeys {
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,

        [Parameter(Mandatory)]
        [string]$RegistryOutDir
    )

    Ensure-Directory -Path $RegistryOutDir

    $exported = New-Object System.Collections.Generic.List[string]

    foreach ($regPath in $Paths) {
        $safeName = Sanitize-Name $regPath
        $filePath = Join-Path $RegistryOutDir "$safeName.reg"

        Write-Log "Exporting registry: $regPath -> $filePath"
        & reg.exe export $regPath $filePath /y | Out-Null

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $filePath)) {
            throw "Failed to export registry path: $regPath"
        }

        $exported.Add($filePath) | Out-Null
        Write-Log "Exported: $regPath" "OK"
    }

    return $exported.ToArray()
}

function Import-RegistryFiles {
    param(
        [Parameter(Mandatory)]
        [string]$RegistryDir
    )

    if (-not (Test-Path -LiteralPath $RegistryDir)) {
        Write-Log "Registry folder not found, skipping import: $RegistryDir" "WARN"
        return
    }

    $files = Get-ChildItem -LiteralPath $RegistryDir -Filter *.reg -File -ErrorAction SilentlyContinue |
             Sort-Object Name

    foreach ($file in $files) {
        Write-Log "Importing registry file: $($file.FullName)"
        & reg.exe import $file.FullName | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to import registry file: $($file.FullName)"
        }

        Write-Log "Imported: $($file.Name)" "OK"
    }
}

function Copy-Tree {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [string]$Label = 'Files'
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source path not found: $Source"
    }

    Ensure-Directory -Path $Destination

    $sourceFull = (Resolve-Path -LiteralPath $Source).Path
    $destFull = (Resolve-Path -LiteralPath $Destination).Path

    if ($destFull.StartsWith($sourceFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Destination cannot be inside the source path."
    }

    Write-Log "Copying ${Label}: $Source -> $Destination"

    $null = & robocopy.exe `
        $Source `
        $Destination `
        /E /Z /XJ /R:2 /W:2 /COPY:DAT /DCOPY:DAT /NFL /NDL /NP /NJH /NJS

    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        throw "$Label copy failed. Robocopy exit code: $rc"
    }

    Write-Log "$Label copy completed. Robocopy exit code: $rc" "OK"
}

function New-Manifest {
    param(
        [Parameter(Mandatory)]
        [string]$Mode,

        [string]$InputFolder,
        [string]$OutputFolder,

        [string[]]$RegistryPaths,
        [string[]]$ExportedRegistryFiles
    )

    return [ordered]@{
        ToolName        = $script:ToolName
        Author          = $script:Author
        Version         = $script:Version
        Mode            = $Mode
        ComputerName    = $env:COMPUTERNAME
        UserName        = $env:USERNAME
        TimeUtc         = (Get-Date).ToUniversalTime().ToString('o')
        InputFolder     = $InputFolder
        OutputFolder    = $OutputFolder
        RegistryPaths   = $RegistryPaths
        RegistryFiles   = $ExportedRegistryFiles
        PowerShell      = $PSVersionTable.PSVersion.ToString()
        OS              = [System.Environment]::OSVersion.VersionString
    }
}

function Save-Manifest {
    param(
        [Parameter(Mandatory)]
        $Manifest,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-HashSafe {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }

    return $null
}

try {
    Set-ConsoleBlackTheme
    Ensure-Administrator

    $mode = Prompt-MenuChoice
    $registryPaths = Get-RegistryPathsFromUser

    $baseRoot = Join-Path $env:ProgramData 'Windows Scripts'
    Ensure-Directory -Path $baseRoot

    $sessionId = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:SessionRoot = Join-Path $baseRoot "RegistryMigration-$sessionId"
    Ensure-Directory -Path $script:SessionRoot

    $script:LogFile = Join-Path $script:SessionRoot "migration.log"
    Write-Log "Starting $script:ToolName" "INFO"
    Write-Log "Author: $script:Author" "INFO"
    Write-Log "Mode: $mode" "INFO"

    if ($mode -eq 'Backup') {
        $sourceFolder = Select-Folder -Title 'Select the SOURCE folder to back up' -InitialPath $env:USERPROFILE
        $outputFolder = Select-Folder -Title 'Select the OUTPUT folder where the backup will be stored' -InitialPath $env:USERPROFILE

        $sourceFolder = Resolve-ExistingPath -Path $sourceFolder
        if (-not (Test-Path -LiteralPath $sourceFolder)) {
            throw "Invalid source folder: $sourceFolder"
        }

        if (-not (Test-Path -LiteralPath $outputFolder)) {
            Ensure-Directory -Path $outputFolder
        }

        $outputFolder = Resolve-ExistingPath -Path $outputFolder

        $backupRoot  = Join-Path $outputFolder 'WindowsScriptsBackup'
        $filesOutDir = Join-Path $backupRoot 'Files'
        $regOutDir   = Join-Path $backupRoot 'Registry'
        $metaOutDir   = Join-Path $backupRoot 'Meta'

        Ensure-Directory -Path $backupRoot
        Ensure-Directory -Path $filesOutDir
        Ensure-Directory -Path $regOutDir
        Ensure-Directory -Path $metaOutDir

        $folderName = Split-Path -Path $sourceFolder -Leaf
        $destinationTree = Join-Path $filesOutDir $folderName

        $validRegs = Get-ExistingRegistryPaths -Paths $registryPaths
        $exportedRegs = @()

        if ($validRegs.Count -gt 0) {
            $exportedRegs = Export-RegistryKeys -Paths $validRegs -RegistryOutDir $regOutDir
        } else {
            Write-Log 'No registry paths were found. Registry backup skipped.' 'WARN'
        }

        Copy-Tree -Source $sourceFolder -Destination $destinationTree -Label 'Source folder'

        $manifest = New-Manifest -Mode 'Backup' -InputFolder $sourceFolder -OutputFolder $backupRoot -RegistryPaths $validRegs -ExportedRegistryFiles $exportedRegs
        $manifestPath = Join-Path $metaOutDir 'manifest.json'
        Save-Manifest -Manifest $manifest -Path $manifestPath

        $hashPath = Join-Path $metaOutDir 'hashes.txt'
        $hashLines = New-Object System.Collections.Generic.List[string]
        $hashLines.Add("Manifest SHA256: $((Get-HashSafe $manifestPath))") | Out-Null
        $hashLines.Add("Log SHA256: $((Get-HashSafe $script:LogFile))") | Out-Null

        foreach ($f in $exportedRegs) {
            $hashLines.Add("$f = $((Get-HashSafe $f))") | Out-Null
        }

        $hashLines | Set-Content -LiteralPath $hashPath -Encoding UTF8

        Write-Log "Backup completed successfully." "OK"
        Write-Log "Backup root: $backupRoot" "OK"
    }
    elseif ($mode -eq 'Restore') {
        $backupFolder = Select-Folder -Title 'Select the BACKUP folder to restore from' -InitialPath $env:USERPROFILE
        $destinationFolder = Select-Folder -Title 'Select the DESTINATION folder to restore into' -InitialPath $env:USERPROFILE

        $backupFolder = Resolve-ExistingPath -Path $backupFolder
        if (-not (Test-Path -LiteralPath $backupFolder)) {
            throw "Backup folder not found: $backupFolder"
        }

        if (-not (Test-Path -LiteralPath $destinationFolder)) {
            Ensure-Directory -Path $destinationFolder
        }

        $destinationFolder = Resolve-ExistingPath -Path $destinationFolder

        $filesInDir = Join-Path $backupFolder 'Files'
        $regInDir   = Join-Path $backupFolder 'Registry'
        $metaInDir   = Join-Path $backupFolder 'Meta'

        if (Test-Path -LiteralPath $filesInDir) {
            Write-Log "Restoring files from: $filesInDir"
            Copy-Tree -Source $filesInDir -Destination $destinationFolder -Label 'Backup files'
        } else {
            Write-Log 'Files folder not found in backup. Skipping file restore.' 'WARN'
        }

        if (Test-Path -LiteralPath $regInDir) {
            Import-RegistryFiles -RegistryDir $regInDir
        } else {
            Write-Log 'Registry folder not found in backup. Skipping registry restore.' 'WARN'
        }

        $manifestPath = Join-Path $metaInDir 'manifest.json'
        if (Test-Path -LiteralPath $manifestPath) {
            Write-Log "Loaded manifest: $manifestPath" "OK"
        }

        Write-Log "Restore completed successfully." "OK"
        Write-Log "Destination root: $destinationFolder" "OK"
    }
    else {
        throw "Unknown mode selected."
    }

    $metaMsg = "Session log stored at: $script:LogFile"
    Write-Log $metaMsg "OK"
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    throw
}

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUVFlLtQWlDsXfSLyngfSDn7/W
# tISgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
# AQsFADAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzMB4XDTI2MDcwNzA4MDE1
# N1oXDTI5MDcwNzA4MTE1N1owGzEZMBcGA1UEAwwQUkhTSE9VUkFWLUlULU9wczCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALFj11KDAqN3fhbDT9fvgrLF
# VemPYmcud3qA+9Sc4RojOjElODGXyaOlBSVmDGpmCkNRC+dnkGCLB8bYb3gsnHey
# Ud99DA8tvkTgb06+B1pigTZUmhyAwyPiu77+h224c8SsZFkmgQ/Dh2Sc2ynNocZe
# 773d6a/B4DRg7/K9xV8jFap6BP1fjaM3Do40GSL+OVnXl2ssvfFk4FyP5fc8Czz5
# MJ5IJKRFrnHv3kNcmyz5mnz0LoBQs/JtHpWg3BogIalJ2tyCiZgk0xIsz5j5UjhA
# /KepfnWGpCowJ/NJWnmOZcikFlDPggI27QNc/IbxZ035ht+Zgc7b1Cf68GmL/8UC
# AwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0G
# A1UdDgQWBBRJ+13W7/PcqVgZXZf87/JdXvGqxjANBgkqhkiG9w0BAQsFAAOCAQEA
# MDUJsw0AephOCByoLTFSm8hnB4I7s8ddA64vDTv4QF2TcXdrd/glByhEQexUEDpw
# lPCSbzHAmRM5X71QYNoB/CDlCoAO8BQnbegqkhAx8ubRyciwsLA4ZPp+/GFbgZaV
# khkOWpL6v6fmU3kSB5px+roqOuMjmqvbtCDlC4JH25WuDEgGJQhqpgdQSZdomWjH
# le/GnQKt4Y18ysVFvgE1lRO8x6gkJ5IJbZPJ0Q//2xCvtM0WpjXmQl1RHV/7tqDS
# fqprCQxuKiTPC64VfafzeS7IUNJMgQS73H6wuaKdeT85PIxreleNwNXfbr4O/FY3
# eqlSEZAqzKtZXfNFWPmHazCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFow
# DQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNl
# cnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIz
# NTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcG
# A1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3Rl
# ZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2je
# u+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bG
# l20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBE
# EC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/N
# rDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A
# 2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8
# IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfB
# aYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaa
# RBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZi
# fvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXe
# eqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g
# /KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQY
# MBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEF
# BQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBD
# BggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1Ud
# IAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22
# Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih
# 9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYD
# E3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c
# 2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88n
# q2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5
# lDCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAw
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290
# IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMC
# VVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBU
# cnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysdduj
# Rmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S
# 9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+
# 42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg6
# 2IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21
# Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8
# y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQ
# NfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gao
# u30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6g
# qztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJD
# psZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D
# 8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEA
# MB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC
# 0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSG
# Mmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQu
# Y3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0B
# AQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6F
# TGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mC
# efSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57m
# QfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9
# ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dB
# wp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdq
# fMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2
# puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAO
# k5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL
# 0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBun
# vAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE
# 1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNV
# BAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNl
# cnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBD
# QTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNI
# QTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHf
# yjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPx
# NyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpk
# BaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFv
# ZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1zn
# OM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8f
# cpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ah
# fvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUD
# y9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9
# w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTn
# nkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKa
# cJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7
# /PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ
# 7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYI
# KwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEu
# Y3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0Ex
# LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcN
# AQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF
# 0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKq
# dT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbU
# UO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTe
# HihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG
# 7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NB
# qycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6
# +iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaA
# yBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyP
# ehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3F
# NwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIE+jCC
# BPYCAQEwLzAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzAhAQvylGgaQVhE7g
# tCp7LUPgMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBTTI45sHYUF+pl75PQbN48SAVOiUjANBgkq
# hkiG9w0BAQEFAASCAQAlIq7MV6xuuX1Qpojp6Ec1NecUOw3996aHAzEQLRgZC+nf
# ywGwI0q6GoBDNnt7N3oBN/sdtJGuqA7snh6psEhuXP1hXqnSidTMSwrxCpRoCVB3
# jyaBRoAxdKMI2LdXo3HCKAkFSVD+J6rDItLzXRLiM/Yx/Q1apk22nn7wZrbLyp17
# PdsaDUleagqqTqbnkGj5mhtwY/TZ9tySPEx7FdYNhLz7Kth5ZjsQpmPz/ulUoVbS
# LD3kLmAjUj1aZ6c3/5LCpxjsL+DQr2oRPadPBJ0B1LEzi0RPaVxoUCEfgzlvZSG/
# iPxWPxgOIS4oOYQYhMVXJEeB+clhg2GoamCTJULvoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDUwOFowLwYJKoZIhvcNAQkEMSIEID/wIyXtvn+AsTbt
# UKupRHy/6uZj1F/qTLlPCDr+tUKYMA0GCSqGSIb3DQEBAQUABIICADQy2tl6pjqA
# HAn3+Z2yg4DeFbj5TvuNow4mFJy8D382K5X2sICheXK0tymDnHZLWb3lVk2o/eFI
# fHCYfnX6qB0fs4Wy9ZbOnjXkPNbV7/V37aSup7Qwpeix92Xi7HuJW3AkdLofpXFp
# fpJXpZPyxiMKIWc31pOwIXdsnzMmMFYuneqeWYNsC/BTNNP9Z1a+DHh/+tBfH7lm
# hNzUasHLn6uBGhJTunrRQZ7XxRE04SVNkkR2g2TSE1DU7ABzoNmUmKTCQX6PuN0v
# LGdFmDJNYiG7zxcgkahwJUrcqH3X4Lew6e39gVtRPWJxngm+HGCVNFO3tVEHj7d5
# TSzUM9WoeCjUh7xvhl7ZCrTKir4JfHjMqyS866s1IGCQsGWisy2e9m/Ln7iZb0la
# Abc/LvRxhBnW3vJ5uG5Q9MJwas7oH6AssipR/XO3VY9GSzTeOf2Q1v7khOYmevss
# gQdqvXy4H7KW47m8BzrEo07XHcqoAynOvv5FfZlyOCurqIOrw2DPTy8vrbJlgAgT
# fwHTeU5pGJim7TgLrmUeDFHx2XhLytagXXKC7Vstx2tpoijmMHVvHrhKsxIOFe9+
# KlVnSH1DFHGiKl1JHA9iyXpoxPPHauQjZR1u4vN01oMo1i2R1dz8oHkJ5PWhdj1K
# WYy89JrFyjlw2dtHNwxXNKjYusM8Y3SG
# SIG # End signature block
