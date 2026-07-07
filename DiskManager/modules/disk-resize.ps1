function Resize-PartitionInteractive {

$drive = Read-Host "Drive Letter"
$sizeGB = Read-Host "New Size (GB)"

$size = $sizeGB * 1GB

Resize-Partition -DriveLetter $drive -Size $size

Write-Host "Partition resized."

}
