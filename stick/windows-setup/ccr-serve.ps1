param(
    [ValidateSet('main', 'workers')] [string]$Mode = 'workers',
    [ValidateSet('start', 'stop', 'restart', 'status')] [string]$Action = 'start'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:USERPROFILE '.ccr-ventoy'
$binary = Join-Path $env:LOCALAPPDATA 'VentoyTools\bin\ccr-rust.exe'
$credentialsPath = Join-Path $root 'runtime-credentials.json'
$logDir = Join-Path $env:LOCALAPPDATA 'VentoyTools\logs'
$config = Join-Path $root ($(if ($Mode -eq 'main') { 'config.json' } else { 'glm-workers.json' }))
$port = $(if ($Mode -eq 'main') { 3456 } else { 3457 })
$pidFile = Join-Path $logDir "ccr-$Mode.pid"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Test-Health {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Get-Listener {
    $connections = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($connections.Count -eq 0) { return $null }
    $processId = [int]$connections[0].OwningProcess
    return Get-CimInstance Win32_Process -Filter "ProcessId=$processId"
}

function Stop-Listener {
    $listener = Get-Listener
    if ($listener -and $listener.ExecutablePath -eq $binary) {
        Stop-Process -Id $listener.ProcessId -Force
        Start-Sleep -Milliseconds 500
    } elseif ($listener) {
        throw "Port $port belongs to another process: $($listener.Name) pid $($listener.ProcessId)"
    }
}

function Start-Listener {
    if (Test-Health) { return }
    $listener = Get-Listener
    if ($listener) {
        throw "Port $port belongs to another process: $($listener.Name) pid $($listener.ProcessId)"
    }
    foreach ($item in @($binary, $config, $credentialsPath)) {
        if (-not (Test-Path $item)) { throw "required CCR file missing: $item" }
    }

    $values = Get-Content $credentialsPath -Raw | ConvertFrom-Json
    $names = $(if ($Mode -eq 'main') {
        @('CCR_ZAI_API_KEY', 'CCR_AZURE_API_KEY', 'CCR_MINIMAX_API_KEY')
    } else {
        @('CCR_ZAI_API_KEY')
    })
    foreach ($name in $names) {
        $value = [string]$values.$name
        if ([string]::IsNullOrEmpty($value)) { throw "invalid runtime credential entry: $name" }
        Set-Item -Path "Env:$name" -Value $value
    }

    & $binary --config $config validate
    if ($LASTEXITCODE -ne 0) { throw "ccr-rust config validation failed with exit $LASTEXITCODE" }
    $stdout = Join-Path $logDir "ccr-$Mode.out.log"
    $stderr = Join-Path $logDir "ccr-$Mode.err.log"
    $arguments = "--config `"$config`" start --host 127.0.0.1 --port $port"
    $process = Start-Process -FilePath $binary -ArgumentList $arguments -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    Set-Content -Path $pidFile -Value $process.Id -Encoding ascii
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Health) { return }
        if ($process.HasExited) { throw "ccr-rust exited with code $($process.ExitCode); see $stderr" }
        Start-Sleep -Milliseconds 500
    }
    throw "ccr-rust did not become healthy; see $stderr"
}

switch ($Action) {
    'start' { Start-Listener }
    'stop' { Stop-Listener }
    'restart' { Stop-Listener; Start-Listener }
    'status' {
        if (Test-Health) {
            Write-Output "ccr-rust $Mode healthy on 127.0.0.1:$port"
        } else {
            Write-Output "ccr-rust $Mode down on 127.0.0.1:$port"
            exit 1
        }
    }
}
