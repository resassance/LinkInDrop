import pathlib
import re
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
flutter = shutil.which("flutter") or shutil.which("flutter.bat")
if flutter is None:
    raise RuntimeError("Flutter is not on PATH")
subprocess.run([flutter, "create", "--platforms=android,windows,linux", "--org=dev.resassance", "--project-name=nearbridge", "."], cwd=root, check=True, shell=sys.platform == "win32")
assets = root / "platform_assets" / "android"
target = root / "android" / "app" / "src" / "main"
shutil.copyfile(assets / "AndroidManifest.xml", target / "AndroidManifest.xml")
kotlin = target / "kotlin" / "dev" / "resassance" / "nearbridge"
kotlin.mkdir(parents=True, exist_ok=True)
for name in ["MainActivity.kt", "ConnectionService.kt", "ClipboardTile.kt"]:
    shutil.copyfile(assets / name, kotlin / name)
drawable = target / "res" / "drawable"
drawable.mkdir(parents=True, exist_ok=True)
shutil.copyfile(assets / "tile_icon.xml", drawable / "tile_icon.xml")
gradle = root / "android" / "app" / "build.gradle.kts"
if gradle.exists():
    value = gradle.read_text(encoding="utf-8")
    value = value.replace("minSdk = flutter.minSdkVersion", "minSdk = 23")
    gradle.write_text(value, encoding="utf-8")
for folder in ["android", "windows", "linux"]:
    for file in (root / folder).rglob("*"):
        if file.suffix in {".cpp", ".h", ".kt", ".kts"} and file.is_file():
            value = file.read_text(encoding="utf-8")
            value = re.sub(r"/\*.*?\*/", "", value, flags=re.S)
            value = "\n".join(line for line in value.splitlines() if not line.lstrip().startswith("//")) + "\n"
            file.write_text(value, encoding="utf-8")
generated_test = root / "test" / "widget_test.dart"
if generated_test.exists() and "MyApp" in generated_test.read_text(encoding="utf-8"):
    generated_test.unlink()
