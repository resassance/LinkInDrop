import base64
import hashlib
import os
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
encoded = os.environ.get("NB_ANDROID_KEYSTORE")
password = os.environ.get("NB_ANDROID_STORE_PASSWORD")
if not encoded or not password:
    raise RuntimeError("Permanent Android signing secrets are required")
target = root / "android/app/linkindrop-release.p12"
target.write_bytes(base64.b64decode(encoded, validate=True))
target.chmod(0o600)
listing = subprocess.run(["keytool", "-J-Duser.language=en", "-list", "-v", "-keystore", str(target), "-storepass:env", "NB_ANDROID_STORE_PASSWORD"], check=True, text=True, capture_output=True).stdout
aliases = re.findall(r"^Alias name:\s*(.+)$", listing, re.MULTILINE)
if len(aliases) != 1:
    raise RuntimeError("The release keystore must contain exactly one signing alias")
if aliases[0].strip() != "linkindrop":
    subprocess.run(["keytool", "-changealias", "-keystore", str(target), "-alias", aliases[0].strip(), "-destalias", "linkindrop", "-storepass:env", "NB_ANDROID_STORE_PASSWORD", "-keypass:env", "NB_ANDROID_STORE_PASSWORD"], check=True, capture_output=True)
certificate = subprocess.run(["keytool", "-exportcert", "-keystore", str(target), "-alias", "linkindrop", "-storepass:env", "NB_ANDROID_STORE_PASSWORD"], check=True, capture_output=True).stdout
fingerprint = hashlib.sha256(certificate).hexdigest()
expected = (root / "platform_assets/android/release-certificate.sha256").read_text().strip()
if fingerprint != expected:
    raise RuntimeError(f"Signing secret certificate {fingerprint} differs from pinned certificate {expected}")
gradle = (root / "android/app/build.gradle.kts").read_text()
if 'linkindrop-signing.properties' not in gradle or 'signingConfigs.create("linkindropRelease")' not in gradle:
    raise RuntimeError("Android Gradle signing configuration was not installed")
properties = root / "android/app/linkindrop-signing.properties"
escaped = password.replace(chr(92), chr(92) * 2).replace(chr(10), chr(92) + "n").replace(chr(13), chr(92) + "r")
properties.write_text("storePassword=" + escaped + "\n")
properties.chmod(0o600)
print("Prepared pinned permanent Android signing certificate " + fingerprint)
report = subprocess.run([str(root / "android/gradlew"), ":app:signingReport", "--console=plain"], cwd=root / "android", text=True, capture_output=True)
if report.returncode != 0:
    print("\n".join((report.stdout + report.stderr).splitlines()[-80:]))
    raise RuntimeError("Gradle signing preflight failed")
release = re.search(r"Variant:\s*release\b(?:(?!Variant:).)*?SHA-256:\s*([a-fA-F0-9:]+)", report.stdout, re.S)
if release is None or release.group(1).replace(":", "").lower() != expected:
    raise RuntimeError("Gradle release variant does not use the pinned Android certificate")
print("Gradle release variant uses the permanent Android signing certificate")
