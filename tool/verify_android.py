import os
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
sdk = pathlib.Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
tools = sorted((sdk / "build-tools").glob("*/apksigner"), key=lambda path: [int(part) for part in re.findall(r"\d+", path.parent.name)])
if not tools:
    raise RuntimeError("apksigner is not installed")
result = subprocess.run([str(tools[-1]), "verify", "--print-certs", str(root / "build/app/outputs/flutter-apk/app-release.apk")], check=True, text=True, capture_output=True)
fingerprints = {value.lower() for value in re.findall(r"certificate SHA-256 digest:\s*([a-fA-F0-9]+)", result.stdout)}
expected = (root / "platform_assets/android/release-certificate.sha256").read_text().strip()
print("APK signer certificate fingerprints: " + ", ".join(sorted(fingerprints)))
if fingerprints != {expected}:
    raise RuntimeError("APK is not signed by the permanent Nearbridge release certificate")
print("Verified permanent Nearbridge Android signing certificate")
