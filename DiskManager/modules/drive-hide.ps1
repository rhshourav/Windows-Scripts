function Hide-Drive {

$letter = Read-Host "Drive Letter to hide"

Remove-PartitionAccessPath -DriveLetter $letter -AccessPath "$letter`:"

Write-Host "Drive hidden."

}

function Unhide-Drive {

$disk = Read-Host "Disk Number"
$part = Read-Host "Partition Number"
$letter = Read-Host "Drive Letter"

Add-PartitionAccessPath -DiskNumber $disk -PartitionNumber $part -DriveLetter $letter

Write-Host "Drive restored."

}
