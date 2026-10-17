param(
    [switch]$SkipTools,
    [switch]$SkipPolicy
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This setup is for Windows. Run SETUP.bat from Windows File Explorer or Windows Terminal.'
}

$stickRoot = Split-Path -Parent $PSScriptRoot
$policySource = Join-Path $stickRoot 'provision\files\AGENTS-core.md'
$exampleSource = Join-Path $stickRoot 'provision\files\example-AGENTS-core.md'
$homeDir = [Environment]::GetFolderPath('UserProfile')
$targets = @(
    (Join-Path $homeDir 'AGENTS.md'),
    (Join-Path $homeDir '.codex\AGENTS.md')
)
$claudeTarget = Join-Path $homeDir '.claude\CLAUDE.md'
$claudeStub = "@~/AGENTS.md`r`n"
$packageIds = @(
    '7zip.7zip',
    'Git.Git',
    'GitHub.cli',
    'Python.Python.3.12',
    'astral-sh.uv',
    'Rustlang.Rustup',
    'BurntSushi.ripgrep.MSVC',
    'sharkdp.fd',
    'sharkdp.bat',
    'dandavison.delta',
    'jqlang.jq',
    'MikeFarah.yq',
    'Kitware.CMake',
    'Ninja-build.Ninja',
    'Casey.Just',
    'Rclone.Rclone',
    'mcmilk.7zip-zstd'
)

function Install-Package {
    param([string]$PackageId)
    & winget list --id $PackageId --exact --accept-source-agreements | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "==> $PackageId (already installed)"
        return
    }
    Write-Host "==> $PackageId"
    & winget install --id $PackageId --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed for $PackageId (exit $LASTEXITCODE)"
    }
}

function Copy-Policy {
    param([string]$Source)
    foreach ($target in $targets) {
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Copy-Item $Source $target -Force
        Write-Host "policy: $target"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $claudeTarget) | Out-Null
    Set-Content -Path $claudeTarget -Value $claudeStub -NoNewline -Encoding ascii
    Write-Host "policy: $claudeTarget"
}

Write-Host 'Ventoy stick: Windows operator setup'
Write-Host "Profile: $homeDir"

if (-not $SkipPolicy) {
    if (Test-Path $policySource) {
        Copy-Policy -Source $policySource
    } elseif (Test-Path $exampleSource) {
        Write-Warning 'AGENTS-core.md is absent; installed the public example policy, not the stick private policy.'
        Copy-Policy -Source $exampleSource
    } else {
        throw "Policy payload not found: $policySource"
    }
} else {
    Write-Host 'policy: skipped'
}

if (-not $SkipTools) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is required but was not found. Install App Installer from Microsoft Store, then rerun.'
    }
    foreach ($package in $packageIds) {
        Install-Package -PackageId $package
    }
    Write-Host 'Close and reopen Windows Terminal so refreshed PATH entries take effect.'
} else {
    Write-Host 'tools: skipped'
}

Write-Host 'Windows setup complete. Run DISABLE-WINDOWS-HELLO.bat separately when password sign-in should replace Windows Hello.'
