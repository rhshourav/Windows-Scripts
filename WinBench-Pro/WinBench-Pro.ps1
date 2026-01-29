#requires -version 5.0
<#
===============================================================================
 Windows-Scripts | WinBench-Pro (Real-World Benchmarks + Trace Kit) v2.0.2
 Author : Shourav (rhshourav)
 GitHub : https://github.com/rhshourav
===============================================================================

Purpose (CLI-first, real workloads):
  [1] RAM      : WinSAT mem (bandwidth) + optional uncached/single-thread variants
  [2] Storage  : DiskSpd (real IO patterns, uncached) + WinSAT disk
  [3] CPU      : WinSAT cpu (compression/encryption) + FFmpeg x264 encode (real workload)
  [4] GPU      : WinSAT d3d/dwm baseline + FFmpeg HW encode throughput (NVENC/QSV/AMF if available)
  Trace ("strace-like"):
      - WPR (ETL) optional
      - Procmon (PML) optional
      - Perf counters CSV optional

Output:
  - Beautiful terminal summary
  - report.txt
  - report.html (optional)
  - transcript.txt
  - traces (ETL/PML/CSV) when enabled

CLI vs GUI note:
  - CLI tools (DiskSpd/FFmpeg/WinSAT) are repeatable and scriptable.
  - GUI tools can be convenient but are harder to automate reliably.
  - This script defaults to CLI-first, and can optionally include GUI tools if found.

USAGE:
  Interactive:
    powershell -ExecutionPolicy Bypass -File .\WinBench-Pro.ps1

  Non-interactive examples:
    powershell -ExecutionPolicy Bypass -File .\WinBench-Pro.ps1 -Selection "1-4" -Profile Extended -Report Both -TraceCounters -TraceWPR
    powershell -ExecutionPolicy Bypass -File .\WinBench-Pro.ps1 -Selection "2" -Profile Standard -Report Text
#>

[CmdletBinding()]
param(
  [string]$Selection = "",                       # "1", "1,2", "1-4", "all"
  [ValidateSet("Quick","Standard","Extended")]
  [string]$Profile = "Standard",                 # intensity/duration
  [ValidateSet("Terminal","Text","Html","Both")]
  [string]$Report = "Both",                      # save txt/html
  [switch]$UseGUI,                               # allow optional GUI tools if found
  [switch]$NoDownload,                           # do not download missing tools
  [switch]$NoElevate,                            # do not attempt self-elevation
  [switch]$TraceWPR,                             # record ETL via WPR around tests
  [switch]$TraceProcmon,                         # record PML via Procmon around tests
  [switch]$TraceCounters                         # sample perf counters to CSV
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptVersion = "2.0.2"

# -----------------------------
# Theme / UI
# -----------------------------
$C_OK="Green"; $C_WARN="Yellow"; $C_ERR="Red"; $C_INFO="Cyan"; $C_DIM="DarkGray"; $C_HDR="White"

function Write-Rule([string]$title="") {
  $line = ("=" * 78)
  Write-Host $line -ForegroundColor $C_DIM
  if ($title) { Write-Host (" " + $title) -ForegroundColor $C_HDR }
  Write-Host $line -ForegroundColor $C_DIM
}
function W([string]$msg, [string]$color="Gray") { Write-Host $msg -ForegroundColor $color }
function OK([string]$msg) { W "[OK] $msg" $C_OK }
function INF([string]$msg) { W "[i]  $msg" $C_INFO }
function WRN([string]$msg) { W "[!] $msg" $C_WARN }
function ERR([string]$msg) { W "[X] $msg" $C_ERR }

# -----------------------------
# Array safety helper (fixes .Count on single objects)
# -----------------------------
function To-Array {
  param($x)
  if ($null -eq $x) { return @() }
  if ($x -is [System.Array]) { return $x }
  return ,$x
}

# -----------------------------
# Admin / Elevation
# -----------------------------
function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}
function Ensure-Admin {
  if ($NoElevate) { return }
  if (Test-IsAdmin) { return }
  WRN "Not running as Administrator. Some tests/traces may be limited."
  WRN "Relaunching elevated..."
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "powershell.exe"
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " + ($MyInvocation.UnboundArguments -join " ")
  $psi.Verb = "runas"
  try {
    [Diagnostics.Process]::Start($psi) | Out-Null
    exit 0
  } catch {
    ERR "Elevation cancelled/failed. Continuing non-admin."
  }
}

# -----------------------------
# TLS / Download helpers
# -----------------------------
function Enable-Tls12 {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}
function Invoke-Download {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [int]$StallSeconds = 120
  )

  Enable-Tls12

  $tmp = $OutFile + ".part"
  try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {}

  # --- Prefer BITS (most reliable on Windows) ---
  if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
    try {
      INF "Downloading (BITS): $Url"
      $job = Start-BitsTransfer -Source $Url -Destination $tmp -Asynchronous -DisplayName "WinBench-Pro" -Description "Download"

      $lastBytes = -1L
      $stall = 0

      while ($job.JobState -in @("Connecting","Transferring")) {
        Start-Sleep -Seconds 1
        $job = Get-BitsTransfer -Id $job.Id

        $bt = [double]$job.BytesTransferred
        $tt = [double]$job.BytesTotal

        $pct = if ($tt -gt 0) { [math]::Round(($bt/$tt)*100,1) } else { 0 }
        $mbt = [math]::Round($bt/1MB,1)
        $mbt2= if ($tt -gt 0) { [math]::Round($tt/1MB,1) } else { 0 }

        if ($bt -eq $lastBytes) { $stall++ } else { $stall = 0; $lastBytes = [int64]$bt }
        if ($stall -ge $StallSeconds) { throw "Download stalled for ~${StallSeconds}s (no progress)." }

        if ($tt -gt 0) {
          Write-Host -NoNewline ("`r[i]  Downloading... {0}% ({1} MB / {2} MB)" -f $pct,$mbt,$mbt2)
        } else {
          Write-Host -NoNewline ("`r[i]  Downloading... {0} MB" -f $mbt)
        }
      }

      Write-Host ""

      if ($job.JobState -eq "Transferred") {
        Complete-BitsTransfer -BitsJob $job
        Move-Item $tmp $OutFile -Force
        OK "Saved: $OutFile"
        return $true
      }

      throw "BITS ended in state: $($job.JobState)"
    } catch {
      Write-Host ""
      WRN "BITS download failed: $($_.Exception.Message)"
      try { if ($job) { Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } } catch {}
      try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {}
      WRN "Falling back to stream download..."
    }
  }

  # --- Stream fallback (shows progress) ---
  INF "Downloading (stream): $Url"
  $resp = $null; $in = $null; $fs = $null
  try {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = "GET"
    $req.UserAgent = "WinBench-Pro/$ScriptVersion"
    $req.AllowAutoRedirect = $true
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000

    $resp = $req.GetResponse()
    $total = [int64]$resp.ContentLength

    $in = $resp.GetResponseStream()
    $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)

    $buf = New-Object byte[] (1024*1024)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $downloaded = 0L
    $lastReportSec = -1
    $lastBytes = 0L
    $stall = 0

    while (($read = $in.Read($buf,0,$buf.Length)) -gt 0) {
      $fs.Write($buf,0,$read)
      $downloaded += $read

      $sec = [int]$sw.Elapsed.TotalSeconds
      if ($sec -ne $lastReportSec) {
        $lastReportSec = $sec

        $mb = [math]::Round($downloaded/1MB,1)
        $mbTot = if ($total -gt 0) { [math]::Round($total/1MB,1) } else { 0 }
        $pct = if ($total -gt 0) { [math]::Round(($downloaded/$total)*100,1) } else { 0 }

        $speed = ($downloaded - $lastBytes) / 1MB
        $lastBytes = $downloaded

        if ($speed -le 0) { $stall++ } else { $stall = 0 }
        if ($stall -ge $StallSeconds) { throw "Download stalled for ~${StallSeconds}s (no progress)." }

        if ($total -gt 0) {
          Write-Host -NoNewline ("`r[i]  Downloading... {0}% ({1} MB / {2} MB) {3} MB/s" -f $pct,$mb,$mbTot,[math]::Round($speed,1))
        } else {
          Write-Host -NoNewline ("`r[i]  Downloading... {0} MB  {1} MB/s" -f $mb,[math]::Round($speed,1))
        }
      }
    }

    Write-Host ""
    $fs.Close(); $in.Close(); $resp.Close()
    Move-Item $tmp $OutFile -Force
    OK "Saved: $OutFile"
    return $true
  } catch {
    Write-Host ""
    WRN "Stream download failed: $($_.Exception.Message)"
    return $false
  } finally {
    try { if ($fs) { $fs.Dispose() } } catch {}
    try { if ($in) { $in.Dispose() } } catch {}
    try { if ($resp) { $resp.Dispose() } } catch {}
    try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {}
  }
}


# -----------------------------
# Run capture helper
# -----------------------------
function Invoke-Capture {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string]$Arguments = "",
    [int]$TimeoutSec = 0,
    [string]$WorkDir = ""
  )
  $pinfo = New-Object System.Diagnostics.ProcessStartInfo
  $pinfo.FileName = $FilePath
  $pinfo.Arguments = $Arguments
  $pinfo.UseShellExecute = $false
  $pinfo.RedirectStandardOutput = $true
  $pinfo.RedirectStandardError  = $true
  $pinfo.CreateNoWindow = $true
  if ($WorkDir) { $pinfo.WorkingDirectory = $WorkDir }

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $pinfo

  $null = $p.Start()
  if ($TimeoutSec -gt 0) {
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill() } catch {}
      return [pscustomobject]@{ ExitCode = 124; StdOut=""; StdErr="TIMEOUT"; TimedOut=$true }
    }
  } else {
    $p.WaitForExit() | Out-Null
  }

  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut=$out; StdErr=$err; TimedOut=$false }
}

# -----------------------------
# Context + results
# -----------------------------
$ScriptRoot = Split-Path -Parent $PSCommandPath
$RunStamp   = (Get-Date).ToString("yyyyMMdd-HHmmss")
$OutRoot    = Join-Path $ScriptRoot ("Benchmark-Results\" + $RunStamp)
$ToolsRoot  = Join-Path $ScriptRoot "Tools"
$null = New-Item -ItemType Directory -Path $OutRoot -Force
$null = New-Item -ItemType Directory -Path $ToolsRoot -Force

$TxtReport  = Join-Path $OutRoot "report.txt"
$HtmlReport = Join-Path $OutRoot "report.html"
$MetaJson   = Join-Path $OutRoot "meta.json"

$Global:Results = New-Object System.Collections.ArrayList
function Add-Result {
  param(
    [string]$Category,
    [string]$Name,
    [hashtable]$Metrics,
    [string]$RawText = ""
  )
  $obj = [pscustomobject]@{
    Time     = (Get-Date).ToString("s")
    Category = $Category
    Name     = $Name
    Metrics  = $Metrics
    RawText  = $RawText
  }
  [void]$Global:Results.Add($obj)
}

# -----------------------------
# System inventory
# -----------------------------
function Get-OsInfo {
  $os  = Get-CimInstance Win32_OperatingSystem
  $cs  = Get-CimInstance Win32_ComputerSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $memGB = [Math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
  [pscustomobject]@{
    ScriptVersion = $ScriptVersion
    ComputerName  = $env:COMPUTERNAME
    User          = $env:USERNAME
    OS            = $os.Caption
    Version       = $os.Version
    Build         = $os.BuildNumber
    Arch          = $os.OSArchitecture
    CPU           = $cpu.Name
    Cores         = $cpu.NumberOfCores
    Threads       = $cpu.NumberOfLogicalProcessors
    RAM_GB        = $memGB
  }
}

function Get-GpuInfo {
  try {
    return @(
      Get-CimInstance Win32_VideoController | ForEach-Object {
        [pscustomobject]@{
          Name         = $_.Name
          Driver       = $_.DriverVersion
          RAM_MB       = if ($_.AdapterRAM) { [Math]::Round($_.AdapterRAM/1MB,0) } else { $null }
          PNPDeviceID  = $_.PNPDeviceID
          Status       = $_.Status
        }
      }
    )
  } catch { return @() }
}

function Get-VolumeInfo {
  try {
    return @(
      Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        [pscustomobject]@{
          Drive  = $_.DeviceID
          Label  = $_.VolumeName
          FS     = $_.FileSystem
          SizeGB = if ($_.Size) { [Math]::Round($_.Size/1GB,2) } else { $null }
          FreeGB = if ($_.FreeSpace) { [Math]::Round($_.FreeSpace/1GB,2) } else { $null }
        }
      }
    )
  } catch { return @() }
}

function Detect-PhysicalDisks {
  if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
    try {
      return @(
        Get-PhysicalDisk | ForEach-Object {
          [pscustomobject]@{
            FriendlyName = $_.FriendlyName
            MediaType    = $_.MediaType
            BusType      = $_.BusType
            SizeGB       = [Math]::Round($_.Size/1GB,2)
            HealthStatus = $_.HealthStatus
          }
        }
      )
    } catch {}
  }
  try {
    return @(
      Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk | ForEach-Object {
        [pscustomobject]@{
          FriendlyName = $_.FriendlyName
          MediaType    = $_.MediaType
          BusType      = $_.BusType
          SizeGB       = [Math]::Round($_.Size/1GB,2)
          HealthStatus = $_.HealthStatus
        }
      }
    )
  } catch { return @() }
}

# -----------------------------
# Tool management
# -----------------------------
function Get-ToolPath([string]$Name) {
  Join-Path $ToolsRoot $Name
}

function Ensure-DiskSpd {
  $dir = Get-ToolPath "DiskSpd"
  $exe = Join-Path $dir "amd64\diskspd.exe"
  if (Test-Path $exe) { return $exe }

  if ($NoDownload) { WRN "DiskSpd missing and downloads disabled."; return $null }

  $zip = Join-Path $OutRoot "DiskSpd.zip"
  $url = "https://github.com/microsoft/diskspd/releases/latest/download/DiskSpd.zip"
  if (-not (Invoke-Download $url $zip)) { return $null }
  if (-not (Expand-ZipPortable $zip $dir)) { WRN "DiskSpd zip extract failed."; return $null }

  if (Test-Path $exe) { OK "DiskSpd ready."; return $exe }
  WRN "DiskSpd exe not found after extraction."
  return $null
}

function Ensure-FFmpeg {
  $dir = Get-ToolPath "ffmpeg"
  $exe = Join-Path $dir "ffmpeg.exe"
  $probe = Join-Path $dir "ffprobe.exe"
  if (Test-Path $exe) { return @{ ffmpeg=$exe; ffprobe=$probe } }

  if ($NoDownload) { WRN "FFmpeg missing and downloads disabled."; return $null }

  $zip = Join-Path $OutRoot "ffmpeg-release-essentials.zip"
  $zip = Join-Path $OutRoot "ffmpeg.zip"

$urls = @(
  # gyan.dev essentials: compatible with older Windows (vendor states Win7+) :contentReference[oaicite:0]{index=0}
  "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",

  # GitHub fallback (BtbN). If your network blocks gyan.dev, this often works. :contentReference[oaicite:1]{index=1}
  "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
)

$ok = $false
foreach ($u in $urls) {
  if (Invoke-Download $u $zip) { $ok = $true; break }
}

if (-not $ok) { return $null }

  if (-not (Invoke-Download $url $zip)) { return $null }

  $tmp = Join-Path $OutRoot "ffmpeg_extract"
  $null = New-Item -ItemType Directory -Path $tmp -Force
  if (-not (Expand-ZipPortable $zip $tmp)) { WRN "FFmpeg zip extract failed."; return $null }

  $found = Get-ChildItem -Path $tmp -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $found) { WRN "FFmpeg exe not found after extraction."; return $null }

  $binDir = Split-Path -Parent $found.FullName
  $null = New-Item -ItemType Directory -Path $dir -Force
  Copy-Item (Join-Path $binDir "ffmpeg.exe")  $dir -Force
  if (Test-Path (Join-Path $binDir "ffprobe.exe")) { Copy-Item (Join-Path $binDir "ffprobe.exe") $dir -Force }
  if (Test-Path (Join-Path $binDir "ffplay.exe"))  { Copy-Item (Join-Path $binDir "ffplay.exe")  $dir -Force }

  if (Test-Path $exe) { OK "FFmpeg ready."; return @{ ffmpeg=$exe; ffprobe=$probe } }
  WRN "FFmpeg install failed."
  return $null
}

function Ensure-Procmon {
  $dir = Get-ToolPath "Procmon"
  $exe64 = Join-Path $dir "Procmon64.exe"
  $exe32 = Join-Path $dir "Procmon.exe"
  if (Test-Path $exe64) { return $exe64 }
  if (Test-Path $exe32) { return $exe32 }

  if ($NoDownload) { WRN "Procmon missing and downloads disabled."; return $null }

  $zip = Join-Path $OutRoot "ProcessMonitor.zip"
  $url = "https://download.sysinternals.com/files/ProcessMonitor.zip"
  if (-not (Invoke-Download $url $zip)) { return $null }
  if (-not (Expand-ZipPortable $zip $dir)) { WRN "Procmon zip extract failed."; return $null }

  if (Test-Path $exe64) { OK "Procmon ready."; return $exe64 }
  if (Test-Path $exe32) { OK "Procmon ready."; return $exe32 }
  WRN "Procmon exe not found after extraction."
  return $null
}

function Find-FurMarkExe {
  $candidates = @(
    "$env:ProgramFiles\Geeks3D\FurMark\FurMark.exe",
    "$env:ProgramFiles(x86)\Geeks3D\FurMark\FurMark.exe"
  )
  foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
  return $null
}

# -----------------------------
# Tracing
# -----------------------------
$Global:TraceState = [pscustomobject]@{
  WPRActive = $false
  ProcmonActive = $false
  CountersJob = $null
  CountersOut = $null
  ProcmonExe = $null
  ProcmonPml = $null
  WprEtl = $null
}

function Start-WPR([string]$Tag) {
  $wpr = Join-Path $env:windir "System32\wpr.exe"
  if (-not (Test-Path $wpr)) { WRN "wpr.exe not found. Skipping WPR trace."; return }
  $etl = Join-Path $OutRoot ("trace_" + $Tag + ".etl")
  $Global:TraceState.WprEtl = $etl
  INF "WPR start (GeneralProfile)..."
  try {
    & $wpr -start GeneralProfile -filemode | Out-Null
    $Global:TraceState.WPRActive = $true
    OK "WPR recording started."
  } catch { WRN "WPR start failed: $($_.Exception.Message)" }
}
function Stop-WPR {
  if (-not $Global:TraceState.WPRActive) { return }
  $wpr = Join-Path $env:windir "System32\wpr.exe"
  $etl = $Global:TraceState.WprEtl
  INF "WPR stop -> $etl"
  try {
    & $wpr -stop $etl | Out-Null
    $Global:TraceState.WPRActive = $false
    OK "WPR trace saved."
  } catch { WRN "WPR stop failed: $($_.Exception.Message)" }
}

function Start-ProcmonTrace([string]$Tag) {
  $exe = Ensure-Procmon
  if (-not $exe) { WRN "Procmon unavailable. Skipping Procmon trace."; return }
  $pml = Join-Path $OutRoot ("procmon_" + $Tag + ".pml")
  $Global:TraceState.ProcmonExe = $exe
  $Global:TraceState.ProcmonPml = $pml

  INF "Procmon start (quiet) -> $pml"
  try {
    Start-Process -FilePath $exe -ArgumentList "/AcceptEula","/Quiet","/Minimized","/BackingFile",$pml -WindowStyle Minimized | Out-Null
    $Global:TraceState.ProcmonActive = $true
    OK "Procmon recording started."
  } catch { WRN "Procmon start failed: $($_.Exception.Message)" }
}

function Stop-ProcmonTrace {
  if (-not $Global:TraceState.ProcmonActive) { return }
  $exe = $Global:TraceState.ProcmonExe
  INF "Procmon stop..."
  try {
    & $exe /Terminate | Out-Null
    Start-Sleep -Seconds 2
    & $exe /Terminate | Out-Null
    $Global:TraceState.ProcmonActive = $false
    OK "Procmon trace stopped."
  } catch { WRN "Procmon stop failed: $($_.Exception.Message)" }
}

function Get-CounterSafe([string[]]$Paths) {
  try { Get-Counter -Counter $Paths -ErrorAction Stop } catch { return $null }
}

function Start-Counters([string]$Tag) {
  $csv = Join-Path $OutRoot ("counters_" + $Tag + ".csv")
  $Global:TraceState.CountersOut = $csv

  $paths = @(
    "\Processor(_Total)\% Processor Time",
    "\Memory\Available MBytes",
    "\PhysicalDisk(_Total)\Disk Read Bytes/sec",
    "\PhysicalDisk(_Total)\Disk Write Bytes/sec",
    "\PhysicalDisk(_Total)\Avg. Disk sec/Read",
    "\PhysicalDisk(_Total)\Avg. Disk sec/Write"
  )
  $gpuTry = "\GPU Engine(*)\Utilization Percentage"
  $testGpu = Get-CounterSafe -Paths @($gpuTry)
  if ($testGpu) { $paths += $gpuTry }

  INF "Perf counters capture -> $csv"
  try {
    $job = Start-Job -ScriptBlock {
      param($CounterPaths, $OutFile)
      try {
        while ($true) {
          $c = Get-Counter -Counter $CounterPaths -ErrorAction SilentlyContinue
          if ($c) {
            $t = Get-Date
            foreach ($s in $c.CounterSamples) {
              "{0},{1},{2},{3}" -f $t.ToString("s"), $s.Path.Replace(",",";"), $s.CookedValue, $s.InstanceName.Replace(",",";") |
                Add-Content -Path $OutFile -Encoding UTF8
            }
          }
          Start-Sleep -Seconds 1
        }
      } catch {}
    } -ArgumentList ($paths, $csv)

    $Global:TraceState.CountersJob = $job
    OK "Perf counters started."
  } catch { WRN "Perf counters start failed: $($_.Exception.Message)" }
}

function Stop-Counters {
  $job = $Global:TraceState.CountersJob
  if (-not $job) { return }
  INF "Stopping perf counters..."
  try {
    Stop-Job $job -Force | Out-Null
    Remove-Job $job -Force | Out-Null
    $Global:TraceState.CountersJob = $null
    OK "Perf counters stopped."
  } catch { WRN "Perf counters stop failed: $($_.Exception.Message)" }
}

function Start-Traces([string]$Tag) {
  if ($TraceWPR)      { Start-WPR $Tag }
  if ($TraceProcmon)  { Start-ProcmonTrace $Tag }
  if ($TraceCounters) { Start-Counters $Tag }
}
function Stop-Traces {
  Stop-Counters
  Stop-ProcmonTrace
  Stop-WPR
}

# -----------------------------
# WinSAT
# -----------------------------
function Test-WinSAT([string]$Args, [string]$Name, [string]$Category) {
  $winsat = Join-Path $env:windir "System32\winsat.exe"
  if (-not (Test-Path $winsat)) { WRN "winsat.exe not found. Skipping $Name."; return }

  INF "WinSAT: $Name"
  $r = Invoke-Capture -FilePath $winsat -Arguments $Args -TimeoutSec 0
  $raw = ($r.StdOut + "`n" + $r.StdErr).Trim()

  if ($r.ExitCode -ne 0) {
    WRN "WinSAT '$Name' exit code: $($r.ExitCode)"
  } else {
    OK "WinSAT '$Name' completed."
  }

  $m = @{}
  if ($raw -match "Memory Performance:\s+([\d\.]+)\s+MB/s") { $m["MBps"] = [double]$Matches[1] }
  if ($raw -match "Compression\s+([\d\.]+)\s+MB/s") { $m["Compression_MBps"] = [double]$Matches[1] }
  if ($raw -match "Encryption\s+([\d\.]+)\s+MB/s") { $m["Encryption_MBps"] = [double]$Matches[1] }
  if ($raw -match "Disk\s+Sequential\s+([\d\.]+)\s+MB/s") { $m["DiskSeq_MBps"] = [double]$Matches[1] }
  if ($raw -match "D3D\s+Assessment\s+Score:\s+([\d\.]+)") { $m["D3DScore"] = [double]$Matches[1] }

  Add-Result -Category $Category -Name $Name -Metrics $m -RawText $raw
}

# -----------------------------
# Selection parsing
# -----------------------------
function Parse-SelectionList([string]$Text, [int]$Max) {
  $Text = $Text.Trim().ToLower()
  if ($Text -eq "all") { return 1..$Max }
  $nums = New-Object System.Collections.Generic.List[int]
  $parts = $Text -split "\s*,\s*"
  foreach ($p in $parts) {
    if ($p -match "^\s*(\d+)\s*-\s*(\d+)\s*$") {
      $a=[int]$Matches[1]; $b=[int]$Matches[2]
      if ($a -gt $b) { $t=$a; $a=$b; $b=$t }
      for ($k=$a; $k -le $b; $k++) { if ($k -ge 1 -and $k -le $Max) { $nums.Add($k) } }
    } elseif ($p -match "^\d+$") {
      $k=[int]$p
      if ($k -ge 1 -and $k -le $Max) { $nums.Add($k) }
    }
  }
  $seen=@{}
  $out=@()
  foreach ($n in $nums) { if (-not $seen.ContainsKey($n)) { $seen[$n]=$true; $out+=$n } }
  return $out
}

function Parse-MainSelection([string]$Text) {
  $Text = ($Text -as [string]).Trim().ToLower()
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  if ($Text -eq "all") { return @(1,2,3,4) }
  return @(Parse-SelectionList $Text 4)  # <- force array even for single selection
}


# -----------------------------
# RAM tests
# -----------------------------
function Run-RAM {
  Start-Traces "ram"
  try {
    Write-Rule "RAM Benchmarks"
    Test-WinSAT -Args "mem -v"     -Name "WinSAT mem (bandwidth)"     -Category "RAM"
    if ($Profile -in @("Standard","Extended")) {
      Test-WinSAT -Args "mem -up -v" -Name "WinSAT mem (single-thread)" -Category "RAM"
    }
    if ($Profile -eq "Extended") {
      Test-WinSAT -Args "mem -nc -v" -Name "WinSAT mem (uncached)" -Category "RAM"
    }
  } finally { Stop-Traces }
}

# -----------------------------
# Storage tests
# -----------------------------
function Read-DriveSelection {
  $vols = To-Array (Get-VolumeInfo)
  if (-not $vols -or $vols.Count -eq 0) { return @("C:") }

  Write-Host ""
  W "Available volumes:" $C_INFO
  for ($i=0; $i -lt $vols.Count; $i++) {
    $v = $vols[$i]
    W ("  [{0}] {1}  Label={2}  FS={3}  Free={4}GB / {5}GB" -f ($i+1), $v.Drive, ($v.Label -as [string]), $v.FS, $v.FreeGB, $v.SizeGB) $C_DIM
  }
  W "Select drive(s) to test (e.g. 1,3 or 1-2) or Enter for C:" $C_INFO
  $ans = Read-Host "> "
  if ([string]::IsNullOrWhiteSpace($ans)) { return @("C:") }

  $idx = Parse-SelectionList $ans $vols.Count
  $drives = @()
  foreach ($n in $idx) { $drives += $vols[$n-1].Drive }
  if ($drives.Count -eq 0) { $drives = @("C:") }
  return $drives
}

function Run-DiskSpdProfile {
  param(
    [string]$DiskSpdExe,
    [string]$Drive,
    [string]$Label,
    [string]$Args,
    [int]$TimeoutSec
  )
  $testDir = Join-Path ($Drive + "\") "WinBenchPro_Test"
  $null = New-Item -ItemType Directory -Path $testDir -Force
  $testFile = Join-Path $testDir "diskspd_test.dat"

  $sizeGB = 2
  if ($Profile -eq "Quick") { $sizeGB = 1 }
  if ($Profile -eq "Extended") { $sizeGB = 4 }
  $bytes = $sizeGB * 1GB

  $fullArgs = "$Args -c$bytes `"$testFile`""
  INF "DiskSpd $Label on $Drive"
  $r = Invoke-Capture -FilePath $DiskSpdExe -Arguments $fullArgs -TimeoutSec $TimeoutSec -WorkDir $testDir
  $raw = ($r.StdOut + "`n" + $r.StdErr).Trim()

  $m = @{}
  if ($raw -match "total:\s+IOPS=\s*([\d\.]+)") { $m["IOPS"] = [double]$Matches[1] }
  if ($raw -match "total:\s+.*?MB/s=\s*([\d\.]+)") { $m["MBps"] = [double]$Matches[1] }
  if ($raw -match "avg\.\s+latency:\s+([\d\.]+)ms") { $m["AvgLatency_ms"] = [double]$Matches[1] }
  if ($raw -match "Latency\s+.*?avg:\s+([\d\.]+)ms") { $m["AvgLatency_ms"] = [double]$Matches[1] }

  Add-Result -Category "Storage" -Name ("DiskSpd " + $Label + " (" + $Drive + ")") -Metrics $m -RawText $raw

  if ($Profile -ne "Extended") {
    try { Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  } else {
    INF "Keeping test file(s) for Extended profile: $testDir"
  }
}

function Run-Storage {
  Start-Traces "storage"
  try {
    Write-Rule "Storage Benchmarks"
    $diskspd = Ensure-DiskSpd
    if (-not $diskspd) { WRN "DiskSpd unavailable; WinSAT disk only." }

    $drives = Read-DriveSelection
    foreach ($d in $drives) {
      Test-WinSAT -Args ("disk -drive {0} -v" -f $d.TrimEnd(":")) -Name ("WinSAT disk (" + $d + ")") -Category "Storage"

      if ($diskspd) {
        $dur = 20
        if ($Profile -eq "Standard") { $dur = 30 }
        if ($Profile -eq "Extended") { $dur = 45 }

        Run-DiskSpdProfile -DiskSpdExe $diskspd -Drive $d -Label "SeqRead 1MiB"         -Args ("-b1M -d{0} -o4  -t1 -s -w0   -Sh -L -Z1" -f $dur) -TimeoutSec ($dur + 60)
        Run-DiskSpdProfile -DiskSpdExe $diskspd -Drive $d -Label "SeqWrite 1MiB"        -Args ("-b1M -d{0} -o4  -t1 -s -w100 -Sh -L -Z1" -f $dur) -TimeoutSec ($dur + 60)
        Run-DiskSpdProfile -DiskSpdExe $diskspd -Drive $d -Label "RandRead 4K"          -Args ("-b4K -d{0} -o32 -t4 -r -w0   -Sh -L -Z1" -f $dur) -TimeoutSec ($dur + 60)
        Run-DiskSpdProfile -DiskSpdExe $diskspd -Drive $d -Label "RandWrite 4K"         -Args ("-b4K -d{0} -o32 -t4 -r -w100 -Sh -L -Z1" -f $dur) -TimeoutSec ($dur + 60)
        Run-DiskSpdProfile -DiskSpdExe $diskspd -Drive $d -Label "Mixed 70R/30W 4K"     -Args ("-b4K -d{0} -o32 -t4 -r -w30  -Sh -L -Z1" -f $dur) -TimeoutSec ($dur + 60)
      }
    }

    if ($UseGUI) {
      Write-Host ""
      WRN "GUI note: CrystalDiskMark/others are not reliably script-capturable."
      WRN "This script focuses on repeatable CLI logs (DiskSpd)."
    }
  } finally { Stop-Traces }
}

# -----------------------------
# CPU tests
# -----------------------------
function Ensure-TestClip([string]$FfmpegExe) {
  $clip = Join-Path $OutRoot "input_1080p60_30s.mp4"
  if (Test-Path $clip) { return $clip }

  INF "Generating local test clip (1080p, 60fps, 30s) for repeatable encode benchmarks..."
  $args = ('-hide_banner -y -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 30 -pix_fmt yuv420p -c:v libx264 -preset veryfast -crf 18 "{0}"' -f $clip)
  $r = Invoke-Capture -FilePath $FfmpegExe -Arguments $args -TimeoutSec 0 -WorkDir $OutRoot
  if ($r.ExitCode -ne 0 -or -not (Test-Path $clip)) {
    WRN "Failed to generate test clip. FFmpeg stderr tail:"
    $tail = ($r.StdErr -split "`r?`n")
    $show = ($tail | Select-Object -Last 25) -join "`n"
    W $show $C_DIM
    return $null
  }
  OK "Test clip ready: $clip"
  return $clip
}

function Parse-FFmpegSpeed([string]$Text) {
  $fps = $null
  $speed = $null
  $matches = [regex]::Matches($Text, "fps=\s*([\d\.]+)")
  if ($matches.Count -gt 0) { $fps = [double]$matches[$matches.Count-1].Groups[1].Value }
  $m2 = [regex]::Matches($Text, "speed=\s*([\d\.]+)x")
  if ($m2.Count -gt 0) { $speed = [double]$m2[$m2.Count-1].Groups[1].Value }
  return @{ FPS=$fps; SpeedX=$speed }
}

function Run-FFmpegEncodeTest {
  param(
    [string]$FfmpegExe,
    [string]$Input,
    [string]$Name,
    [string]$VCodecArgs
  )
  INF "FFmpeg encode: $Name"
  $args = ('-hide_banner -y -i "{0}" -an {1} -t 30 -f null NUL' -f $Input, $VCodecArgs)
  $r = Invoke-Capture -FilePath $FfmpegExe -Arguments $args -TimeoutSec 0 -WorkDir $OutRoot
  $raw = ($r.StdOut + "`n" + $r.StdErr).Trim()
  $m = Parse-FFmpegSpeed $raw
  Add-Result -Category "CPU/GPU" -Name ("FFmpeg " + $Name) -Metrics $m -RawText $raw
  if ($r.ExitCode -eq 0) { OK "FFmpeg '$Name' done." } else { WRN "FFmpeg '$Name' exit code: $($r.ExitCode)" }
}

function Get-FFmpegEncoders([string]$FfmpegExe) {
  $r = Invoke-Capture -FilePath $FfmpegExe -Arguments "-hide_banner -encoders" -TimeoutSec 0 -WorkDir $OutRoot
  return ($r.StdOut + "`n" + $r.StdErr)
}

function Run-CPU {
  Start-Traces "cpu"
  try {
    Write-Rule "CPU Benchmarks"
    Test-WinSAT -Args "cpu -compression -v" -Name "WinSAT cpu (compression)" -Category "CPU"
    Test-WinSAT -Args "cpu -encryption -v"  -Name "WinSAT cpu (AES encryption)" -Category "CPU"

    $ff = Ensure-FFmpeg
    if (-not $ff) { WRN "FFmpeg unavailable; skipping real-world encode workload."; return }
    $clip = Ensure-TestClip $ff.ffmpeg
    if (-not $clip) { WRN "No input clip available; skipping encode workload."; return }

    Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "CPU libx264 (veryfast, CRF 23)" -VCodecArgs "-c:v libx264 -preset veryfast -crf 23"
    if ($Profile -eq "Extended") {
      Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "CPU libx264 (slow, CRF 23)" -VCodecArgs "-c:v libx264 -preset slow -crf 23"
    }
  } finally { Stop-Traces }
}

# -----------------------------
# GPU tests
# -----------------------------
function Run-GPU {
  Start-Traces "gpu"
  try {
    Write-Rule "GPU Benchmarks"
    Test-WinSAT -Args "dwm -v" -Name "WinSAT dwm (desktop composition)" -Category "GPU"
    Test-WinSAT -Args "d3d -v -width 1920 -height 1080" -Name "WinSAT d3d (1920x1080)" -Category "GPU"

    $gpus = To-Array (Get-GpuInfo)
    if ($gpus.Count -gt 0) {
      INF "Detected GPU(s):"
      $i=0
      foreach ($g in $gpus) {
        $i++
        W ("  [{0}] {1}  VRAM={2}MB  Driver={3}" -f $i, $g.Name, ($g.RAM_MB -as [string]), ($g.Driver -as [string])) $C_DIM
      }
      Add-Result -Category "GPU" -Name "GPU Inventory" -Metrics @{"Count"=$gpus.Count} -RawText (($gpus | Format-List * | Out-String).Trim())
    } else {
      WRN "No GPU info found via WMI."
    }

    $ff = Ensure-FFmpeg
    if (-not $ff) { WRN "FFmpeg unavailable; skipping GPU encode throughput."; return }
    $clip = Ensure-TestClip $ff.ffmpeg
    if (-not $clip) { WRN "No input clip available; skipping GPU encode throughput."; return }

    $encText = Get-FFmpegEncoders $ff.ffmpeg
    $haveNV  = ($encText -match "h264_nvenc")
    $haveQSV = ($encText -match "h264_qsv")
    $haveAMF = ($encText -match "h264_amf")

    Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "CPU libx264 baseline (veryfast, CRF 23)" -VCodecArgs "-c:v libx264 -preset veryfast -crf 23"

    if ($haveNV) {
      Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "GPU NVIDIA NVENC (h264_nvenc, p4, 8M)" -VCodecArgs "-c:v h264_nvenc -preset p4 -b:v 8M"
      if ($Profile -eq "Extended") {
        Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "GPU NVIDIA NVENC (hevc_nvenc, p4, 8M)" -VCodecArgs "-c:v hevc_nvenc -preset p4 -b:v 8M"
      }
    } else { INF "NVENC not detected in FFmpeg encoders." }

    if ($haveQSV) {
      Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "GPU Intel QSV (h264_qsv, quality=23)" -VCodecArgs "-c:v h264_qsv -global_quality 23"
      if ($Profile -eq "Extended") {
        Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "GPU Intel QSV (hevc_qsv, quality=23)" -VCodecArgs "-c:v hevc_qsv -global_quality 23"
      }
    } else { INF "QSV not detected in FFmpeg encoders." }

    if ($haveAMF) {
      Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "GPU AMD AMF (h264_amf, quality=balanced)" -VCodecArgs "-c:v h264_amf -quality balanced"
      if ($Profile -eq "Extended") {
        Run-FFmpegEncodeTest -FfmpegExe $ff.ffmpeg -Input $clip -Name "GPU AMD AMF (hevc_amf, quality=balanced)" -VCodecArgs "-c:v hevc_amf -quality balanced"
      }
    } else { INF "AMF not detected in FFmpeg encoders." }

    if ($UseGUI) {
      $fur = Find-FurMarkExe
      if ($fur) {
        Write-Host ""
        WRN "FurMark detected: $fur"
        WRN "This can push thermals hard. Use at your own risk."
        $durMs = if ($Profile -eq "Quick") { 30000 } elseif ($Profile -eq "Standard") { 60000 } else { 90000 }
        INF "Running FurMark benchmark (nogui) for $durMs ms..."
        $args = "/nogui /nomenubar /run_mode=1 /width=1920 /height=1080 /msaa=0 /max_time=$durMs /log_score"
        $r = Invoke-Capture -FilePath $fur -Arguments $args -TimeoutSec ([Math]::Ceiling($durMs/1000)+120)
        $raw = ($r.StdOut + "`n" + $r.StdErr).Trim()
        Add-Result -Category "GPU" -Name "FurMark Benchmark (1080p)" -Metrics @{} -RawText $raw
        OK "FurMark run completed."
      } else {
        INF "FurMark not found. Install it and rerun with -UseGUI to include it."
      }
    }

  } finally { Stop-Traces }
}

# -----------------------------
# Reporting
# -----------------------------
function Render-TerminalSummary {
  Write-Rule "Summary (Key Metrics)"
  $rows = @()

  foreach ($r in $Global:Results) {
    $cat = $r.Category
    $name = $r.Name
    $m = $r.Metrics
    if ($m -and $m.Count -gt 0) {
      $flat = ($m.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join " | "
      $rows += [pscustomobject]@{ Category=$cat; Test=$name; Metrics=$flat }
    }
  }

  if ($rows.Count -eq 0) {
    WRN "No parsed metrics available (raw logs still saved)."
    return
  }

  $maxCat = ($rows | ForEach-Object { $_.Category.Length } | Measure-Object -Maximum).Maximum
  $maxTest= ($rows | ForEach-Object { $_.Test.Length } | Measure-Object -Maximum).Maximum
  foreach ($row in $rows) {
    W (("{0,-$maxCat}  {1,-$maxTest}  {2}" -f $row.Category, $row.Test, $row.Metrics)) $C_DIM
  }
}
function Render-ShortSummary {
  Write-Rule "Short Summary"

  # Helper: find first matching test result by name contains text
  function Find-One([string]$contains) {
    foreach ($r in $Global:Results) {
      if (($r.Name -as [string]) -and $r.Name.ToLower().Contains($contains.ToLower())) { return $r }
    }
    return $null
  }

  # RAM
  $ram = Find-One "winsat mem (bandwidth)"
  if ($ram -and $ram.Metrics.ContainsKey("MBps")) {
    OK ("RAM bandwidth: {0} MB/s (WinSAT)" -f $ram.Metrics["MBps"])
  } else {
    WRN "RAM bandwidth: N/A"
  }

  # Storage: pick best DiskSpd SeqRead across drives, if present
  $seqReads = @()
  foreach ($r in $Global:Results) {
    if (($r.Name -as [string]) -and $r.Name -match "DiskSpd SeqRead 1MiB") {
      if ($r.Metrics -and $r.Metrics.ContainsKey("MBps")) { $seqReads += $r }
    }
  }
  if ($seqReads.Count -gt 0) {
    $best = $seqReads | Sort-Object { $_.Metrics["MBps"] } -Descending | Select-Object -First 1
    OK ("Storage best SeqRead: {0} MB/s  ({1})" -f $best.Metrics["MBps"], $best.Name)
  } else {
    # fallback: WinSAT disk
    $wd = Find-One "winsat disk"
    if ($wd -and $wd.Metrics.ContainsKey("DiskSeq_MBps")) {
      OK ("Storage sequential: {0} MB/s (WinSAT)" -f $wd.Metrics["DiskSeq_MBps"])
    } else {
      WRN "Storage sequential: N/A"
    }
  }

  # CPU: pick libx264 baseline
  $cpu = Find-One "ffmpeg cpu libx264 (veryfast"
  if ($cpu -and $cpu.Metrics.ContainsKey("FPS")) {
    OK ("CPU encode (x264 veryfast): {0} fps | {1}x" -f $cpu.Metrics["FPS"], $cpu.Metrics["SpeedX"])
  } else {
    WRN "CPU encode (x264): N/A"
  }

  # GPU: best hardware encoder (NVENC/QSV/AMF) if present
  $gpuEnc = @()
  foreach ($r in $Global:Results) {
    if (($r.Name -as [string]) -and ($r.Name -match "FFmpeg GPU")) {
      if ($r.Metrics -and $r.Metrics.ContainsKey("FPS")) { $gpuEnc += $r }
    }
  }
  if ($gpuEnc.Count -gt 0) {
    $bestG = $gpuEnc | Sort-Object { $_.Metrics["FPS"] } -Descending | Select-Object -First 1
    OK ("GPU encode best: {0} fps | {1}x  ({2})" -f $bestG.Metrics["FPS"], $bestG.Metrics["SpeedX"], $bestG.Name)
  } else {
    INF "GPU encode: no HW encoder test available (NVENC/QSV/AMF not detected or FFmpeg missing)."
  }

  # Artifacts quick pointers
  W "" $C_DIM
  INF ("TXT  : {0}" -f $TxtReport)
  INF ("HTML : {0}" -f $HtmlReport)
  if ($Global:TraceState.CountersOut) { INF ("Counters: {0}" -f $Global:TraceState.CountersOut) }
  if ($Global:TraceState.WprEtl)      { INF ("WPR ETL : {0}" -f $Global:TraceState.WprEtl) }
  if ($Global:TraceState.ProcmonPml)  { INF ("Procmon : {0}" -f $Global:TraceState.ProcmonPml) }
}

function Save-TextReport {
  $os  = Get-OsInfo
  $gpu = To-Array (Get-GpuInfo)
  $vol = To-Array (Get-VolumeInfo)
  $pd  = To-Array (Detect-PhysicalDisks)

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine(("="*78))
  [void]$sb.AppendLine(("Windows-Scripts | WinBench-Pro v{0}  {1}" -f $ScriptVersion, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")))
  [void]$sb.AppendLine(("Author: Shourav (rhshourav) | GitHub: https://github.com/rhshourav"))
  [void]$sb.AppendLine(("="*78))
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("System:")
  [void]$sb.AppendLine((($os | Format-List * | Out-String).Trim()))
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("GPU:")
  [void]$sb.AppendLine((($gpu | Format-Table -AutoSize | Out-String).Trim()))
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("Volumes:")
  [void]$sb.AppendLine((($vol | Format-Table -AutoSize | Out-String).Trim()))
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("Physical Disks (best-effort):")
  [void]$sb.AppendLine((($pd | Format-Table -AutoSize | Out-String).Trim()))
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine(("="*78))
  [void]$sb.AppendLine("Results:")
  [void]$sb.AppendLine(("="*78))
  [void]$sb.AppendLine("")

  foreach ($r in $Global:Results) {
    [void]$sb.AppendLine(("--- [{0}] {1} --- {2}" -f $r.Category, $r.Name, $r.Time))
    if ($r.Metrics -and $r.Metrics.Count -gt 0) {
      [void]$sb.AppendLine("Metrics:")
      foreach ($k in ($r.Metrics.Keys | Sort-Object)) {
        [void]$sb.AppendLine(("  {0}: {1}" -f $k, $r.Metrics[$k]))
      }
    }
    if ($r.RawText) {
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("Raw:")
      [void]$sb.AppendLine($r.RawText)
    }
    [void]$sb.AppendLine("")
  }

  [IO.File]::WriteAllText($TxtReport, $sb.ToString(), [Text.Encoding]::UTF8)
  OK "TXT report saved: $TxtReport"
}

function Html-Escape {
  param([string]$s)
  if ($null -eq $s) { return "" }
  try {
    if (-not ("System.Web.HttpUtility" -as [type])) {
      Add-Type -AssemblyName System.Web -ErrorAction Stop | Out-Null
    }
    return [System.Web.HttpUtility]::HtmlEncode($s)
  } catch {
    return [System.Security.SecurityElement]::Escape($s)
  }
}

function Save-HtmlReport {
  $os  = Get-OsInfo
  $gpu = To-Array (Get-GpuInfo)
  $vol = To-Array (Get-VolumeInfo)
  $pd  = To-Array (Detect-PhysicalDisks)

  $css = @"
body{font-family:Segoe UI,Arial,sans-serif;margin:20px;background:#0b0f14;color:#e6edf3}
h1,h2{margin:0 0 10px 0}
.card{background:#121821;border:1px solid #223043;border-radius:10px;padding:14px;margin:12px 0}
pre{white-space:pre-wrap;background:#0b0f14;border:1px solid #223043;border-radius:8px;padding:10px;overflow:auto}
table{border-collapse:collapse;width:100%}
th,td{border-bottom:1px solid #223043;padding:8px;text-align:left;vertical-align:top}
.small{color:#9fb0c0;font-size:12px}
.tag{display:inline-block;padding:2px 8px;border:1px solid #223043;border-radius:999px;margin-right:6px;color:#9fb0c0}
"@

  $sysBlock = Html-Escape ((($os  | Format-List * | Out-String).Trim()))
  $gpuBlock = Html-Escape ((($gpu | Format-Table -AutoSize | Out-String).Trim()))
  $volBlock = Html-Escape ((($vol | Format-Table -AutoSize | Out-String).Trim()))
  $pdBlock  = Html-Escape ((($pd  | Format-Table -AutoSize | Out-String).Trim()))

  $rows = New-Object System.Text.StringBuilder

  foreach ($r in $Global:Results) {
    $mHtml = ""
    if ($r.Metrics -and $r.Metrics.Count -gt 0) {
      $mHtml = "<table><tr><th>Metric</th><th>Value</th></tr>"
      foreach ($k in ($r.Metrics.Keys | Sort-Object)) {
        $mHtml += "<tr><td>" + (Html-Escape $k) + "</td><td>" + (Html-Escape ([string]$r.Metrics[$k])) + "</td></tr>"
      }
      $mHtml += "</table>"
    } else {
      $mHtml = "<div class='small'>No parsed metrics (see raw output).</div>"
    }

    $raw  = Html-Escape ($r.RawText)
    $name = Html-Escape ($r.Name)

    [void]$rows.AppendLine(@"
<div class="card">
  <div class="small"><span class="tag">$(Html-Escape $($r.Category))</span> $(Html-Escape $($r.Time))</div>
  <h2>$name</h2>
  $mHtml
  <h3 class="small">Raw Output</h3>
  <pre>$raw</pre>
</div>
"@)
  }

  $html = @"
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>WinBench-Pro Report</title>
<style>$css</style>
</head>
<body>
<h1>Windows-Scripts | WinBench-Pro v$(Html-Escape $ScriptVersion)</h1>
<div class="small">Author: Shourav (rhshourav) | GitHub: https://github.com/rhshourav</div>
<div class="small">Generated: $(Html-Escape $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss")))</div>

<div class="card"><h2>System</h2><pre>$sysBlock</pre></div>
<div class="card"><h2>GPU</h2><pre>$gpuBlock</pre></div>
<div class="card"><h2>Volumes</h2><pre>$volBlock</pre></div>
<div class="card"><h2>Physical Disks (best-effort)</h2><pre>$pdBlock</pre></div>

$($rows.ToString())

<div class="card">
  <h2>Artifacts</h2>
  <pre>
TXT: $(Html-Escape $TxtReport)
Perf counters: $(Html-Escape $($Global:TraceState.CountersOut))
WPR ETL: $(Html-Escape $($Global:TraceState.WprEtl))
Procmon PML: $(Html-Escape $($Global:TraceState.ProcmonPml))
  </pre>
</div>

</body></html>
"@

  [IO.File]::WriteAllText($HtmlReport, $html, [Text.Encoding]::UTF8)
  OK "HTML report saved: $HtmlReport"
}

function Save-Meta {
  $meta = [pscustomobject]@{
    ScriptVersion = $ScriptVersion
    RunStamp = $RunStamp
    OutRoot  = $OutRoot
    Profile  = $Profile
    Report   = $Report
    TraceWPR = [bool]$TraceWPR
    TraceProcmon = [bool]$TraceProcmon
    TraceCounters = [bool]$TraceCounters
    ResultsCount = $Global:Results.Count
  }
  $meta | ConvertTo-Json -Depth 6 | Out-File -FilePath $MetaJson -Encoding UTF8
}

# -----------------------------
# Menu
# -----------------------------
function Show-MainMenu {
  Write-Rule ("Windows-Scripts | WinBench-Pro v{0} (PS 5.0/5.1)" -f $ScriptVersion)
  W ("Output Dir : {0}" -f $OutRoot) $C_DIM
  W ("Profile    : {0}" -f $Profile) $C_DIM
  W ("Report     : {0}" -f $Report) $C_DIM
  W ("Tracing    : WPR={0} Procmon={1} Counters={2}" -f [bool]$TraceWPR, [bool]$TraceProcmon, [bool]$TraceCounters) $C_DIM
  Write-Host ""
  W "Select test groups (examples: 1 | 1,2 | 1-4 | all):" $C_INFO
  W "  [1] RAM" $C_HDR
  W "  [2] Storage (DiskSpd + WinSAT disk)" $C_HDR
  W "  [3] CPU (WinSAT cpu + FFmpeg x264 real encode)" $C_HDR
  W "  [4] GPU (WinSAT + FFmpeg HW encode; optional FurMark if installed)" $C_HDR
  Write-Host ""
}

# -----------------------------
# Main
# -----------------------------
Ensure-Admin

try { Start-Transcript -Path (Join-Path $OutRoot "transcript.txt") -Force | Out-Null } catch {}

try {
  Show-MainMenu

  if ([string]::IsNullOrWhiteSpace($Selection)) {
    $Selection = Read-Host "> "
  }
  $sel = @(Parse-MainSelection $Selection)   # <- force array
if ($sel.Count -eq 0) {
    WRN "No selection provided. Defaulting to: all"
    $sel = @(1,2,3,4)
  }

  $os = Get-OsInfo
  Add-Result -Category "System" -Name "OS/CPU/RAM Snapshot" -Metrics @{} -RawText ((($os | Format-List * | Out-String).Trim()))
  Add-Result -Category "System" -Name "Physical Disks Snapshot" -Metrics @{} -RawText (((Detect-PhysicalDisks | Format-Table -AutoSize | Out-String).Trim()))

  foreach ($n in $sel) {
    switch ($n) {
      1 { Run-RAM }
      2 { Run-Storage }
      3 { Run-CPU }
      4 { Run-GPU }
    }
  }

  Render-TerminalSummary
Render-ShortSummary


  if ($Report -in @("Text","Both")) { Save-TextReport }
  if ($Report -in @("Html","Both")) { Save-HtmlReport }
  Save-Meta

  Write-Rule "Done"
  OK "Results directory: $OutRoot"
  if (Test-Path $TxtReport)  { INF "TXT : $TxtReport" }
  if (Test-Path $HtmlReport) { INF "HTML: $HtmlReport" }

  if ($Report -in @("Html","Both")) {
    W ""
    W "Open HTML report now? (Y/N)" $C_INFO
    $a = Read-Host "> "
    if ($a -match "^(y|yes)$") {
      try { Start-Process $HtmlReport | Out-Null } catch {}
    }
  }

} finally {
  try { Stop-Transcript | Out-Null } catch {}
}
