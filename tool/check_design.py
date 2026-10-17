import json
import pathlib
import re
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'tool/generate_translations.py'), '--check'], check=True)
translations = json.loads((root / 'lib/l10n/strings_en.json').read_text(encoding='utf-8'))
keys = set()
for file in [*root.glob('lib/ui/*.dart'), *root.glob('lib/core/*.dart')]:
    source = file.read_text(encoding='utf-8')
    for match in re.finditer(r'(?:tr\(context,\s*|localizeMessage\()((?:"(?:[^"\\]|\\.)*")|(?:\'(?:[^\'\\]|\\.)*\'))', source):
        literal = match[1]
        key = json.loads(literal) if literal.startswith('"') else literal[1:-1]
        keys.add(key)
missing = keys - translations.keys()
if missing:
    raise RuntimeError(f'Missing translations: {missing}')
for size, density in [(48, 'mdpi'), (72, 'hdpi'), (96, 'xhdpi'), (144, 'xxhdpi'), (192, 'xxxhdpi')]:
    path = root / f'platform_assets/android/res/mipmap-{density}/ic_launcher.png'
    content = path.read_bytes()
    if content[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', content[16:24]) != (size, size):
        raise RuntimeError(f'Invalid Android launcher icon: {density}')
for file in root.glob('platform_assets/android/**/*.xml'):
    ET.parse(file)
for asset in ['brand.png', 'tray.png', 'tray.ico', 'source.png']:
    if not (root / 'assets/icons' / asset).is_file():
        raise RuntimeError(f'Missing shared brand asset: {asset}')
print(f'Validated {len(keys)} referenced translation keys, Android XML, launcher sizes and shared brand assets')
