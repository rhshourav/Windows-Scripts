<#
  Copy-TokenToClipboard.ps1 (Windows PowerShell 5.1+ / Windows 10 → Windows 11)

  Reads a text file in the SAME directory as this script, copies its content to
  clipboard, then shows a popup: "Site token is copied to clipboard."

  Usage:
    powershell -ExecutionPolicy Bypass -File .\Copy-TokenToClipboard.ps1
    powershell -ExecutionPolicy Bypass -File .\Copy-TokenToClipboard.ps1 -FileName "token.txt"

  Exit codes:
    0 = success
    1 = file not found / invalid
    2 = read failed / empty
    3 = clipboard failed
#>

[CmdletBinding()]
param(
  [string]$FileName = "token.txt",

  [string]$Title = "Clipboard",

  [string]$Message = "Site token is copied to clipboard.",

  [int]$TimeoutSeconds = 5,

  [switch]$Trim
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-ScriptDir {
  # Works for "run from file". If launched via IEX, $PSScriptRoot is empty and this cannot be trusted.
  if ($PSScriptRoot) { return $PSScriptRoot }
  if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
  return (Get-Location).Path
}

function Show-Popup {
  param([string]$Text, [string]$Caption, [int]$TimeoutSec)

  # Try WinForms MessageBox first (best UX). Implement timeout via timer.
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(1, $TimeoutSec) * 1000
    $timer.Add_Tick({
      try {
        $open = [System.Windows.Forms.Application]::OpenForms
        if ($open -and $open.Count -gt 0) { $open[0].Close() }
      } catch {}
      $timer.Stop()
      $timer.Dispose()
    })
    $timer.Start()
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Caption, 'OK', 'Information')
    return
  } catch {
    # Fallback: WScript popup supports timeout
    try {
      $ws = New-Object -ComObject WScript.Shell
      [void]$ws.Popup($Text, [Math]::Max(1, $TimeoutSec), $Caption, 64)
      return
    } catch {
      Write-Host $Text
    }
  }
}

function Copy-ToClipboard {
  param([string]$TextToCopy)

  # Preferred: Set-Clipboard
  try {
    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
      Set-Clipboard -Value $TextToCopy
      return $true
    }
  } catch {}

  # Fallback: WinForms clipboard
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.Clipboard]::SetText($TextToCopy)
    return $true
  } catch {}

  # Last fallback: clip.exe
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c clip"
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($TextToCopy)
    $p.StandardInput.Close()
    $p.WaitForExit()

    return ($p.ExitCode -eq 0)
  } catch {
    return $false
  }
}

# -----------------------------
# Resolve file in same dir
# -----------------------------
$scriptDir = Get-ScriptDir
$tokenPath = Join-Path -Path $scriptDir -ChildPath $FileName

if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
  Show-Popup -Text "Token file not found:`n$tokenPath" -Caption "Error" -TimeoutSec 8
  Write-Error "File not found: $tokenPath"
  exit 1
}

# -----------------------------
# Read content
# -----------------------------
try {
  $content = Get-Content -LiteralPath $tokenPath -Raw -ErrorAction Stop
  if ($Trim) { $content = $content.Trim() }
} catch {
  Show-Popup -Text "Failed to read token file:`n$tokenPath" -Caption "Error" -TimeoutSec 8
  Write-Error "Failed to read file: $tokenPath"
  exit 2
}

if ([string]::IsNullOrWhiteSpace($content)) {
  Show-Popup -Text "Token file is empty:`n$tokenPath" -Caption "Error" -TimeoutSec 8
  Write-Error "File is empty/whitespace: $tokenPath"
  exit 2
}

# -----------------------------
# Copy + notify
# -----------------------------
if (-not (Copy-ToClipboard -TextToCopy $content)) {
  Show-Popup -Text "Failed to copy token to clipboard." -Caption "Error" -TimeoutSec 8
  Write-Error "Clipboard copy failed."
  exit 3
}

Show-Popup -Text $Message -Caption $Title -TimeoutSec $TimeoutSeconds
exit 0
