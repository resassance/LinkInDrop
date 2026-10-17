import hashlib
import pathlib
import re
import shutil
import sys
import tarfile
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
output = root / "dist"
output.mkdir(exist_ok=True)
platform = sys.argv[1]
version_match = re.search(r"^version:\s*([^\s+]+)", (root / "pubspec.yaml").read_text(), re.MULTILINE)
if version_match is None:
    raise RuntimeError("pubspec.yaml has no version")
version = version_match.group(1)
if platform == "android":
    shutil.copyfile(root / "build/app/outputs/flutter-apk/app-release.apk", output / f"linkindrop-{version}-android.apk")
elif platform == "linux":
    bundle = root / "build/linux/x64/release/bundle"
    with tarfile.open(output / f"linkindrop-{version}-linux-x64.tar.gz", "w:gz") as archive:
        archive.add(bundle, arcname="LinkInDrop")
elif platform == "windows":
    bundle = root / "build/windows/x64/runner/Release"
    with zipfile.ZipFile(output / f"linkindrop-{version}-windows-x64.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for file in bundle.rglob("*"):
            if file.is_file():
                archive.write(file, file.relative_to(bundle))
for file in output.iterdir():
    if file.name.endswith(".sha256"):
        continue
    checksum = hashlib.sha256(file.read_bytes()).hexdigest()
    file.with_name(file.name + ".sha256").write_text(f"{checksum}  {file.name}\n")

