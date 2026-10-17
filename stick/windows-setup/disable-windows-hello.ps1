param(
    [switch]$ConfirmPasswordTested
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script is for Windows.'
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run DISABLE-WINDOWS-HELLO.bat as Administrator.'
}

if (-not $ConfirmPasswordTested) {
    Write-Host 'Before Hello is disabled, the account password must have unlocked the lock screen.'
    $answer = Read-Host -Prompt 'Type PASSWORD-TESTED to continue'
    if ($answer -ne 'PASSWORD-TESTED') {
        throw 'Password test was not confirmed. Run SET-PASSWORD.bat first, then prove the password with Windows+L.'
    }
}

$passwordLessKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
$currentPasswordLess = (Get-ItemProperty -Path $passwordLessKey -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
if ($currentPasswordLess -ne 0) {
    throw 'Password sign-in is not exposed yet. Run SET-PASSWORD.bat and test the password first.'
}
$providerPolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$helloProviders = '{D6886603-9D2F-4EB2-B667-1971041FA96B},{BEC09223-B018-416D-A0AC-523971B639F5},{8AF662BF-65A0-4D0A-A540-A338A999D36F}'
$oldExcluded = (Get-ItemProperty -Path $providerPolicyKey -ErrorAction SilentlyContinue).ExcludedCredentialProviders
if ($null -eq $oldExcluded) {
    $rollbackValue = '"ExcludedCredentialProviders"=-'
} else {
    $escapedOld = [string]$oldExcluded -replace '"', '\"'
    $rollbackValue = '"ExcludedCredentialProviders"="{0}"' -f $escapedOld
}
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rollback = Join-Path $PSScriptRoot "hello-rollback-$timestamp.reg"
@"
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device]
"DevicePasswordLessBuildVersion"=dword:00000002

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System]
$rollbackValue

"@ | Set-Content -Path $rollback -Encoding ascii
Write-Host "rollback: $rollback"

New-ItemProperty -Path $providerPolicyKey -Name 'ExcludedCredentialProviders' -PropertyType String -Value $helloProviders -Force | Out-Null
Write-Host 'Windows Hello providers disabled: PIN, fingerprint, facial recognition'

Write-Host ''
Write-Host 'REQUIRED VERIFICATION BEFORE REBOOT:'
Write-Host '1. Press Windows+L.'
Write-Host '2. If password fails, use a Hello method, sign in, and double-click the rollback .reg file.'
Write-Host '3. Remove old PIN, fingerprint, and face enrollments in Settings > Accounts > Sign-in options.'
