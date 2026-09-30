#!/usr/bin/env python3
"""Linux container-only behavioral checks; uses synthetic profiles and commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LatehookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.target = self.root / 'target'
        self.payload = self.target / 'root/provision-copy'
        (self.payload / 'profiles/default/ssh').mkdir(parents=True)
        (self.payload / '.copy-complete').touch()
        (self.payload / 'profiles/default/profile.conf').write_text('TARGET_USER="tester"\n')
        (self.payload / 'profiles/default/ssh/test.pub').write_text('ssh-ed25519 test-key test\n')
        shutil.copy2(ROOT / 'stick/provision/latehook.sh', self.payload)
        (self.target / 'etc').mkdir()
        (self.target / 'etc/passwd').write_text('tester:x:1000:1000:Tester:/home/tester:/bin/bash\n')
        self.stick = self.root / 'stick'
        (self.stick / 'provision').mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ['mountpoint', 'umount', 'sync']:
            self.command(name, 'exit 0')
        self.command('curtin', 'printf "%s\\n" "$@" > "$TARGET/curtin-args"\nexit "${MOCK_RC:-0}"')
        self.env = dict(os.environ, TARGET=str(self.target), VTOY_MNT=str(self.stick),
                        PATH=str(self.bin) + ':' + os.environ['PATH'])

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_hook(self, **env):
        result = subprocess.run(['bash', str(self.payload / 'latehook.sh')],
                                env=dict(self.env, **env), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return next((self.stick / 'logs').glob('default-*'))

    def test_staging_installs_access_retry_and_logs(self):
        logdir = self.run_hook()
        keys = self.target / 'home/tester/.ssh/authorized_keys'
        self.assertIn('test-key', keys.read_text())
        self.assertEqual(keys.stat().st_mode & 0o777, 0o600)
        unit = (self.target / 'etc/systemd/system/provision-retry.service').read_text()
        self.assertIn('After=network-online.target\n', unit)
        self.assertNotIn('After=network-online.target multi-user.target', unit)
        self.assertIn('TimeoutStartSec=45min', unit)
        self.assertIn('ConditionPathExists=!/root/BOOTSTRAP-OK', unit)
        self.assertIn('--target=' + str(self.target), (self.target / 'curtin-args').read_text())
        self.assertIn('rc=0', (logdir / 'RESULT').read_text())
        self.assertFalse((self.target / 'root/BOOTSTRAP-OK').exists())

    def test_bootstrap_failure_is_logged_without_aborting_install(self):
        logdir = self.run_hook(MOCK_RC='37')
        self.assertEqual((logdir / 'BOOTSTRAP-RC').read_text(), '37\n')
        self.assertIn('rc=37', (logdir / 'BOOTSTRAP-FAILED').read_text())

    def test_hung_chroot_is_bounded(self):
        self.command('curtin', 'sleep 30')
        logdir = self.run_hook(BOOTSTRAP_TIMEOUT='0.1')
        self.assertEqual((logdir / 'BOOTSTRAP-RC').read_text(), '124\n')

    def test_partial_copy_never_runs_and_still_installs_recovery(self):
        (self.payload / '.copy-complete').unlink()
        logdir = self.run_hook()
        self.assertFalse((self.target / 'curtin-args').exists())
        self.assertEqual((logdir / 'BOOTSTRAP-RC').read_text(), 'copy-incomplete\n')
        self.assertTrue((self.target / 'usr/local/sbin/provision-retry.sh').exists())
        self.assertTrue((self.target / 'home/tester/.ssh/authorized_keys').exists())

    def test_retry_propagates_bootstrap_failure(self):
        self.run_hook()
        # Only a disposable Linux container may exercise generated absolute paths.
        self.assertTrue(Path('/.dockerenv').exists(), 'run inside the test container')
        retry_source = Path('/root/provision-copy')
        retry_source.mkdir(parents=True, exist_ok=True)
        (retry_source / '.copy-complete').touch()
        (retry_source / 'bootstrap.sh').write_text('#!/bin/bash\nexit 23\n')
        script = self.target / 'usr/local/sbin/provision-retry.sh'
        result = subprocess.run(['bash', str(script)], timeout=10)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(Path('/root/BOOTSTRAP-RC').read_text(), '23\n')


if __name__ == '__main__':
    if not Path('/.dockerenv').exists():
        raise SystemExit('Run in a disposable Ubuntu Docker container, with project mounted at /work read-only.')
    unittest.main(verbosity=2)
