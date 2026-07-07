@echo off
reg export HKLM\SOFTWARE D:\Migration\HKLM_SOFTWARE.reg /y
reg export HKCU\SOFTWARE D:\Migration\HKCU_SOFTWARE.reg /y

reg export HKLM\SYSTEM D:\Migration\HKLM_SYSTEM.reg /y
reg export HKLM\SECURITY D:\Migration\HKLM_SECURITY.reg /y
reg export HKLM\SAM D:\Migration\HKLM_SAM.reg /y
