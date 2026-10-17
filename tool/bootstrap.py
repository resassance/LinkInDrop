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
for name in ["MainActivity.kt", "ConnectionService.kt", "ClipboardTile.kt", "FolderAccess.kt", "BridgeApplication.kt", "PlatformBridge.kt", "BootReceiver.kt", "ReceiveFiles.kt", "LocalNetwork.kt", "ReceivedDocumentsProvider.kt", "NativeStrings.kt"]:
    shutil.copyfile(assets / name, kotlin / name)
drawable = target / "res" / "drawable"
drawable.mkdir(parents=True, exist_ok=True)
shutil.copytree(assets / "res", target / "res", dirs_exist_ok=True)
old_tile = drawable / "tile_icon.xml"
if old_tile.exists():
    old_tile.unlink()
shutil.copyfile(root / "assets/icons/tray.ico", root / "windows/runner/resources/app_icon.ico")
for file in [root / "windows/runner/Runner.rc", root / "windows/runner/main.cpp", root / "linux/runner/my_application.cc"]:
    if file.exists():
        value = file.read_text(encoding="utf-8").replace('"nearbridge"', '"LinkInDrop"')
        value = value.replace('L"nearbridge"', 'L"LinkInDrop"')
        file.write_text(value, encoding="utf-8")
for platform in ["windows", "linux"]:
    cmake = root / platform / "CMakeLists.txt"
    if cmake.exists():
        value = cmake.read_text(encoding="utf-8").replace('set(BINARY_NAME "nearbridge")', 'set(BINARY_NAME "LinkInDrop")')
        cmake.write_text(value, encoding="utf-8")
gradle = root / "android" / "app" / "build.gradle.kts"
if gradle.exists():
    value = gradle.read_text(encoding="utf-8")
    if "import java.util.Properties" not in value:
        value = "import java.util.Properties\n\n" + value
    value = value.replace("minSdk = flutter.minSdkVersion", "minSdk = 23")
    value = value.replace("ndkVersion = flutter.ndkVersion", 'ndkVersion = "27.0.12077973"')
    value = value.replace('signingConfig = signingConfigs.getByName("debug")', '\n'.join([
        'if (file("nearbridge-signing.properties").exists()) {',
        'signingConfig = signingConfigs.create("nearbridgeRelease") {',
        'val credentials = Properties().apply {',
        'file("nearbridge-signing.properties").inputStream().use { load(it) }',
        '}',
        'storeFile = file("nearbridge-release.p12")',
        'storePassword = credentials.getProperty("storePassword")',
        'keyAlias = "nearbridge"',
        'keyPassword = credentials.getProperty("storePassword")',
        '}',
        '} else { signingConfig = signingConfigs.getByName("debug") }',
    ]))
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
