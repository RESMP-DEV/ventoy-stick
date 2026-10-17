@echo off
setlocal
set "SCRIPT=%~dp0ccr-serve.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" workers %1
exit /b %ERRORLEVEL%
