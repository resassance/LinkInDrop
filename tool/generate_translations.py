import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
folder = root / 'lib/l10n'
russian = json.loads((folder / 'strings_ru.json').read_text(encoding='utf-8'))
english = json.loads((folder / 'strings_en.json').read_text(encoding='utf-8'))
if russian.keys() != english.keys():
    raise RuntimeError('Translation keys differ between Russian and English')
for key, value in english.items():
    if set(re.findall(r'\{\d+\}', key)) != set(re.findall(r'\{\d+\}', value)):
        raise RuntimeError(f'Translation arguments differ: {key!r}')

def literal(value):
    return json.dumps(value, ensure_ascii=False).replace('$', r'\$')

content = 'const englishStrings = <String, String>{\n'
content += ''.join(f'  {literal(key)}: {literal(value)},\n' for key, value in english.items())
content += '};\n'
target = folder / 'translations.dart'
if '--check' in sys.argv:
    tokens = lambda text: re.findall(r'"(?:[^"\\]|\\.)*"|[^\s]', text)
    if tokens(target.read_text(encoding='utf-8')) != tokens(content):
        raise RuntimeError('Run python tool/generate_translations.py to update translations.dart')
else:
    target.write_text(content, encoding='utf-8')
print(f'Validated {len(english)} Russian/English translation templates')
