@echo off
setlocal
set "SCRIPT=%~dp0setup.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: setup.ps1 must remain beside SETUP.bat.
    pause
    exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
echo.
echo SETUP_EXIT_CODE=%RC%
pause
exit /b %RC%
