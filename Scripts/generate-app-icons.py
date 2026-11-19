#!/usr/bin/env python3
"""Resize a square PNG into the sizes declared by the macOS app icon catalog."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
args = parser.parse_args()
folder = Path(__file__).resolve().parents[1] / 'MacPearl/Resources/Assets.xcassets/AppIcon.appiconset'
catalog = json.loads((folder / 'Contents.json').read_text())
for entry in catalog['images']:
    size = int(entry['size'].split('x')[0])
    scale = int(entry['scale'][0])
    name = f'app-icon-{size}x{size}@{scale}x.png'
    subprocess.run(['/usr/bin/sips', '-z', str(size * scale), str(size * scale),
                    str(args.source.resolve()), '--out', str(folder / name)], check=True)
    entry['filename'] = name
(folder / 'Contents.json').write_text(json.dumps(catalog, indent=2) + '\n')
