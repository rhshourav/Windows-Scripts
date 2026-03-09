#Requires -RunAsAdministrator

Clear-Host

$repo = "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/modules"

$modules = @(
"disk-info.ps1",
"disk-format.ps1",
"disk-resize.ps1",
"disk-wipe.ps1",
"drive-hide.ps1",
"drive-letter.ps1"
)

foreach ($m in $modules) {
    irm "$repo/$m" | iex
}

function Show-Menu {

    Write-Host ""
    Write-Host "==== Windows PowerShell Disk Manager ===="
    Write-Host "1. List Disks"
    Write-Host "2. Resize Partition"
    Write-Host "3. Format Partition"
    Write-Host "4. Change FileSystem"
    Write-Host "5. Secure Wipe Disk"
    Write-Host "6. Change Drive Letter"
    Write-Host "7. Hide Drive"
    Write-Host "8. Unhide Drive"
    Write-Host "9. Exit"
    Write-Host ""

}

do {

Show-Menu
$choice = Read-Host "Select Option"

switch ($choice) {

"1" { Get-DiskInfo }

"2" { Resize-PartitionInteractive }

"3" { Format-PartitionInteractive }

"4" { Convert-FSInteractive }

"5" { Secure-WipeDisk }

"6" { Change-DriveLetter }

"7" { Hide-Drive }

"8" { Unhide-Drive }

}

} while ($choice -ne "9")
