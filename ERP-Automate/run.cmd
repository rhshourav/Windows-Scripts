@echo off
powershell -NoLogo -ExecutionPolicy Bypass -Command ^
  "try { irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1' | iex } ^
   catch { Invoke-RestMethod 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1' | Invoke-Expression }"
