"""Regression checks for command dispatch on macOS's system Bash (3.2)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseCLITests(unittest.TestCase):
    def test_optional_arguments_on_system_bash(self):
        with tempfile.TemporaryDirectory(prefix='macpearl-release-cli-') as folder:
            work = Path(folder)
            commands = work / 'commands'
            commands.mkdir()
            log = work / 'arguments'
            for tool in ('xcodebuild', 'python3'):
                stub = commands / tool
                stub.write_text('#!/bin/bash\nprintf "%s\\n" "$0" "$@" >> "$RELEASE_TEST_LOG"\n')
                stub.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'], RELEASE_TEST_LOG=str(log))
            env.pop('MACPEARL_BUILD_NUMBER', None)
            env.pop('MACPEARL_VERSION', None)
            cases = (
                ('archive', str(work / 'signed'), False, False),
                ('archive-unsigned', str(work / 'unsigned'), True, False),
                ('inspect', '/a path/MacPearl.app', False, False),
                ('verify', '/a path/MacPearl.app', False, True),
                ('verify-notarized', '/a path/MacPearl.app', False, True),
            )
            for command, argument, unsigned, signed in cases:
                with self.subTest(command=command):
                    log.write_text('')
                    result = subprocess.run(['/bin/bash', str(ROOT / 'Scripts/release.sh'), command, argument],
                                            env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = log.read_text().splitlines()
                    self.assertEqual('CODE_SIGNING_ALLOWED=NO' in args, unsigned)
                    self.assertEqual('--signed' in args, signed)
                    self.assertEqual('--notarized' in args, command == 'verify-notarized')
                    if command.startswith('archive'):
                        self.assertIn('archive', args)
                        self.assertIn('--archive', args)
                    else:
                        self.assertIn(argument, args)

            # Overrides do not require editing the Xcode project for each release.
            env.update(MACPEARL_BUILD_NUMBER='2', MACPEARL_VERSION='0.1.1')
            log.write_text('')
            result = subprocess.run(['/bin/bash', str(ROOT / 'Scripts/release.sh'), 'archive', str(work / 'versioned')],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = log.read_text().splitlines()
            self.assertIn('CURRENT_PROJECT_VERSION=2', args)
            self.assertIn('MARKETING_VERSION=0.1.1', args)
            env['MACPEARL_BUILD_NUMBER'] = 'not-a-number'
            result = subprocess.run(['/bin/bash', str(ROOT / 'Scripts/release.sh'), 'archive', str(work / 'invalid')],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse((work / 'invalid').exists())

            log.write_text('')
            result = subprocess.run(['/bin/bash', str(ROOT / 'Scripts/release.sh'), 'package-free',
                                     '/archive with spaces/MacPearl.xcarchive', str(work / 'free dmg')],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = log.read_text().splitlines()
            self.assertIn('Scripts/package-free.py', args)
            self.assertIn('/archive with spaces/MacPearl.xcarchive', args)
            self.assertIn(str(work / 'free dmg'), args)
            result = subprocess.run(['/bin/bash', str(ROOT / 'Scripts/release.sh'), 'package-free'],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
