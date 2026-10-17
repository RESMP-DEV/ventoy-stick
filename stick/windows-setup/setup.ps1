param(
    [switch]$SkipTools,
    [switch]$SkipPolicy,
    [switch]$SkipCcr,
    [switch]$Smoke
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This setup is for Windows. Run SETUP.bat from Windows.'
}
if (@('AMD64', 'ARM64') -notcontains $env:PROCESSOR_ARCHITECTURE) {
    throw "Unsupported Windows architecture: $($env:PROCESSOR_ARCHITECTURE). The payload is x86_64."
}

$stickRoot = Split-Path -Parent $PSScriptRoot
$installRoot = Join-Path $env:LOCALAPPDATA 'VentoyTools'
$binDir = Join-Path $installRoot 'bin'
$logDir = Join-Path $installRoot 'logs'
$policyDir = Join-Path $installRoot 'policy'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logDir "setup-$stamp.log"
$summaryPath = Join-Path $logDir 'setup-latest.json'
$steps = @()
$currentStep = 'start'
New-Item -ItemType Directory -Force -Path $binDir, $logDir, $policyDir | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format o), $Level, $Message
    Write-Host $line
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

function Redact-Text {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $result = $Text
    $result = $result -replace '(?im)^(\s*(?:experimental_bearer_token|api_key|token|access_token|refresh_token)\s*=\s*).+$', '$1"[REDACTED]"'
    $result = $result -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}', '$1[REDACTED]'
    $result = $result -replace '(?i)("([^"]*(?:api[_-]?key|token|access[_-]?token|refresh[_-]?token)[^"]*)"\s*:\s*)"[^"]+"', '$1"[REDACTED]"'
    return $result
}

function Invoke-Native {
    param([string]$Name, [string]$File, [string[]]$Arguments)
    Write-Log "$Name command: $File $($Arguments -join ' ')"
    $output = & $File @Arguments 2>&1
    $exit = $LASTEXITCODE
    $text = Redact-Text (($output | Out-String).TrimEnd())
    if ($text.Length -gt 0) { Add-Content -Path $logPath -Value $text -Encoding UTF8 }
    if ($exit -ne 0) { throw "$Name failed with exit $exit" }
}

function Step {
    param([string]$Name, [scriptblock]$Body)
    $script:currentStep = $Name
    $started = Get-Date
    Write-Log "START $Name"
    try {
        & $Body
        $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
        $script:steps += @{ name = $Name; status = 'ok'; elapsed_ms = $elapsed }
        Write-Log "OK $Name (${elapsed}ms)"
    } catch {
        $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
        $script:steps += @{
            name = $Name; status = 'failed'; elapsed_ms = $elapsed
            error = Redact-Text ([string]$_.Exception.Message)
        }
        Write-Log "FAILED ${Name}: $($_.Exception.Message)" 'ERROR'
        throw
    }
}

function Write-Summary {
    param([bool]$Success)
    $summary = @{
        recorded_at = (Get-Date -Format o)
        status = $(if ($Success) { 'passed' } else { 'failed' })
        current_step = $currentStep
        log = $logPath
        steps = $steps
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath -Encoding UTF8
    Write-Log "summary: $summaryPath"
}

$packageIds = @(
    '7zip.7zip', 'Git.Git', 'GitHub.cli', 'Python.Python.3.12',
    'astral-sh.uv', 'Rustlang.Rustup', 'BurntSushi.ripgrep.MSVC',
    'sharkdp.fd', 'sharkdp.bat', 'dandavison.delta', 'jqlang.jq',
    'MikeFarah.yq', 'Kitware.CMake', 'Ninja-build.Ninja', 'Casey.Just',
    'Rclone.Rclone', 'mcmilk.7zip-zstd'
)

function Install-Package {
    param([string]$PackageId)
    & winget list --id $PackageId --exact --accept-source-agreements | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "winget package already installed: $PackageId"
        return
    }
    Invoke-Native "winget install $PackageId" winget @(
        'install', '--id', $PackageId, '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    )
}

function Copy-IfAbsent {
    param([string]$Source, [string]$Target, [string]$Label)
    if (Test-Path $Target) {
        Write-Log "$Label preserved existing file: $Target"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Target) | Out-Null
        Copy-Item $Source $Target
        Write-Log "$Label installed: $Target"
    }
}

function Get-ExpectedHash {
    param([string]$Name)
    foreach ($line in Get-Content (Join-Path $PSScriptRoot 'bin\BINARIES.sha256')) {
        if ($line -match ('^([A-Fa-f0-9]{64})\s+\*?' + [regex]::Escape($Name) + '$')) {
            return $Matches[1].ToLowerInvariant()
        }
    }
    throw "expected hash missing for $Name"
}

function Install-HashedBinary {
    param([string]$Name)
    $source = Join-Path $PSScriptRoot "bin\$Name"
    $target = Join-Path $binDir ($Name -replace '-x86_64', '')
    if (-not (Test-Path $source)) { throw "payload binary missing: $source" }
    $expected = Get-ExpectedHash -Name $Name
    $actual = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "hash mismatch for $Name source: expected $expected got $actual" }
    if ((Test-Path $target) -and ((Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected)) {
        Write-Log "binary unchanged: $target"
    } else {
        Copy-Item $source $target -Force
        Write-Log "binary installed: $target sha256=$expected"
    }
}

Write-Log "Ventoy Windows setup start stick=$stickRoot profile=$env:USERNAME"
Write-Log "platform=$([Environment]::OSVersion.VersionString) arch=$($env:PROCESSOR_ARCHITECTURE) ps=$($PSVersionTable.PSVersion)"

$terminalError = $null
try {
Step policy {
    $realPolicy = Join-Path $stickRoot 'provision\files\AGENTS-core.md'
    $examplePolicy = Join-Path $stickRoot 'provision\files\example-AGENTS-core.md'
    $source = $realPolicy
    if (-not (Test-Path $source)) {
        $source = $examplePolicy
        Write-Log 'private AGENTS-core.md absent; public example will be used' 'WARN'
    }
    if (-not (Test-Path $source)) { throw 'policy payload missing' }
    Copy-Item $source (Join-Path $policyDir 'AGENTS-core.md') -Force
    if (-not $SkipPolicy) {
        Copy-IfAbsent $source (Join-Path $env:USERPROFILE 'AGENTS.md') 'home policy'
        Copy-IfAbsent $source (Join-Path $env:USERPROFILE '.codex\AGENTS.md') 'Codex global policy'
        Copy-IfAbsent $source (Join-Path $env:USERPROFILE '.codex-ccr\AGENTS.md') 'CCR Codex global policy'
        $claude = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'
        if (-not (Test-Path $claude)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $claude) | Out-Null
            Set-Content -Path $claude -Value "@~/AGENTS.md`r`n" -NoNewline -Encoding ascii
            Write-Log "Claude policy import installed: $claude"
        } else {
            Write-Log "Claude policy import preserved existing file: $claude"
        }
    }
}

Step tools {
    if ($SkipTools) {
        Write-Log 'tools skipped by request'
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is required but was not found. Install App Installer, then rerun.'
    }
    foreach ($package in $packageIds) {
        Install-Package -PackageId $package
    }
    Write-Log 'reopen Windows Terminal after setup to refresh PATH entries'
}

Step binaries {
    if ($SkipCcr) {
        Write-Log 'pinned Codex/CCR binaries and aliases skipped by request'
        return
    }
    Install-HashedBinary -Name 'codex-x86_64.exe'
    Install-HashedBinary -Name 'ccr-rust-x86_64.exe'
    foreach ($name in @(
        'ccr-serve.ps1', 'ccr-main.cmd', 'ccr-glm-workers.cmd',
        'codex-ccr.cmd', 'ccr-healthcheck.ps1', 'ccr-healthcheck.cmd',
        'ccr-smoke.ps1', 'ccr-smoke.cmd'
    )) {
        Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path $binDir $name) -Force
        Write-Log "launcher installed: $(Join-Path $binDir $name)"
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $parts = @($userPath -split ';' | Where-Object { $_.Length -gt 0 })
    if ($parts -notcontains $binDir) {
        $parts = @($binDir) + @($parts | Where-Object { $_ -ne $binDir })
        [Environment]::SetEnvironmentVariable('Path', $parts -join ';', 'User')
        Write-Log "user PATH prepended: $binDir"
    } else {
        Write-Log "user PATH already contains: $binDir"
    }
    $env:Path = "$binDir;$env:Path"
    foreach ($alias in @('codex-ccr.cmd', 'ccr-rust.exe', 'ccr-healthcheck.cmd')) {
        $command = Get-Command $alias -ErrorAction SilentlyContinue
        if ($command) {
            Write-Log "alias resolves to $($command.Source)"
        } else {
            throw "installed alias cannot be resolved after PATH update: $alias"
        }
    }
}

Step ccr-credentials {
    if ($SkipCcr) {
        Write-Log 'CCR and Codex routing skipped by request'
        return
    }
    $profile = 'default'
    $archive = Join-Path $stickRoot "provision\profiles\$profile\secrets.tar"
    if (-not (Test-Path $archive)) {
        throw "CCR credentials archive missing: $archive (physical Ventoy stick required)"
    }
    $extract = Join-Path $env:TEMP "ventoy-ccr-$stamp"
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    Invoke-Native 'extract credentials archive' tar.exe @('-xf', $archive, '-C', $extract)
    $required = @('codex\auth.json', 'codex\config.toml', 'ccr\runtime-credentials.json')
    foreach ($relative in $required) {
        if (-not (Test-Path (Join-Path $extract $relative))) {
            throw "credentials archive missing $relative"
        }
    }

    $codexHome = Join-Path $env:USERPROFILE '.codex-ccr'
    $ccrHome = Join-Path $env:USERPROFILE '.ccr-ventoy'
    New-Item -ItemType Directory -Force -Path $codexHome, $ccrHome | Out-Null
    $homeToml = $env:USERPROFILE.Replace('\', '/')
    $configText = Get-Content (Join-Path $extract 'codex\config.toml') -Raw
    $configText = $configText.Replace('__HOME__', $homeToml)
    Set-Content -Path (Join-Path $codexHome 'ccr.config.toml') -Value $configText -Encoding ascii
    Set-Content -Path (Join-Path $codexHome 'config.toml') -Value $configText -Encoding ascii
    Copy-Item (Join-Path $extract 'codex\auth.json') (Join-Path $codexHome 'auth.json') -Force
    Copy-Item (Join-Path $stickRoot 'provision\files\ccr-model-catalog.json') `
        (Join-Path $codexHome 'ccr-live-model-catalog.json') -Force
    Copy-Item (Join-Path $extract 'ccr\runtime-credentials.json') `
        (Join-Path $ccrHome 'runtime-credentials.json') -Force
    Copy-Item (Join-Path $stickRoot 'provision\files\ccr\config.json') `
        (Join-Path $ccrHome 'config.json') -Force
    Copy-Item (Join-Path $stickRoot 'provision\files\ccr\glm-workers.json') `
        (Join-Path $ccrHome 'glm-workers.json') -Force
    Remove-Item -Path $extract -Recurse -Force

    foreach ($path in @($codexHome, $ccrHome)) {
        $account = "$env:USERDOMAIN\$env:USERNAME"
        Invoke-Native "restrict ACL $path" icacls.exe @(
            $path, '/inheritance:r', '/grant:r', "${account}:(OI)(CI)F"
        )
    }
    Write-Log "dedicated Codex CCR home: $codexHome (existing global .codex untouched)"
    Write-Log "dedicated CCR home: $ccrHome (existing .claude-code-router untouched)"
}

Step ccr-validate {
    if ($SkipCcr) { return }
    $codex = Join-Path $binDir 'codex.exe'
    $ccr = Join-Path $binDir 'ccr-rust.exe'
    $mainConfig = Join-Path $env:USERPROFILE '.ccr-ventoy\config.json'
    $workersConfig = Join-Path $env:USERPROFILE '.ccr-ventoy\glm-workers.json'
    Invoke-Native 'Codex version' $codex @('--version')
    Invoke-Native 'ccr-rust version' $ccr @('version')
    Write-Log "CCR configs staged; each launcher validates after credential injection: $mainConfig, $workersConfig"
}

Step ccr-services {
    if ($SkipCcr) { return }
    $serve = Join-Path $binDir 'ccr-serve.ps1'
    Invoke-Native 'start CCR main' powershell.exe @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serve, 'main', 'start'
    )
    Invoke-Native 'start CCR GLM workers' powershell.exe @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serve, 'workers', 'start'
    )
    Invoke-Native 'CCR healthcheck' (Join-Path $binDir 'ccr-healthcheck.cmd') @()

    $startup = [Environment]::GetFolderPath('Startup')
    $shell = New-Object -ComObject WScript.Shell
    foreach ($mode in @('main', 'workers')) {
        $shortcut = $shell.CreateShortcut((Join-Path $startup "Ventoy CCR $mode.lnk"))
        $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serve`" $mode start"
        $shortcut.WorkingDirectory = $binDir
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        Write-Log "startup shortcut installed: $(Join-Path $startup \"Ventoy CCR $mode.lnk\")"
    }
}

if ($Smoke) {
    Step smoke {
        if ($SkipCcr) { throw 'Smoke cannot run with -SkipCcr' }
        Invoke-Native 'real Codex CCR marker smoke' (Join-Path $binDir 'ccr-smoke.cmd') @()
    }
}
} catch {
    $terminalError = $_
    Write-Log "SETUP FAILED at ${currentStep}" 'ERROR'
    Write-Summary $false
}

if (-not $terminalError) {
    Write-Summary $true
    Write-Log 'SETUP COMPLETE'
}

$stickLogDir = Join-Path $PSScriptRoot 'logs'
try {
    New-Item -ItemType Directory -Force -Path $stickLogDir | Out-Null
    Copy-Item -Path $logPath -Destination (Join-Path $stickLogDir "setup-$stamp.log") -Force
    Copy-Item -Path $summaryPath -Destination (Join-Path $stickLogDir 'setup-latest.json') -Force
    Write-Log "sanitized setup log copied to stick: $stickLogDir"
} catch {
    Write-Log "could not copy sanitized setup log to stick: $($_.Exception.Message)" 'WARN'
}

if ($terminalError) {
    exit 1
}
