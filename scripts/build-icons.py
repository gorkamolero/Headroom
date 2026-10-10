#!/usr/bin/env python3
"""Build Headroom's icons from Saga's existing black-sun vector contours.

Requires rsvg-convert (librsvg) and the macOS sips/iconutil tools.
Committed assets let ordinary app builds run without librsvg.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'Assets'
art = json.loads((ASSETS / 'black-sun-paths.json').read_text())
disc = art['disc']
paths = ''.join(f'<path d="{path}"/>' for group in art['groups'] for path in group['paths'])

def mark(flame, centre):
    return (f'<g transform="translate(512 512) scale(.88) translate(-{disc["cx"]} -{disc["cy"]})">'
            f'<g fill="{flame}" transform="{art["transform"]}">{paths}</g>'
            f'<circle cx="{disc["cx"]}" cy="{disc["cy"]}" r="{disc["r"]}" {centre}/></g>')

svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
       '<rect x="64" y="64" width="896" height="896" rx="198" fill="#F2EAD9"/>'
       + mark('#C73E22', 'fill="#161615"') + '</svg>')
(ASSETS / 'AppIcon.svg').write_text(svg)
subprocess.run(['rsvg-convert', str(ASSETS/'AppIcon.svg'), '-o', str(ASSETS/'AppIcon.png')], check=True)
for name, centre in [('StatusOn', 'fill="black"'), ('StatusOff', 'fill="none" stroke="black" stroke-width="42"')]:
    # A tighter viewport makes the flame silhouette legible at menu-bar size.
    status = ('<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="155 155 714 714">'
              + mark('black', centre) + '</svg>')
    (ASSETS / f'{name}.svg').write_text(status)
    subprocess.run(['rsvg-convert', '-f', 'pdf', str(ASSETS/f'{name}.svg'), '-o', str(ASSETS/f'{name}.pdf')], check=True)

with tempfile.TemporaryDirectory(prefix='headroom-icons-') as temporary:
    iconset = Path(temporary) / 'AppIcon.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            subprocess.run(['sips', '-z', str(pixels), str(pixels), str(ASSETS/'AppIcon.png'),
                            '--out', str(iconset/filename)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(ASSETS/'AppIcon.icns')], check=True)
print('Built app icon and monochrome menu-bar templates.')
