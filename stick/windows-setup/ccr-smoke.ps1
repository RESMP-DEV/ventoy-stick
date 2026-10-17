Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$bin = Join-Path $env:LOCALAPPDATA 'VentoyTools\bin'
$marker = 'WINDOWS-CCR-SMOKE-' + (Get-Date -Format 'yyyyMMddHHmmss')
$reply = Join-Path $env:TEMP "$marker.txt"
$env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex-ccr'
& (Join-Path $bin 'codex-ccr.cmd') exec --skip-git-repo-check --output-last-message $reply `
    "Reply with exactly: $marker"
if ($LASTEXITCODE -ne 0) { throw "Codex CCR smoke failed with exit $LASTEXITCODE" }
$actual = (Get-Content $reply -Raw).Trim()
Remove-Item -Path $reply -Force
if ($actual -ne $marker) { throw "Codex CCR final reply did not match marker" }
Write-Output "Codex CCR smoke: OK marker=$marker"
