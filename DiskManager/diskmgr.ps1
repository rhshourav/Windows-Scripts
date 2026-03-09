#Requires -RunAsAdministrator
[Console]::OutputEncoding=[System.Text.Encoding]::UTF8
chcp 65001 > $null

$Author="rhshourav"
$Version="2.0.1"

$LogDir="$env:USERPROFILE\Documents\rhshourav\windowsScripts\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile="$LogDir\diskmgr.log"

function Log($m){
$t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
"$t | $m" | Out-File $LogFile -Append
}

function Banner{

Clear-Host
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "        Windows Scripts Disk Manager       "
Write-Host "==========================================="
Write-Host "Author  : $Author"
Write-Host "Version : $Version"
Write-Host ""

}

function SystemInfo{

$os=(Get-CimInstance Win32_OperatingSystem).Caption
$ram=[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,2)
$total=[math]::Round((Get-Disk|Measure Size -Sum).Sum/1GB,2)

Write-Host "System Information"
Write-Host "------------------"
Write-Host "OS           : $os"
Write-Host "RAM          : $ram GB"
Write-Host "Total Disk   : $total GB"
Write-Host "Log Dir      : $LogDir"
Write-Host ""

}

function Header{
Banner
SystemInfo
}

function Pause{Read-Host "Press Enter"}

# --------------------------------------------------
# lsblk style disk topology
# --------------------------------------------------

function DiskTopology {

Header

$disks = Get-Disk

foreach($d in $disks){

Write-Host ""
Write-Host "Disk$d ($($d.FriendlyName)) [$($d.BusType)]"

try {
$parts = Get-Partition -DiskNumber $d.Number -ErrorAction Stop
}
catch {
Write-Host "  |- No partitions detected"
continue
}

foreach($p in $parts){

$vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue

$fs  = $vol.FileSystem
$dl  = $p.DriveLetter
$size = [math]::Round($p.Size/1GB,2)

Write-Host "  |- Partition $($p.PartitionNumber)  $dl  $fs  $size GB"

}

}

Pause

}

# --------------------------------------------------
# ASCII visual disk map
# --------------------------------------------------

function DiskVisualizer{

Header

$disks=Get-Disk

foreach($d in $disks){

Write-Host ""
Write-Host "Disk $($d.Number)"

$parts=Get-Partition -DiskNumber $d.Number

foreach($p in $parts){

$size=[math]::Round($p.Size/1GB,2)
$blocks=[math]::Min([int]($size*2),50)
$bar=("#"* $blocks)

Write-Host "[P$($p.PartitionNumber)] $bar $size GB"

}

}

Pause

}

# --------------------------------------------------
# Resize monitor
# --------------------------------------------------

function ResizeMonitor{

Header

$drive=Read-Host "Drive letter"

Write-Host "Monitoring resize changes..."

while($true){

$size=(Get-Partition -DriveLetter $drive).Size
$gb=[math]::Round($size/1GB,2)

Write-Host "$(Get-Date) : $gb GB"

Start-Sleep 2

}

}

# --------------------------------------------------
# Disk benchmark
# --------------------------------------------------

function DiskBenchmark{

Header

$path="$env:TEMP\diskbench.tmp"

Write-Host "Running disk benchmark..."

$size=200MB
$buffer=New-Object byte[] $size

$sw=[Diagnostics.Stopwatch]::StartNew()

[IO.File]::WriteAllBytes($path,$buffer)

$sw.Stop()

$writeSpeed=[math]::Round(($size/1MB)/$sw.Elapsed.TotalSeconds,2)

Remove-Item $path -Force

Write-Host "Write Speed : $writeSpeed MB/s"

Pause

}

# --------------------------------------------------
# NVMe / USB detection
# --------------------------------------------------

function DiskType{

Header

Get-Disk | Select Number,FriendlyName,BusType,Size

Pause

}

# --------------------------------------------------
# SMART health
# --------------------------------------------------

function SmartHealth{

Header

Get-WmiObject -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus |
Select InstanceName,PredictFailure

Pause

}

# --------------------------------------------------
# SSD secure erase
# --------------------------------------------------

function SecureErase{

Header

Get-Disk | ft Number,FriendlyName,BusType

$disk=Read-Host "Disk Number"

$confirm=Read-Host "Type ERASE"

if($confirm -ne "ERASE"){return}

$script=@"
select disk $disk
clean all
exit
"@

$script | diskpart

Log "Secure erase disk $disk"

}

# --------------------------------------------------
# WinRM remote disk command
# --------------------------------------------------

function RemoteDiskManager{

Header

$host=Read-Host "Remote Host"
$cmd=Read-Host "Command (Get-Disk / Get-Partition)"

Invoke-Command -ComputerName $host -ScriptBlock {param($c) Invoke-Expression $c} -ArgumentList $cmd

Pause

}

# --------------------------------------------------
# Update from GitHub
# --------------------------------------------------

function CheckUpdate{

$repo="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/diskmgr.ps1"

$tmp="$env:TEMP\diskmgr_update.ps1"

Invoke-WebRequest $repo -OutFile $tmp

$remote=(Select-String $tmp "Version").Line

if($remote -notmatch $Version){

Write-Host "New version available"

}

}

# --------------------------------------------------
# Menu (ncurses style navigation)
# --------------------------------------------------

$options=@(
"Disk Topology (lsblk style)",
"Partition Visualizer",
"Resize Monitor",
"Disk Benchmark",
"SMART Health",
"Disk Type Detection",
"Secure Erase",
"Remote Disk Manager",
"Check Update",
"Exit"
)

$index=0

while($true){

Header

for($i=0;$i -lt $options.Count;$i++){

if($i -eq $index){
Write-Host "> $($options[$i])" -ForegroundColor Yellow
}else{
Write-Host "  $($options[$i])"
}

}

$key=[console]::ReadKey($true)

if($key.Key -eq "UpArrow"){$index--}
if($key.Key -eq "DownArrow"){$index++}

if($index -lt 0){$index=0}
if($index -ge $options.Count){$index=$options.Count-1}

if($key.Key -eq "Enter"){

switch($index){

0{DiskTopology}
1{DiskVisualizer}
2{ResizeMonitor}
3{DiskBenchmark}
4{SmartHealth}
5{DiskType}
6{SecureErase}
7{RemoteDiskManager}
8{CheckUpdate}
9{break}

}

}

}
