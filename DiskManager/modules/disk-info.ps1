function Get-DiskInfo {

Write-Host ""
Write-Host "===== DISKS ====="

Get-Disk | Format-Table Number, FriendlyName, Size, PartitionStyle

Write-Host ""
Write-Host "===== PARTITIONS ====="

Get-Partition | Format-Table DiskNumber, PartitionNumber, DriveLetter, Size

Write-Host ""
Write-Host "===== VOLUMES ====="

Get-Volume | Format-Table DriveLetter, FileSystem, SizeRemaining, Size

}
