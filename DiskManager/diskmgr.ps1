#Requires -RunAsAdministrator

$LogFile="$env:ProgramData\psdiskmgr.log"

function Log($msg){
    $time=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$time $msg" | Out-File $LogFile -Append
}

function Pause { Read-Host "Press Enter" }

function Header {
    Clear-Host
    Write-Host "PowerShell Disk Manager" -ForegroundColor Cyan
    Write-Host "================================="
}

function Get-SystemDisk {
    (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber
}

function DiskList {
    Header
    Get-Disk | ft Number,FriendlyName,Size,PartitionStyle
    Pause
}

function PartitionView {
    Header
    Get-Partition | ft DiskNumber,PartitionNumber,DriveLetter,Size
    Pause
}

function ResizePartitionUI {
    Header
    $d=Read-Host "Drive Letter"
    $s=Read-Host "New Size GB"
    Resize-Partition -DriveLetter $d -Size ($s*1GB)
    Log "Resized $d to $s GB"
}

function CreatePartitionUI {
    Header
    $disk=Read-Host "Disk Number"
    $size=Read-Host "Size GB"
    $letter=Read-Host "Drive Letter"
    New-Partition -DiskNumber $disk -Size ($size*1GB) -DriveLetter $letter
    Log "Partition created on disk $disk"
}

function FormatUI {
    Header
    $drive=Read-Host "Drive Letter"
    $fs=Read-Host "Filesystem (NTFS/exFAT/FAT32)"
    $confirm=Read-Host "Type FORMAT"
    if($confirm -eq "FORMAT"){
        Format-Volume -DriveLetter $drive -FileSystem $fs -Confirm:$false
        Log "Formatted $drive"
    }
}

function BitlockerCheck {
    Header
    Get-BitLockerVolume | ft MountPoint,VolumeStatus,ProtectionStatus
    Pause
}

function ConvertGPTMBR {
    Header
    $disk=Read-Host "Disk Number"
    $type=Read-Host "Target (GPT/MBR)"
    if($disk -eq (Get-SystemDisk)){
        Write-Host "Refusing to convert system disk"
        return
    }
    if($type -eq "GPT"){
        Set-Disk $disk -PartitionStyle GPT
    }else{
        Set-Disk $disk -PartitionStyle MBR
    }
}

function MountVHD {
    Header
    $path=Read-Host "Path to VHD"
    Mount-VHD $path
    Log "Mounted VHD $path"
}

function DismountVHD {
    Header
    $path=Read-Host "Path to VHD"
    Dismount-VHD $path
    Log "Unmounted VHD $path"
}

function SecureWipe {

    Header
    Get-Disk | ft Number,FriendlyName,Size

    $disk=Read-Host "Disk to wipe"

    if($disk -eq (Get-SystemDisk)){
        Write-Host "System disk protection active"
        return
    }

    $confirm=Read-Host "Type WIPE"

    if($confirm -ne "WIPE"){return}

    for($i=1;$i -le 3;$i++){

        Write-Host "Pass $i / 3"

        $script=@"
select disk $disk
clean all
exit
"@

        $script | diskpart

    }

    Log "Disk $disk wiped"
}

function CloneDisk {

    Header

    Get-Disk | ft Number,FriendlyName,Size

    $src=Read-Host "Source Disk"
    $dst=Read-Host "Destination Disk"

    if($dst -eq (Get-SystemDisk)){
        Write-Host "Cannot overwrite system disk"
        return
    }

    Write-Host "Cloning..."

    $srcDisk="\\.\PhysicalDrive$src"
    $dstDisk="\\.\PhysicalDrive$dst"

    $srcStream=[System.IO.File]::OpenRead($srcDisk)
    $dstStream=[System.IO.File]::OpenWrite($dstDisk)

    $buffer=New-Object byte[] 1MB

    while(($read=$srcStream.Read($buffer,0,$buffer.Length)) -gt 0){

        $dstStream.Write($buffer,0,$read)
        Write-Progress -Activity "Cloning Disk" -Status "$read bytes copied"

    }

    $srcStream.Close()
    $dstStream.Close()

    Log "Disk $src cloned to $dst"
}

$menu=@(
"List Disks",
"List Partitions",
"Resize Partition",
"Create Partition",
"Format Partition",
"BitLocker Status",
"Convert GPT/MBR",
"Secure Wipe",
"Clone Disk",
"Mount VHD",
"Dismount VHD",
"Exit"
)

$index=0

while($true){

    Header

    for($i=0;$i -lt $menu.Count;$i++){

        if($i -eq $index){
            Write-Host "> $($menu[$i])" -ForegroundColor Yellow
        }else{
            Write-Host "  $($menu[$i])"
        }

    }

    $key=[console]::ReadKey($true)

    if($key.Key -eq "UpArrow"){ $index-- }
    if($key.Key -eq "DownArrow"){ $index++ }

    if($index -lt 0){$index=0}
    if($index -ge $menu.Count){$index=$menu.Count-1}

    if($key.Key -eq "Enter"){

        switch($index){

            0 {DiskList}
            1 {PartitionView}
            2 {ResizePartitionUI}
            3 {CreatePartitionUI}
            4 {FormatUI}
            5 {BitlockerCheck}
            6 {ConvertGPTMBR}
            7 {SecureWipe}
            8 {CloneDisk}
            9 {MountVHD}
            10{DismountVHD}
            11{break}

        }

    }

}
