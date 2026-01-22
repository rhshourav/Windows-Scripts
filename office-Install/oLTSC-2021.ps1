<#
  Office LTSC 2021 Auto-Installer (ODT ZIP)
  - Downloads your OLTSC-2021.zip (setup.exe + Configuration.xml)
  - Extracts to temp
  - Runs: setup.exe /configure Configuration.xml
  - Shows a live spinner + status output (no prompts)
  - Writes log
  - Cleans up at the end
#>

#region Admin check
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
  Write-Host "[!] Run this script as Administrator." -ForegroundColor Red
  exit 1
}
#endregion
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

#region Globals
$ZipUrl     = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/OLTSC-2021.zip"
$BaseDir    = Join-Path $env:TEMP ("OLTSC2021_" + [Guid]::NewGuid().ToString("N"))
$ZipPath    = Join-Path $BaseDir "OLTSC-2021.zip"
$LogPath    = Join-Path $BaseDir ("install_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
$ErrorActionPreference = "Stop"
#endregion

#region UI helpers
function Write-Banner {
  Clear-Host
  $line = ("=" * 70)
  Write-Host $line -ForegroundColor DarkCyan
  Write-Host "  Office LTSC 2021 Auto-Installer (ODT ZIP)  |  rhshourav" -ForegroundColor Cyan
  Write-Host $line -ForegroundColor DarkCyan
  Write-Host "  WorkDir: $BaseDir" -ForegroundColor DarkGray
  Write-Host "  Log   : $LogPath" -ForegroundColor DarkGray
  Write-Host ""
}

function Fail($msg, [int]$code = 1) {
  Write-Host "[X] $msg" -ForegroundColor Red
  Write-Host "[i] Log (if created): $LogPath" -ForegroundColor DarkGray
  try { if (Test-Path $BaseDir) { Write-Host "[i] Leaving workdir for inspection: $BaseDir" -ForegroundColor Yellow } } catch {}
  exit $code
}

function Step($msg) { Write-Host "[*] $msg" -ForegroundColor Yellow }
function Ok($msg)   { Write-Host "[+] $msg" -ForegroundColor Green }
#endregion

Write-Banner

try {
  # Create working dir
  New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

  # Download
  Step "Downloading OLTSC-2021.zip..."
  Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
  Ok "Downloaded."

  # Extract
  Step "Extracting..."
  Expand-Archive -Path $ZipPath -DestinationPath $BaseDir -Force
  Ok "Extracted."

  # Locate setup.exe + config
  $SetupExe = Get-ChildItem -Path $BaseDir -Recurse -File -Filter "setup.exe" | Select-Object -First 1
  $ConfigXml = Get-ChildItem -Path $BaseDir -Recurse -File -Filter "Configuration.xml" | Select-Object -First 1

  if (-not $SetupExe) { Fail "setup.exe not found after extraction." }
  if (-not $ConfigXml) { Fail "Configuration.xml not found after extraction." }

  Step "Using setup.exe: $($SetupExe.FullName)"
  Step "Using config   : $($ConfigXml.FullName)"

  # OPTIONAL: enforce silent display in XML if missing (no prompts)
  # Office setup respects <Display Level="None" AcceptEULA="TRUE" />
  # If your XML already has it, we leave it alone.
  $xmlText = Get-Content -LiteralPath $ConfigXml.FullName -Raw
  if ($xmlText -notmatch "<Display\b") {
    Step "Config has no <Display .../>. Injecting silent display (Level=None, AcceptEULA=TRUE)..."
    # insert before closing </Configuration>
    $inject = "  <Display Level=`"None`" AcceptEULA=`"TRUE`" />`r`n"
    $xmlText = $xmlText -replace "</Configuration>", ($inject + "</Configuration>")
    Set-Content -LiteralPath $ConfigXml.FullName -Value $xmlText -Encoding UTF8
    Ok "Updated Configuration.xml for silent mode."
  } else {
    Ok "Display element already present; leaving XML unchanged."
  }

  # Run installer
  Step "Starting Office install (ODT /configure)..."
  Step "This can look 'stuck' while it downloads. Watch the spinner; check log if needed."

  $args = "/configure `"$($ConfigXml.FullName)`""
  $proc = Start-Process -FilePath $SetupExe.FullName -ArgumentList $args -PassThru -WindowStyle Hidden

  # Spinner while running
  $spin = @('|','/','-','\')
  $i = 0
  while (-not $proc.HasExited) {
    $ch = $spin[$i % $spin.Count]
    Write-Host -NoNewline ("`r[>] Installing... {0}  (PID {1})" -f $ch, $proc.Id) -ForegroundColor Cyan
    Start-Sleep -Milliseconds 250
    $i++
  }
  Write-Host "`r[>] Installing... done.                 " -ForegroundColor Cyan

  # Exit code check
  $exit = $proc.ExitCode
  if ($exit -ne 0) {
    Fail "ODT setup.exe exited with code $exit. Installation may have failed." 2
  }
  Ok "Office LTSC 2021 install process finished (exit code 0)."

  # Basic verification (best-effort)
  Step "Quick verification..."
  $office16 = Join-Path ${env:ProgramFiles} "Microsoft Office\Office16\WINWORD.EXE"
  $office16x86 = Join-Path ${env:ProgramFiles(x86)} "Microsoft Office\Office16\WINWORD.EXE"
  if (Test-Path $office16 -or Test-Path $office16x86) {
    Ok "Detected Office binaries (Word)."
  } else {
    Write-Host "[!] Could not confirm WINWORD.EXE in default path. Install may still be OK." -ForegroundColor Yellow
  }

  # Cleanup
  Step "Cleaning up..."
  Remove-Item -LiteralPath $BaseDir -Recurse -Force
  Ok "Cleanup complete."

  Write-Host ""
  Ok "Done. Launch Word/Excel to confirm."
  exit 0
}
catch {
  Fail $_.Exception.Message 3
}
