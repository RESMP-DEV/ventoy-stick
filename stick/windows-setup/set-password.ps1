Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script is for Windows.'
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run SET-PASSWORD.bat as Administrator.'
}
if ([Environment]::UserDomainName -ne $env:COMPUTERNAME) {
    throw "This looks like a domain or organization account (domain: $([Environment]::UserDomainName)). Change its password through the owning service."
}

$upn = (& "$env:ComSpec" /c 'whoami /upn 2>NUL') -join ''
if ($upn -match '@') {
    throw "This looks like a Microsoft or organization account (UPN: $upn). Change its password through the owning service."
}

$localUser = Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue
if (-not $localUser) {
    throw "Current account '$env:USERNAME' is not a local account."
}
if ($localUser.Enabled -ne $true) {
    throw "Local account '$env:USERNAME' is disabled."
}

Write-Host "This sets the password for local account '$env:USERNAME' and exposes password sign-in."
Write-Host 'You will type the password twice. It is not displayed or written to disk.'
$secure1 = Read-Host -Prompt 'New local account password' -AsSecureString
$secure2 = Read-Host -Prompt 'Confirm password' -AsSecureString
$bstr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
$bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
$plain1 = $null
$plain2 = $null
try {
    $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
    $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
    if ([string]::IsNullOrEmpty($plain1)) { throw 'Password cannot be empty.' }
    if ($plain1 -ne $plain2) { throw 'Passwords differ.' }
    Set-LocalUser -Name $env:USERNAME -Password $secure1
} finally {
    $plain1 = $null
    $plain2 = $null
    if ($bstr1 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroBSTR($bstr1) }
    if ($bstr2 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroBSTR($bstr2) }
}

$passwordLessKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
$oldPasswordLess = (Get-ItemProperty -Path $passwordLessKey -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
if ($null -eq $oldPasswordLess) {
    $rollbackValue = '"DevicePasswordLessBuildVersion"=-'
} else {
    $rollbackValue = '"DevicePasswordLessBuildVersion"=dword:{0:x8}' -f [int]$oldPasswordLess
}
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rollback = Join-Path $PSScriptRoot "password-signin-rollback-$timestamp.reg"
@"
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device]
$rollbackValue

"@ | Set-Content -Path $rollback -Encoding ascii

New-Item -Path $passwordLessKey -Force | Out-Null
New-ItemProperty -Path $passwordLessKey -Name 'DevicePasswordLessBuildVersion' -PropertyType DWord -Value 0 -Force | Out-Null

Write-Host "password: set for local account '$env:USERNAME'"
Write-Host 'password sign-in: exposed at the Windows sign-in screen'
Write-Host "registry rollback: $rollback"
Write-Host ''
Write-Host 'REQUIRED NEXT STEP:'
Write-Host '1. Press Windows+L.'
Write-Host '2. Unlock with the new password. Do not continue to DISABLE-WINDOWS-HELLO.bat until this works.'
Write-Host '3. If it fails, sign back in with Windows Hello and use a local administrator recovery path to reset the password.'
