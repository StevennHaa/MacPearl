#!/usr/bin/env python3
"""Create a local ad-hoc-signed DMG. Never uploads, installs or notarizes."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile

SCRIPTS = Path(__file__).resolve().parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def package(archive, output):
    archive, output = archive.resolve(), output.resolve()
    # Validate before creating output, and never modify the source archive.
    run('python3', SCRIPTS / 'verify-release.py', '--archive', archive)
    output.mkdir(parents=True, exist_ok=False)
    source = archive / 'Products/Applications/MacPearl.app'
    with (source / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    name = f"MacPearl-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}-arm64-experimental.dmg"
    with tempfile.TemporaryDirectory(prefix='macpearl-free-') as folder:
        stage = Path(folder) / 'image'
        stage.mkdir()
        app = stage / 'MacPearl.app'
        run('/usr/bin/ditto', source, app)
        metadata = app / 'Contents/Info.plist'
        with metadata.open('rb') as stream:
            packaged_info = plistlib.load(stream)
        packaged_info['MacPearlCredentialStorage'] = 'secure-enclave-v1'
        metadata.write_bytes(plistlib.dumps(packaged_info))
        # No Apple-issued application prefix exists for this route. The app uses
        # ordinary service/account Keychain queries, not shared access groups.
        entitlements = Path(folder) / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.device.camera': True}))
        run('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
            '--options', 'runtime', '--entitlements', entitlements, app)
        run('python3', SCRIPTS / 'verify-release.py', '--adhoc', app)
        # Exercise real Keychain CRUD and verify Enclave user-presence enforcement
        # in the final ad-hoc process. No GUI prompt, camera or user password.
        run(app / 'Contents/MacOS/MacPearl', '--credential-self-test')
        (stage / 'Applications').symlink_to('/Applications')
        (stage / 'READ ME FIRST.txt').write_text((SCRIPTS.parent / 'Docs/free-download-installation.txt').read_text())
        dmg = output / name
        run('/usr/bin/hdiutil', 'create', '-volname', 'MacPearl Experimental',
            '-srcfolder', stage, '-format', 'UDZO', dmg)
    run('/usr/bin/hdiutil', 'verify', dmg)
    digest = hashlib.sha256()
    with dmg.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    checksum = digest.hexdigest()
    (output / f'{name}.sha256').write_text(f'{checksum}  {name}\n')
    print(f'Local DMG: {dmg}')
    print('Ad-hoc signed only: no verified publisher, notarization or Gatekeeper approval.')
    print('Keep local until model redistribution rights and downloaded-build device testing are complete.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('output', type=Path, help='New output directory; existing paths are rejected')
    args = parser.parse_args()
    package(args.archive, args.output)
