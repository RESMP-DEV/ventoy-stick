#!/usr/bin/env python3
"""Static checks for the Windows payload; these intentionally run on any host."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WINDOWS = ROOT / 'stick' / 'windows-setup'


class WindowsSetupTests(unittest.TestCase):
    def test_batch_files_are_crlf_and_launch_native_scripts(self):
        interactive = {'SETUP.bat', 'SET-PASSWORD.bat', 'DISABLE-WINDOWS-HELLO.bat'}
        for name in ('SETUP.bat', 'SET-PASSWORD.bat', 'DISABLE-WINDOWS-HELLO.bat',
                     'ccr-main.cmd', 'ccr-glm-workers.cmd', 'codex-ccr.cmd',
                     'ccr-healthcheck.cmd', 'ccr-smoke.cmd'):
            data = (WINDOWS / name).read_bytes()
            self.assertNotIn(b'\n', data.replace(b'\r\n', b''))
            self.assertIn(b'powershell.exe -NoProfile -ExecutionPolicy Bypass -File', data)
            if name in interactive:
                self.assertIn(b'pause', data)

    def test_setup_installs_policy_and_baseline_without_secrets(self):
        setup = (WINDOWS / 'setup.ps1').read_text()
        readme = (WINDOWS / 'README.md').read_text()
        self.assertIn("Join-Path $stickRoot 'provision\\files\\AGENTS-core.md'", setup)
        self.assertIn('Copy-IfAbsent', setup)
        self.assertIn(".codex\\AGENTS.md", setup)
        for package in ('Git.Git', 'Python.Python.3.12', 'astral-sh.uv',
                        'Casey.Just', 'Rclone.Rclone', 'mcmilk.7zip-zstd'):
            self.assertIn(f"'{package}'", setup)
        self.assertIn('does not unpack', readme)
        payload_names = {path.name for path in WINDOWS.iterdir() if path.is_file()}
        self.assertNotIn('secrets.tar', payload_names)
        self.assertNotIn('auth.json', payload_names)

    def test_pinned_binaries_and_provenance_are_present(self):
        hashes = {}
        for line in (WINDOWS / 'bin' / 'BINARIES.sha256').read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                hashes[parts[1]] = parts[0]
        self.assertEqual(hashes['codex-x86_64.exe'],
                         'be96b992178b1e467c225800da0d65f2c86d5eba1ef0b14632f65db381cbdfde')
        self.assertEqual(len(hashes['ccr-rust-x86_64.exe']), 64)
        provenance = (WINDOWS / 'bin' / 'BINARIES-provenance.txt').read_text()
        self.assertIn('rust-v0.154.0', provenance)
        self.assertIn('3d07a5a', provenance)
        for name, executable in (
            ('codex-x86_64.exe', b'MZ'),
            ('ccr-rust-x86_64.exe', b'MZ'),
        ):
            data = (WINDOWS / 'bin' / name).read_bytes()[:2]
            self.assertEqual(data, executable)

    def test_setup_installs_codex_ccr_without_repointing_user_config(self):
        setup = (WINDOWS / 'setup.ps1').read_text()
        self.assertIn("Install-HashedBinary -Name 'codex-x86_64.exe'", setup)
        self.assertIn("Install-HashedBinary -Name 'ccr-rust-x86_64.exe'", setup)
        self.assertIn('.codex-ccr', setup)
        self.assertIn('.ccr-ventoy', setup)
        self.assertIn('Copy-IfAbsent', setup)
        self.assertIn('existing global .codex untouched', setup)
        self.assertIn('existing .claude-code-router untouched', setup)
        self.assertIn('setup-latest.json', setup)
        self.assertIn('Redact-Text', setup)
        self.assertIn('secrets.tar', setup)

    def test_sync_preserves_runtime_windows_logs_and_rollbacks(self):
        sync = (ROOT / 'tools' / 'sync-stick.sh').read_text()
        self.assertIn("--exclude '/windows-setup/logs/'", sync)
        self.assertIn("--exclude '/windows-setup/*.reg'", sync)
        self.assertIn("-not -path './windows-setup/logs/*'", sync)
        self.assertIn("-not -path './windows-setup/*.reg'", sync)

    def test_ccr_aliases_and_logging_contract(self):
        aliases = '\n'.join(
            (WINDOWS / name).read_text()
            for name in ('codex-ccr.cmd', 'ccr-main.cmd', 'ccr-glm-workers.cmd',
                         'ccr-healthcheck.cmd', 'ccr-smoke.cmd')
        )
        serve = (WINDOWS / 'ccr-serve.ps1').read_text()
        health = (WINDOWS / 'ccr-healthcheck.ps1').read_text()
        smoke = (WINDOWS / 'ccr-smoke.ps1').read_text()
        self.assertIn('--profile ccr', aliases)
        self.assertIn('CODEX_HOME', aliases)
        self.assertIn('127.0.0.1:3457', aliases)
        for text in (serve, smoke):
            self.assertIn('$env:LOCALAPPDATA', text)
        self.assertIn('runtime-credentials.json', serve)
        self.assertIn('CCR_ZAI_API_KEY', serve)
        self.assertIn('validate', serve)
        self.assertIn('Get-NetTCPConnection', serve)
        self.assertIn('RedirectStandardError', serve)
        self.assertIn('glm-5.3-flashx', health)
        self.assertIn('Reply with exactly:', smoke)

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
