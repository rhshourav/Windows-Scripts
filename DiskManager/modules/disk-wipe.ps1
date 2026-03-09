function Secure-WipeDisk {

Get-Disk | Format-Table Number, FriendlyName, Size

$disk = Read-Host "Disk Number"

$confirm = Read-Host "Type WIPE to destroy ALL DATA"

if ($confirm -ne "WIPE") {
Write-Host "Cancelled"
return
}

Write-Host "Cleaning disk..."

Clear-Disk -Number $disk -RemoveData -Confirm:$false

Write-Host "Overwriting with zeros..."

$script = @"
select disk $disk
clean all
exit
"@

$script | diskpart

Write-Host "Disk securely wiped."

}
