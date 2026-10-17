import base64
import hashlib
import os
import pathlib
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


class SigningTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('keytool'), 'JDK keytool is required')
    def test_existing_private_key_is_preserved_under_the_product_alias(self):
        project = pathlib.Path(__file__).resolve().parent.parent
        real_run = subprocess.run
        with tempfile.TemporaryDirectory(prefix='linkindrop-signing-') as folder:
            root = pathlib.Path(folder)
            (root / 'tool').mkdir()
            shutil.copyfile(project / 'tool/sign_android.py', root / 'tool/sign_android.py')
            (root / 'android/app').mkdir(parents=True)
            (root / 'platform_assets/android').mkdir(parents=True)
            original = root / 'original.p12'
            password = 'linkindrop-test-password'
            real_run(['keytool', '-genkeypair', '-alias', 'initial-key', '-keystore', str(original),
                      '-storetype', 'PKCS12', '-keyalg', 'RSA', '-keysize', '2048', '-dname',
                      'CN=LinkInDropTest', '-storepass', password, '-keypass', password, '-validity', '1'],
                     check=True, capture_output=True)
            certificate = real_run(['keytool', '-exportcert', '-keystore', str(original), '-alias',
                                    'initial-key', '-storepass', password], check=True, capture_output=True).stdout
            fingerprint = hashlib.sha256(certificate).hexdigest()
            (root / 'platform_assets/android/release-certificate.sha256').write_text(fingerprint)
            (root / 'android/app/build.gradle.kts').write_text(
                'linkindrop-signing.properties\nsigningConfigs.create("linkindropRelease")\n')

            def run(command, **kwargs):
                if str(command[0]).endswith('gradlew'):
                    return subprocess.CompletedProcess(command, 0,
                        stdout=f'Variant: release\nSHA-256: {fingerprint}\n', stderr='')
                return real_run(command, **kwargs)

            with patch.dict(os.environ, {'NB_ANDROID_KEYSTORE': base64.b64encode(original.read_bytes()).decode(),
                                         'NB_ANDROID_STORE_PASSWORD': password}), patch('subprocess.run', side_effect=run):
                runpy.run_path(str(root / 'tool/sign_android.py'), run_name='__main__')
            renamed = root / 'android/app/linkindrop-release.p12'
            exported = real_run(['keytool', '-exportcert', '-keystore', str(renamed), '-alias',
                                 'linkindrop', '-storepass', password], check=True, capture_output=True).stdout
            self.assertEqual(certificate, exported)
            self.assertEqual((root / 'android/app/linkindrop-signing.properties').read_text(),
                             f'storePassword={password}\n')


if __name__ == '__main__':
    unittest.main()
