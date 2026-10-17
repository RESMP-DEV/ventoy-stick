@echo off
setlocal
set "SCRIPT=%~dp0ccr-serve.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" main %1
exit /b %ERRORLEVEL%
