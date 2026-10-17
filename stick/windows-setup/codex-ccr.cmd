@echo off
setlocal
set "BIN=%~dp0"
powershell.exe -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3457/health' -TimeoutSec 2).StatusCode } catch { exit 1 }" >NUL 2>&1
if not "%ERRORLEVEL%"=="0" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BIN%ccr-serve.ps1" workers start
)
set "CODEX_HOME=%USERPROFILE%\.codex-ccr"
"%BIN%codex.exe" --profile ccr %*
exit /b %ERRORLEVEL%
