Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$config = Join-Path $env:USERPROFILE '.codex-ccr\ccr.config.toml'
if (-not (Test-Path $config)) { throw "CCR Codex config missing: $config" }
$match = Select-String -Path $config -Pattern 'experimental_bearer_token\s*=\s*"([^"]+)"'
if (-not $match) { throw 'experimental bearer token missing from CCR Codex config' }
$token = $match.Matches[0].Groups[1].Value
$response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3457/v1/models' `
    -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8
if ($response.Content -notmatch 'glm-5\.3-flashx') {
    throw 'CCR GLM model catalog does not advertise glm-5.3-flashx'
}
Write-Output 'CCR GLM listener: OK (glm-5.3-flashx advertised)'
