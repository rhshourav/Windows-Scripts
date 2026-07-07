function Change-DriveLetter {

$old = Read-Host "Current Letter"
$new = Read-Host "New Letter"

Set-Partition -DriveLetter $old -NewDriveLetter $new

Write-Host "Drive letter changed."

}
