import base64
import os
import pathlib

encoded = os.environ.get("NB_ANDROID_KEYSTORE")
password = os.environ.get("NB_ANDROID_STORE_PASSWORD")
if not encoded or not password:
    raise RuntimeError("Permanent Android signing secrets are required")
target = pathlib.Path(__file__).resolve().parent.parent / "android/app/nearbridge-release.p12"
target.write_bytes(base64.b64decode(encoded, validate=True))
target.chmod(0o600)
