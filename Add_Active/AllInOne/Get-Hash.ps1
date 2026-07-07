# Download file
$response = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Add_Active/AllInOne/AIO.cmd'

# Normalize exactly as the script does
$response = $response -replace "`r?`n", "`r`n"
$response = $response.TrimEnd() + "`r`n`r`n"

# Compute hash
$ms = New-Object IO.MemoryStream
$sw = New-Object IO.StreamWriter($ms)
$sw.Write($response)
$sw.Flush()
$ms.Position = 0
$hash = [BitConverter]::ToString(
    [Security.Cryptography.SHA256]::Create().ComputeHash($ms)
) -replace '-'

$hash  # copy this value into $expectedHash in your script
