#!/usr/bin/env python3
"""Test the actual mounted free DMG without installing or starting unlock logic."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('dmg', type=Path)
parser.add_argument('--interactive', action='store_true', help='Ask the user to authorize a synthetic credential twice')
args = parser.parse_args()
if not args.dmg.is_file():
    parser.error('Provide an existing DMG')
with tempfile.TemporaryDirectory(prefix='macpearl-dmg-check-') as folder:
    subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse',
                    '-mountpoint', folder, str(args.dmg.resolve())], check=True)
    try:
        app = Path(folder) / 'MacPearl.app'
        subprocess.run(['python3', str(Path(__file__).with_name('verify-release.py')), '--adhoc', str(app)], check=True)
        command = [str(app / 'Contents/MacOS/MacPearl'), '--credential-self-test']
        if args.interactive:
            command.append('--interactive')
        subprocess.run(command, check=True)
    finally:
        subprocess.run(['/usr/bin/hdiutil', 'detach', folder], check=True)
