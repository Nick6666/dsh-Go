"""Contract checks for tooling/ios/build-ipa.sh.

The script is run with --dry-run, so nothing is built and no Xcode is needed: the
checks are the argument handling, the stamped version and the command it prints.
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'tooling/ios/build-ipa.sh'


def run(*args):
    return subprocess.run(
        ['bash', str(SCRIPT), *args], capture_output=True, text=True, cwd=ROOT,
        env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'PYTHON': 'python3'},
    )


class BuildIpaDryRun(unittest.TestCase):
    def test_prints_an_unsigned_device_build_with_the_stamped_version(self):
        with tempfile.TemporaryDirectory() as out:
            done = run('--dry-run', '--build-name', '9.9.9', '--build-number', '12345678', '--output', out)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('flutter build ios --release --no-codesign', done.stdout)
        self.assertIn('--build-name 9.9.9', done.stdout)
        self.assertIn('--build-number 12345678', done.stdout)
        self.assertIn('--dart-define=DSH_APP_VERSION=9.9.9+12345678', done.stdout)
        self.assertIn('dsh-go-9.9.9-ios-arm64', done.stdout)

    def test_the_version_comes_from_the_pubspec(self):
        version = None
        for line in (ROOT / 'app/pubspec.yaml').read_text().splitlines():
            if line.startswith('version:'):
                version = line.split(':', 1)[1].strip().split('+')[0]
                break
        self.assertIsNotNone(version, 'app/pubspec.yaml has no version')
        with tempfile.TemporaryDirectory() as out:
            done = run('--dry-run', '--build-number', '12345678', '--output', out)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('--build-name ' + version, done.stdout)

    def test_rejects_a_version_name_that_is_not_semver(self):
        done = run('--dry-run', '--build-name', '1.1')
        self.assertNotEqual(done.returncode, 0)
        self.assertIn('not a version name', done.stderr)

    def test_rejects_a_signing_or_export_flag(self):
        for flag in ('--codesign', '--export-method=app-store'):
            done = run('--dry-run', '--', flag)
            self.assertNotEqual(done.returncode, 0, flag)
            self.assertIn('signing and export', done.stderr)

    def test_rejects_a_codesign_flag_this_script_owns(self):
        done = run('--dry-run', '--build-number', '1', '--', '--no-codesign')
        self.assertNotEqual(done.returncode, 0)
        self.assertIn('set by this script', done.stderr)


if __name__ == '__main__':
    unittest.main()
