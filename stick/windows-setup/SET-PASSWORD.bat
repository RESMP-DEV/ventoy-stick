@echo off
setlocal
net session >NUL 2>&1
if not "%ERRORLEVEL%"=="0" (
    echo ERROR: Right-click this file and choose Run as administrator.
    pause
    exit /b 5
)
set "SCRIPT=%~dp0set-password.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: set-password.ps1 must remain beside this file.
    pause
    exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
echo.
echo SET_PASSWORD_EXIT_CODE=%RC%
pause
exit /b %RC%
