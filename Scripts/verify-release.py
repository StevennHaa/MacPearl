#!/usr/bin/env python3
"""Validate the shipping product locally; never mutates the app or contacts a notary service."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, include_stderr=False):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return result.stdout + result.stderr if include_stderr else result.stdout


def inspect(args):
    path = args.path.resolve()
    if args.archive:
        applications = path / 'Products/Applications'
        require(applications.is_dir(), 'Missing archive Applications directory')
        require(sorted(p.name for p in applications.iterdir()) == ['MacPearl.app'],
                'Archive must contain exactly MacPearl.app in Applications')
        products = path / 'Products'
        require(sorted(p.name for p in products.iterdir()) == ['Applications'],
                'Unexpected installed products in archive')
        app = applications / 'MacPearl.app'
    else:
        app = path
    require(app.is_dir() and app.name == 'MacPearl.app', 'Expected MacPearl.app')
    forbidden = ('MacPearlAuthorizationPlugin', 'MacPearlCameraBroker', 'macpearl-authctl')
    for child in app.rglob('*'):
        require(not any(name in child.name for name in forbidden), f'Research product present: {child}')
        require(child.suffix != '.xctest', f'Test bundle present: {child}')
        if child.is_symlink():
            require(child.resolve().is_relative_to(app.resolve()), f'External symlink: {child}')
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    require(info.get('CFBundleIdentifier') == 'com.stevenha.MacPearl', 'Unexpected bundle identifier')
    require(info.get('LSUIElement') is True, 'Menu bar app configuration missing')
    require(info.get('NSCameraUsageDescription'), 'Camera usage description missing')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion'):
        require(info.get(key), f'Missing {key}')
    require(info.get('CFBundleExecutable') == 'MacPearl', 'Unexpected executable')
    executable = app / 'Contents/MacOS/MacPearl'
    architectures = run('/usr/bin/lipo', '-archs', str(executable)).decode().strip()
    require(architectures == 'arm64', f'Expected initial arm64 release, got {architectures}')
    require(any((app / 'Contents/Resources').rglob('InsightFaceMobileFaceNet.mlmodelc')),
            'Compiled recognition model missing')
    print(f"Contents OK: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), "
        f"macOS {info['LSMinimumSystemVersion']}+, {architectures}")
    if args.signed or args.notarized or args.adhoc:
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
        details = run('/usr/bin/codesign', '-d', '--verbose=4', str(app), include_stderr=True).decode()
        if args.adhoc:
            require('Signature=adhoc' in details, 'Ad-hoc signature required')
            require(info.get('MacPearlCredentialStorage') == 'secure-enclave-v1',
                    'Free app must select Secure Enclave credential storage')
        else:
            require('Authority=Developer ID Application:' in details, 'Developer ID Application signature required')
            require('TeamIdentifier=FY4JUG23QT' in details, 'Unexpected signing team')
        require(re.search(r'flags=.*\bruntime\b', details), 'Hardened runtime missing')
        if not args.adhoc:
            require(re.search(r'^Timestamp=.+$', details, re.MULTILINE), 'Secure timestamp missing')
        raw = run('/usr/bin/codesign', '-d', '--entitlements', ':-', str(app), include_stderr=True)
        start = raw.find(b'<?xml')
        end = raw.find(b'</plist>', start)
        require(start >= 0 and end >= 0, 'Cannot read signature entitlements')
        entitlements = plistlib.loads(raw[start:end + len(b'</plist>')])
        require(not entitlements.get('com.apple.security.get-task-allow'), 'Debug entitlement present')
        require(entitlements.get('com.apple.security.device.camera') is True, 'Camera entitlement missing')
        if args.adhoc:
            require(not entitlements.get('keychain-access-groups'), 'Unexpected shared Keychain group')
            print('Ad-hoc signature, runtime and camera entitlement OK; no publisher identity or notarization')
        else:
            print('Developer ID signature, team, runtime, timestamp and required entitlements OK')
    if args.notarized:
        run('/usr/bin/xcrun', 'stapler', 'validate', str(app))
        run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=4', str(app))
        print('Stapled ticket and Gatekeeper assessment OK; hardware testing is still required')
    elif not args.signed and not args.adhoc:
        print('Structure check only: signing/notarization and device behavior are NOT validated')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    parser.add_argument('--archive', action='store_true')
    parser.add_argument('--signed', action='store_true')
    parser.add_argument('--notarized', action='store_true')
    parser.add_argument('--adhoc', action='store_true')
    try:
        args = parser.parse_args()
        require(not (args.adhoc and (args.signed or args.notarized)), 'Choose ad-hoc or Developer ID verification')
        inspect(args)
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output.decode(errors='replace'), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors='replace'), file=sys.stderr)
        sys.exit(1)
