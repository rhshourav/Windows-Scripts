@echo off
setlocal

set "url=https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1"

powershell -NoLogo -ExecutionPolicy Bypass -Command "try { irm \"%url%\" | iex } catch { Invoke-RestMethod \"%url%\" | Invoke-Expression }"

endlocal
