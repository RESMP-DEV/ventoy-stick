@echo off
setlocal
set "SCRIPT=%~dp0ccr-smoke.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
exit /b %ERRORLEVEL%
