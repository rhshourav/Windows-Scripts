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
