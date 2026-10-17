import pathlib
import sys

from PIL import Image

root = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'assets/icons/source.png'
image = Image.open(source).convert('RGBA')
icons = root / 'assets/icons'
icons.mkdir(parents=True, exist_ok=True)
if source.resolve() != (icons / 'source.png').resolve():
    image.save(icons / 'source.png')
image.resize((512, 512), Image.Resampling.LANCZOS).save(icons / 'brand.png')
image.resize((64, 64), Image.Resampling.LANCZOS).save(icons / 'tray.png')
image.save(icons / 'tray.ico', sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
resources = root / 'platform_assets/android/res'
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    target = resources / f'mipmap-{density}'
    target.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(target / 'ic_launcher.png')
drawable = resources / 'drawable'
drawable.mkdir(parents=True, exist_ok=True)
image.resize((128, 128), Image.Resampling.LANCZOS).save(drawable / 'tile_icon.png')
foreground = Image.new('RGBA', (432, 432))
mark = image.resize((288, 288), Image.Resampling.LANCZOS)
foreground.alpha_composite(mark, (72, 72))
foreground.save(drawable / 'launcher_foreground.png')
