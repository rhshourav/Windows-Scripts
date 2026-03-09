function Format-PartitionInteractive {

$drive = Read-Host "Drive Letter to format"
$fs = Read-Host "Filesystem (NTFS/FAT32/exFAT)"

$confirm = Read-Host "Type FORMAT to confirm"

if ($confirm -ne "FORMAT") {
Write-Host "Aborted"
return
}

Format-Volume -DriveLetter $drive -FileSystem $fs -Confirm:$false

Write-Host "Formatted."

}

function Convert-FSInteractive {

$drive = Read-Host "Drive Letter"
$fs = Read-Host "Target FS (NTFS/FAT32/exFAT)"

Format-Volume -DriveLetter $drive -FileSystem $fs -Confirm:$false

}
