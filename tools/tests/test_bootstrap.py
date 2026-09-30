#!/usr/bin/env python3
"""Run only inside a disposable Linux container; all profiles/credentials are fake."""
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['useradd', '-m', '-s', '/bin/bash', 'tester'], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o755)
        self.payload = self.root / 'payload'
        for rel in ['bin', 'files/ccr', 'profiles/default/ssh']:
            (self.payload / rel).mkdir(parents=True)
        shutil.copy2(ROOT / 'stick/provision/bootstrap.sh', self.payload)
        (self.payload / 'profiles/default/profile.conf').write_text(
            'TARGET_USER="tester"\nREALNAME="Test User"\nGIT_EMAIL="test@example.invalid"\n'
            'ENABLE_CCR_MAIN=1\nENABLE_GLM_WORKERS=1\nENABLE_ZCODE_CREDS=0\n')
        for rel in ['files/ccr/config.json', 'files/ccr/glm-workers.json', 'files/ccr-model-catalog.json']:
            (self.payload / rel).write_text('{}\n')
        (self.payload / 'ccr-serve.py').write_text('#!/usr/bin/env python3\n')
        self.command(self.payload / 'files/install-baseline-tools.sh', 'exit "${MOCK_BASELINE_RC:-0}"')
        self.command(self.payload / 'bin/codex', '''
reply=''
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output-last-message ]; then shift; reply=$1; fi
    prompt=$1
    shift
done
# Echoing the prompt must never be accepted as a valid final answer.
echo "$prompt"
if [ "${MOCK_WRONG_REPLY:-0}" = 1 ]; then
    printf 'wrong answer\\n' > "$reply"
else
    printf '%s\\n' "${prompt#Reply with exactly: }" > "$reply"
fi
exit "${MOCK_CODEX_RC:-0}"
''')
        for name in ['codex-code-mode-host', 'ccr-rust']:
            self.command(self.payload / 'bin' / name, 'exit 0')
        secrets = self.root / 'secrets'
        for rel, content in [('codex/auth.json', '{}'), ('codex/config.toml',
                              'experimental_bearer_token = "synthetic-test-token"\n'),
                             ('ccr/runtime-credentials.json', '{}')]:
            p = secrets / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
        with tarfile.open(self.payload / 'profiles/default/secrets.tar', 'w') as archive:
            archive.add(secrets, arcname='.')
        self.bin = self.root / 'commands'
        self.bin.mkdir()
        self.command(self.bin / 'systemctl', '''
if [ "$1" = --user ]; then
    [ "$XDG_RUNTIME_DIR" = "/run/user/$(id -u)" ] || exit 61
    [ "$DBUS_SESSION_BUS_ADDRESS" = "unix:path=$XDG_RUNTIME_DIR/bus" ] || exit 62
fi
exit "${MOCK_SERVICE_RC:-0}"
''')
        self.command(self.bin / 'curl', 'printf \'{"data":[{"id":"glm-5.3-flashx"}]}\\n\'')
        for name in ['git', 'loginctl', 'sleep']:
            self.command(self.bin / name, 'exit 0')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'])
        for marker in Path('/root').glob('BOOTSTRAP-*'):
            marker.unlink()
        Path('/var/log/ventoy-bootstrap.log').unlink(missing_ok=True)

    @staticmethod
    def command(path, body):
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_bootstrap(self, *args, expected=0, **env):
        result = subprocess.run(['bash', str(self.payload / 'bootstrap.sh'), *args],
                                env=dict(self.env, **env), capture_output=True, text=True, timeout=20)
        log = Path('/var/log/ventoy-bootstrap.log').read_text()
        self.assertEqual(result.returncode, expected, result.stderr + '\n' + log)
        return log

    def test_chroot_stages_without_baseline_or_full_success(self):
        log = self.run_bootstrap('--chrooted', MOCK_BASELINE_RC='99')
        self.assertTrue(Path('/root/BOOTSTRAP-STAGED').exists())
        self.assertFalse(Path('/root/BOOTSTRAP-OK').exists())
        self.assertFalse(Path('/etc/systemd/system/provision-firstboot.service').exists())
        self.assertIn('baseline=skipped', log)
        self.assertEqual(Path('/home/tester/.codex/auth.json').stat().st_uid,
                         int(subprocess.check_output(['id', '-u', 'tester'])))

    def test_full_success_runs_executable_smoke_and_sets_success(self):
        log = self.run_bootstrap()
        self.assertTrue(Path('/root/BOOTSTRAP-OK').exists())
        self.assertIn('smoke=ok', log)
        self.assertIn('services=ok', log)
        self.assertFalse(Path('/root/BOOTSTRAP-FAILED').exists())

    def test_echoed_prompt_is_not_a_successful_smoke(self):
        log = self.run_bootstrap(expected=1, MOCK_WRONG_REPLY='1')
        self.assertIn('final reply did not match', log)
        self.assertFalse(Path('/root/BOOTSTRAP-OK').exists())

    def test_baseline_failure_cannot_mark_success(self):
        log = self.run_bootstrap(expected=1, MOCK_BASELINE_RC='5')
        self.assertIn('baseline=failed', log)
        self.assertFalse(Path('/root/BOOTSTRAP-OK').exists())
        self.assertTrue(Path('/root/BOOTSTRAP-FAILED').exists())
        self.assertEqual(Path('/root/BOOTSTRAP-RC').read_text(), '1\n')

    def test_missing_secrets_cannot_mark_success(self):
        (self.payload / 'profiles/default/secrets.tar').unlink()
        log = self.run_bootstrap('--chrooted', expected=1)
        self.assertIn('secrets=failed', log)
        self.assertFalse(Path('/root/BOOTSTRAP-STAGED').exists())

    def test_service_failure_cannot_mark_success(self):
        log = self.run_bootstrap(expected=1, MOCK_SERVICE_RC='7')
        self.assertIn('services=failed', log)
        self.assertFalse(Path('/root/BOOTSTRAP-OK').exists())

    def test_skipped_baseline_does_not_suppress_firstboot(self):
        self.run_bootstrap('--no-baseline')
        self.assertTrue(Path('/root/BOOTSTRAP-STAGED').exists())
        self.assertFalse(Path('/root/BOOTSTRAP-OK').exists())

    def test_standup_layer_sudo_and_cache_wiring(self):
        (self.payload / 'profiles/default/profile.conf').write_text(
            'TARGET_USER="tester"\nREALNAME="Test User"\nGIT_EMAIL="test@example.invalid"\n'
            'ENABLE_CCR_MAIN=1\nENABLE_GLM_WORKERS=1\nENABLE_ZCODE_CREDS=0\n'
            'ENABLE_PASSWORDLESS_SUDO=1\n')
        self.command(self.bin / 'visudo', 'exit 0\n')
        log = self.run_bootstrap()
        self.assertIn('sudo=ok', log)
        self.assertIn('caches=ok', log)
        sudoers = Path('/etc/sudoers.d/tester')
        self.assertTrue(sudoers.exists())
        self.assertEqual(sudoers.stat().st_mode & 0o777, 0o440)
        self.assertEqual(sudoers.read_text(), 'tester ALL=(ALL) NOPASSWD: ALL\n')
        self.assertIn('rustc-wrapper = "/usr/local/bin/sccache"',
                      Path('/home/tester/.cargo/config.toml').read_text())
        self.assertIn('max_size = 50G',
                      Path('/home/tester/.config/ccache/ccache.conf').read_text())
        self.assertTrue(Path('/etc/profile.d/00-build-cache.sh').exists())
        self.assertIn('policy=skipped', log)
        self.assertIn('nvidia=skipped', log)

    def test_standup_sudo_rejected_by_visudo_blocks_success(self):
        (self.payload / 'profiles/default/profile.conf').write_text(
            'TARGET_USER="tester"\nREALNAME="Test User"\nGIT_EMAIL="test@example.invalid"\n'
            'ENABLE_CCR_MAIN=1\nENABLE_GLM_WORKERS=1\nENABLE_ZCODE_CREDS=0\n'
            'ENABLE_PASSWORDLESS_SUDO=1\n')
        self.command(self.bin / 'visudo', 'exit 1\n')
        Path('/etc/sudoers.d/tester').unlink(missing_ok=True)
        log = self.run_bootstrap(expected=1)
        self.assertIn('sudo=failed', log)
        self.assertFalse(Path('/root/BOOTSTRAP-OK').exists())
        self.assertFalse(Path('/etc/sudoers.d/tester').exists())


if __name__ == '__main__':
    if not Path('/.dockerenv').exists():
        raise SystemExit('Run inside a disposable Ubuntu Docker container.')
    unittest.main(verbosity=2)
