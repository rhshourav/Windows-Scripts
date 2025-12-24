$RepoOwner = "rhshourav"
$RepoName  = "ideal-fishstick"
$Folder    = "erp_font"

$ApiUrl  = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$Folder"
$TempDir = "$env:TEMP\erp_fonts"
$FontDir = "$env:WINDIR\Fonts"

Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $TempDir | Out-Null

$Files = Invoke-RestMethod -Uri $ApiUrl -Headers @{ "User-Agent" = "PowerShell" }

foreach ($File in $Files) {
    if ($File.name -match '\.(ttf|ttc|fon)$') {
        $Out = Join-Path $TempDir $File.name
        Invoke-WebRequest -Uri $File.download_url -OutFile $Out
    }
}

Get-ChildItem $TempDir -Include *.ttf,*.ttc,*.fon | ForEach-Object {
    $Dest = Join-Path $FontDir $_.Name
    if (-not (Test-Path $Dest)) {
        Copy-Item $_.FullName $Dest
    }
}

Remove-Item $TempDir -Recurse -Force
Write-Host "Done"
