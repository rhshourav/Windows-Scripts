<#
  Windows Photos "Invalid Value for Registry" Fix + Default App Associations Auto-Apply
  Part of: Windows-Scripts
  Author : rhshourav
  GitHub : https://github.com/rhshourav/Windows-Scripts

  - Auto-detect OS + installed apps
  - Downloads matching XML (and optional REG) from:
    https://api.github.com/repos/rhshourav/Windows-Scripts/contents/Windows-Photo-Invalid-Reg-Value/File%20Associations?ref=main
  - Applies DefaultAssociationsConfiguration policy + DISM import
  - Clears per-user broken UserChoice keys for common image extensions
  - Resets/repairs Microsoft Photos (terminate, clear LocalState, re-register)
  - Auto-elevates (safe for: iex (irm ...))
#>

[CmdletBinding()]
param(
  [string]$ForceConfig = "",        # e.g. "Win11_ImageGlass+VLC+7zip+Acrobat.xml"
  [switch]$SkipPhotosRepair,
  [switch]$SkipDefaultApps,
  [switch]$SkipWsReset,
  [switch]$DeepRepair               # runs DISM RestoreHealth + SFC (optional)
)

# -----------------------------
# UI + helpers (theme like your other scripts)
# -----------------------------
# Enable ANSI colors (best-effort)
for ($i=0; $i -lt 1; $i++) {
  try { $script:ESC = [char]27 } catch {}
}

function Say($msg, $color="Gray") { Write-Host $msg -ForegroundColor $color }
function Bar { Say ("=" * 78) "DarkGray" }

function Banner {
  try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
  } catch {}

  Bar
  Say "  Windows Photos Fix + Default Associations Auto-Apply" "White"
  Say "  Author: rhshourav  |  Repo: Windows-Scripts" "DarkGray"
  Say "  GitHub : https://github.com/rhshourav/Windows-Scripts" "DarkGray"
  Bar
  Say ""
}

function Convert-BoundParamsToString {
  param([hashtable]$Bound)

  if (-not $Bound -or $Bound.Count -eq 0) { return "" }

  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($k in $Bound.Keys) {
    $v = $Bound[$k]
    if ($v -is [System.Management.Automation.SwitchParameter]) {
      if ($v.IsPresent) { $parts.Add("-$k") }
    }
    elseif ($null -eq $v) {
      # skip
    }
    elseif ($v -is [string]) {
      $escaped = $v.Replace('"','\"')
      $parts.Add("-$k `"$escaped`"")
    }
    else {
      $parts.Add("-$k $v")
    }
  }
  return ($parts -join " ")
}

# -----------------------------
# Auto-elevate (works for .ps1 and iex(irm ...))
# -----------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
  Banner
  Say "[*] Elevation required. Relaunching as Administrator..." "Yellow"

  $argString = Convert-BoundParamsToString -Bound $PSBoundParameters

  $psExe = $null
  try { $psExe = (Get-Process -Id $PID -ErrorAction Stop).Path } catch {}
  if (-not $psExe) {
    $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
  }

  $scriptPath = $PSCommandPath

  if ($scriptPath -and (Test-Path $scriptPath)) {
    # Running from a file
    $startArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $argString"
    Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $startArgs | Out-Null
    return
  }

  # Running from iex(irm ...) or in-memory: write the current script block to a temp .ps1
  $tmp = Join-Path $env:TEMP ("Windows_Photos_Fix_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".ps1")
  try {
    $content = $MyInvocation.MyCommand.Definition
    if (-not $content -or $content.Trim().Length -lt 50) {
      throw "Could not capture script content for elevation."
    }
    [System.IO.File]::WriteAllText($tmp, $content, [System.Text.Encoding]::UTF8)
  } catch {
    Say "[!] Elevation failed: $($_.Exception.Message)" "Red"
    Say "    Run PowerShell as Administrator and re-run the same command." "Yellow"
    return
  }

  $startArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`" $argString"
  Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $startArgs | Out-Null
  return
}

# -----------------------------
# Main banner (now elevated)
# -----------------------------
Banner

# Ensure TLS 1.2 for older builds
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Invoke-RetryWeb {
  param(
    [Parameter(Mandatory=$true)][string]$Uri,
    [int]$Retries = 3
  )
  $headers = @{
    "User-Agent" = "Windows-Photo-Fix-Script"
    "Accept"     = "application/vnd.github+json"
  }

  for ($i=1; $i -le $Retries; $i++) {
    try {
      return Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET -ErrorAction Stop
    } catch {
      if ($i -eq $Retries) { throw }
      Start-Sleep -Seconds (2 * $i)
    }
  }
}

function Download-File {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$OutFile
  )

  $headers = @{ "User-Agent" = "Windows-Photo-Fix-Script" }

  try {
    Invoke-WebRequest -Uri $Url -Headers $headers -OutFile $OutFile -UseBasicParsing -ErrorAction Stop | Out-Null
    return
  } catch {
    # Fallback for older / locked-down environments
    try {
      $wc = New-Object System.Net.WebClient
      $wc.Headers["User-Agent"] = "Windows-Photo-Fix-Script"
      $wc.DownloadFile($Url, $OutFile)
      return
    } catch {
      throw
    }
  }
}

function Test-Installed {
  param([string[]]$Paths, [string[]]$RegDisplayNameLike)

  foreach ($p in $Paths) {
    if ($p -and (Test-Path $p)) { return $true }
  }

  if ($RegDisplayNameLike -and $RegDisplayNameLike.Count -gt 0) {
    $uninstallRoots = @(
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($root in $uninstallRoots) {
      try {
        $apps = Get-ItemProperty $root -ErrorAction SilentlyContinue
        foreach ($pattern in $RegDisplayNameLike) {
          if ($apps | Where-Object { $_.DisplayName -like $pattern }) { return $true }
        }
      } catch {}
    }
  }

  return $false
}

function Get-OSProfile {
  $os = Get-CimInstance Win32_OperatingSystem
  $caption = $os.Caption
  $build   = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber

  if ($caption -match "Windows 11") { return "Win11" }
  if ($caption -match "Windows 10") { return "Win10" }
  if ($caption -match "Windows Server") {
    if ($caption -match "2019") { return "Win2019" }
    if ($caption -match "2022") { return "Win2022" }
    return "WinServer"
  }
  if ($build -ge 22000) { return "Win11" }
  return "Win10"
}

function Get-AppTags {
  $isVLC = Test-Installed `
    -Paths @("$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "$env:ProgramFiles(x86)\VideoLAN\VLC\vlc.exe") `
    -RegDisplayNameLike @("*VLC media player*")

  $is7zip = Test-Installed `
    -Paths @("$env:ProgramFiles\7-Zip\7zFM.exe", "$env:ProgramFiles(x86)\7-Zip\7zFM.exe") `
    -RegDisplayNameLike @("*7-Zip*")

  $isNanaZip = $false
  try { $isNanaZip = [bool](Get-AppxPackage -Name "40174MouriNaruto.NanaZip" -ErrorAction SilentlyContinue) } catch {}

  $isImageGlass = Test-Installed `
    -Paths @("$env:ProgramFiles\ImageGlass\ImageGlass.exe", "$env:ProgramFiles(x86)\ImageGlass\ImageGlass.exe") `
    -RegDisplayNameLike @("*ImageGlass*")

  $isAcrobat = Test-Installed `
    -Paths @("$env:ProgramFiles\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe",
             "$env:ProgramFiles(x86)\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe",
             "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
             "$env:ProgramFiles(x86)\Adobe\Acrobat DC\Acrobat\Acrobat.exe") `
    -RegDisplayNameLike @("*Adobe Acrobat*","*Adobe Acrobat Reader*")

  $isFoxit = Test-Installed `
    -Paths @("$env:ProgramFiles\Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe",
             "$env:ProgramFiles(x86)\Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe") `
    -RegDisplayNameLike @("*Foxit PDF*","*Foxit Reader*")

  $tags = @()
  if ($isImageGlass) { $tags += "ImageGlass" }
  if ($isVLC)        { $tags += "VLC" }
  if ($isNanaZip)    { $tags += "NanaZip" }
  elseif ($is7zip)   { $tags += "7zip" }
  if ($isAcrobat)    { $tags += "AdobeAcrobat" }
  elseif ($isFoxit)  { $tags += "Foxit" }

  return ,$tags
}

function Pick-BestConfig {
  param(
    [string]$OsPrefix,
    [string[]]$Tags,
    [array]$RepoItems
  )

  $xmlItems = $RepoItems | Where-Object { $_.name -match "\.xml$" }

  if ($ForceConfig) {
    $forced = $xmlItems | Where-Object { $_.name -eq $ForceConfig }
    if ($forced) { return $forced[0] }
    throw "ForceConfig '$ForceConfig' was not found in the repo folder."
  }

  $preferred = @()

  if ($Tags.Count -gt 0) {
    $tagCombo = ($Tags -join "+")
    $preferred += "$OsPrefix" + "_" + $tagCombo + ".xml"
  }

  $preferred += "$OsPrefix" + "_Multi_Default.xml"

  if (-not ($Tags -contains "ImageGlass")) {
    foreach ($t in @("AdobeAcrobat","Foxit")) {
      if ($Tags -contains $t) {
        $preferred += "$OsPrefix" + "_PhotoViewer+$t.xml"
      }
    }
  }

  foreach ($p in $preferred) {
    $hit = $xmlItems | Where-Object { $_.name -eq $p }
    if ($hit) { return $hit[0] }
  }

  $best = $null
  $bestScore = -1
  foreach ($item in $xmlItems) {
    if ($item.name -notmatch ("^" + [Regex]::Escape($OsPrefix) + "_")) { continue }
    $score = 0
    foreach ($t in $Tags) {
      if ($item.name -match [Regex]::Escape($t)) { $score++ }
    }
    if ($score -gt $bestScore) {
      $bestScore = $score
      $best = $item
    }
  }

  if ($best) { return $best }

  throw "No suitable XML found for OS '$OsPrefix'. Add a fallback XML (e.g., ${OsPrefix}_Multi_Default.xml) to the repo."
}

function Apply-DefaultAppAssociations {
  param([string]$XmlPath)

  $targetXml = "C:\ProgramData\DefaultAppAssociations.xml"
  Copy-Item -Path $XmlPath -Destination $targetXml -Force

  $polKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
  if (-not (Test-Path $polKey)) { New-Item -Path $polKey -Force | Out-Null }
  New-ItemProperty -Path $polKey -Name "DefaultAssociationsConfiguration" -Value $targetXml -PropertyType String -Force | Out-Null

  Say "[+] Policy set: DefaultAssociationsConfiguration -> $targetXml" "Green"

  $dism = "$env:WINDIR\System32\dism.exe"
  $args = "/Online /Import-DefaultAppAssociations:`"$targetXml`""
  Say "[*] Running DISM import..." "Cyan"
  $p = Start-Process -FilePath $dism -ArgumentList $args -Wait -PassThru
  if ($p.ExitCode -eq 0) {
    Say "[+] DISM import completed." "Green"
  } else {
    Say "[!] DISM import returned ExitCode=$($p.ExitCode). Continuing." "Yellow"
  }
}

function Clear-UserChoiceForExtensions {
  $exts = @(".jpg",".jpeg",".png",".bmp",".gif",".tif",".tiff",".webp",".heic",".jfif")
  $base = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts"

  foreach ($e in $exts) {
    $k = Join-Path $base $e
    foreach ($sub in @("UserChoice","OpenWithList","OpenWithProgids")) {
      $path = Join-Path $k $sub
      if (Test-Path $path) {
        try {
          Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
          Say "[+] Cleared $e -> $sub" "Green"
        } catch {
          Say "[!] Failed clearing $e -> $sub : $($_.Exception.Message)" "Yellow"
        }
      }
    }
  }
}

function Repair-PhotosApp {
  Say "[*] Repairing Microsoft Photos..." "Cyan"

  foreach ($p in @("Microsoft.Photos","Photos","Microsoft.Photos.exe")) {
    try { Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
  }

  $pkgRoot = Join-Path $env:LOCALAPPDATA "Packages"
  $photosPkgs = Get-ChildItem $pkgRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "Microsoft.Windows.Photos_*" }

  foreach ($pp in $photosPkgs) {
    foreach ($sub in @("LocalState","TempState","Settings")) {
      $p = Join-Path $pp.FullName $sub
      if (Test-Path $p) {
        try {
          Remove-Item $p -Recurse -Force -ErrorAction Stop
          Say "[+] Cleared Photos user data: $($pp.Name)\$sub" "Green"
        } catch {
          Say "[!] Could not clear $($pp.Name)\$sub : $($_.Exception.Message)" "Yellow"
        }
      }
    }
  }

  try {
    $photos = Get-AppxPackage -AllUsers Microsoft.Windows.Photos -ErrorAction SilentlyContinue
    if ($photos) {
      foreach ($pkg in $photos) {
        $manifest = Join-Path $pkg.InstallLocation "AppXManifest.xml"
        if (Test-Path $manifest) {
          Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction SilentlyContinue | Out-Null
        }
      }
      Say "[+] Photos re-registered." "Green"
    } else {
      Say "[!] Microsoft.Windows.Photos package not found. Skipping re-register." "Yellow"
    }
  } catch {
    Say "[!] Re-register failed: $($_.Exception.Message)" "Yellow"
  }

  if (-not $SkipWsReset) {
    try {
      Say "[*] Running wsreset.exe (Store cache reset)..." "Cyan"
      Start-Process -FilePath "wsreset.exe" -Wait -ErrorAction SilentlyContinue
      Say "[+] wsreset.exe completed." "Green"
    } catch {
      Say "[!] wsreset.exe failed: $($_.Exception.Message)" "Yellow"
    }
  }

  try {
    Say "[*] Launching Photos once to reinitialize..." "Cyan"
    Start-Process "ms-photos:" | Out-Null
    Start-Sleep -Seconds 6
    try { Get-Process -Name "Microsoft.Photos" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    Say "[+] Photos initialization step done." "Green"
  } catch {
    Say "[!] Could not launch Photos: $($_.Exception.Message)" "Yellow"
  }
}

# -----------------------------
# Main
# -----------------------------
Say "[*] Starting..." "White"

$work = Join-Path $env:TEMP ("PhotoFix_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$osPrefix = Get-OSProfile
$tags = Get-AppTags

Say "[*] OS Profile : $osPrefix" "Cyan"
Say ("[*] Detected  : " + ($(if ($tags.Count) { $tags -join ", " } else { "No optional apps detected" }))) "Cyan"

$api = "https://api.github.com/repos/rhshourav/Windows-Scripts/contents/Windows-Photo-Invalid-Reg-Value/File%20Associations?ref=main"
Say "[*] Fetching repo file list..." "Cyan"
$items = Invoke-RetryWeb -Uri $api -Retries 3

$configItem = Pick-BestConfig -OsPrefix $osPrefix -Tags $tags -RepoItems $items
Say "[+] Selected XML: $($configItem.name)" "Green"

$xmlOut = Join-Path $work $configItem.name
Download-File -Url $configItem.download_url -OutFile $xmlOut
Say "[+] Downloaded: $xmlOut" "Green"

$regItem = $items | Where-Object { $_.name -ieq "PhotoViewer.reg" }
$regOut = $null
if ($regItem) {
  $regOut = Join-Path $work $regItem.name
  Download-File -Url $regItem.download_url -OutFile $regOut
  Say "[+] Downloaded: $regOut" "Green"
}

if (-not $SkipDefaultApps) {
  if ($regOut -and (Test-Path $regOut)) {
    Say "[*] Importing PhotoViewer.reg..." "Cyan"
    $rp = Start-Process -FilePath "reg.exe" -ArgumentList @("import", "`"$regOut`"") -Wait -PassThru
    if ($rp.ExitCode -eq 0) {
      Say "[+] Registry import completed." "Green"
    } else {
      Say "[!] reg import returned ExitCode=$($rp.ExitCode). Continuing." "Yellow"
    }
  }

  Apply-DefaultAppAssociations -XmlPath $xmlOut
  Clear-UserChoiceForExtensions
} else {
  Say "[!] SkipDefaultApps set; not applying XML/policy." "Yellow"
}

if (-not $SkipPhotosRepair) {
  Repair-PhotosApp
} else {
  Say "[!] SkipPhotosRepair set; not repairing Photos." "Yellow"
}

if ($DeepRepair) {
  Say "[*] DeepRepair enabled: DISM RestoreHealth + SFC (may take time)..." "Cyan"
  try {
    Start-Process -FilePath "$env:WINDIR\System32\dism.exe" -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -Wait | Out-Null
    Start-Process -FilePath "$env:WINDIR\System32\sfc.exe"  -ArgumentList "/scannow" -Wait | Out-Null
    Say "[+] DeepRepair completed." "Green"
  } catch {
    Say "[!] DeepRepair failed: $($_.Exception.Message)" "Yellow"
  }
}

Say ""
Say "[+] Done." "Green"
Say "    - If defaults don’t reflect immediately for the current user, SIGN OUT and SIGN IN." "White"
Say "    - For shared/AVD/FSLogix environments, enforce the XML via policy and apply at user logon." "White"
