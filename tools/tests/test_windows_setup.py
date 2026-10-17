#!/usr/bin/env python3
"""Static checks for the Windows payload; these intentionally run on any host."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WINDOWS = ROOT / 'stick' / 'windows-setup'


class WindowsSetupTests(unittest.TestCase):
    def test_batch_files_are_crlf_and_launch_native_scripts(self):
        for name in ('SETUP.bat', 'SET-PASSWORD.bat', 'DISABLE-WINDOWS-HELLO.bat'):
            data = (WINDOWS / name).read_bytes()
            self.assertNotIn(b'\n', data.replace(b'\r\n', b''))
            self.assertIn(b'powershell.exe -NoProfile -ExecutionPolicy Bypass -File', data)
            self.assertIn(b'pause', data)

    def test_setup_installs_policy_and_baseline_without_secrets(self):
        setup = (WINDOWS / 'setup.ps1').read_text()
        readme = (WINDOWS / 'README.md').read_text()
        self.assertIn("Join-Path $stickRoot 'provision\\files\\AGENTS-core.md'", setup)
        self.assertIn("Join-Path $homeDir '.codex\\AGENTS.md'", setup)
        for package in ('Git.Git', 'Python.Python.3.12', 'astral-sh.uv',
                        'Casey.Just', 'Rclone.Rclone', 'mcmilk.7zip-zstd'):
            self.assertIn(f"'{package}'", setup)
        self.assertIn('does not unpack', readme)
        payload_names = {path.name for path in WINDOWS.iterdir() if path.is_file()}
        self.assertNotIn('secrets.tar', payload_names)
        self.assertNotIn('auth.json', payload_names)

    def test_password_script_is_local_only_and_exposes_password_signin(self):
        script = (WINDOWS / 'set-password.ps1').read_text()
        self.assertIn('[Environment]::UserDomainName -ne $env:COMPUTERNAME', script)
        self.assertIn('whoami /upn', script)
        self.assertIn('Get-LocalUser -Name $env:USERNAME', script)
        self.assertIn('Set-LocalUser -Name $env:USERNAME -Password $secure1', script)
        self.assertIn("'DevicePasswordLessBuildVersion' -PropertyType DWord -Value 0", script)
        self.assertIn('Windows+L', script)

    def test_hello_disable_is_gated_by_tested_password(self):
        script = (WINDOWS / 'disable-windows-hello.ps1').read_text()
        self.assertIn('PASSWORD-TESTED', script)
        self.assertIn('.DevicePasswordLessBuildVersion', script)
        self.assertIn('if ($currentPasswordLess -ne 0)', script)
        self.assertIn("'ExcludedCredentialProviders' -PropertyType String", script)
        for provider in (
            '{D6886603-9D2F-4EB2-B667-1971041FA96B}',
            '{BEC09223-B018-416D-A0AC-523971B639F5}',
            '{8AF662BF-65A0-4D0A-A540-A338A999D36F}',
        ):
            self.assertIn(provider, script)
        self.assertIn('hello-rollback-', script)


if __name__ == '__main__':
    unittest.main(verbosity=2)
