#!/usr/bin/env python3
"""Enable Apple's audio/PiP background mode without changing other iOS settings.
Run from the lyriKO project root: python3 enable_ios_pip_audio.py
"""
from pathlib import Path
import plistlib
import re

path = Path('ios/Runner/Info.plist')
if not path.is_file():
    raise SystemExit('Run this script from the lyriKO project root (Info.plist not found).')
original = path.read_bytes()
info = plistlib.loads(original)
modes = info.get('UIBackgroundModes', [])
if not isinstance(modes, list):
    raise SystemExit('UIBackgroundModes has an unexpected format; file left unchanged.')
if 'audio' in modes:
    print('Audio/PiP background mode already enabled. No changes made.')
    raise SystemExit(0)

# Preserve the original plist formatting and all other keys/values.
text = original.decode('utf-8')
pattern = r'(<key>UIBackgroundModes</key>\s*<array>)(.*?)(</array>)'
match = re.search(pattern, text, flags=re.DOTALL)
if match:
    updated = text[:match.end(2)] + '\n\t\t<string>audio</string>' + text[match.end(2):]
else:
    marker = '</dict>'
    if marker not in text:
        raise SystemExit('Could not locate Info.plist root dictionary; file left unchanged.')
    updated = text.replace(marker, '\t<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>audio</string>\n\t</array>\n' + marker, 1)
parsed = plistlib.loads(updated.encode('utf-8'))
assert 'audio' in parsed['UIBackgroundModes']
assert all(parsed.get(key) == value for key, value in info.items() if key != 'UIBackgroundModes')
path.write_text(updated, encoding='utf-8')
print('Enabled UIBackgroundModes: audio. Other Info.plist settings preserved.')
