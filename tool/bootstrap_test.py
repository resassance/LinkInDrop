import pathlib
import runpy
import shutil
import tempfile
import unittest
from unittest.mock import patch


class BootstrapTest(unittest.TestCase):
    def test_platform_assets_and_identity_survive_bootstrap(self):
        project = pathlib.Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix='linkindrop-bootstrap-') as folder:
            root = pathlib.Path(folder)
            shutil.copytree(project / 'platform_assets', root / 'platform_assets')
            shutil.copytree(project / 'assets/icons', root / 'assets/icons')
            (root / 'tool').mkdir()
            shutil.copyfile(project / 'tool/bootstrap.py', root / 'tool/bootstrap.py')

            def create_platforms(command, **kwargs):
                self.assertIn('--project-name=linkindrop', command)
                self.assertIn('--org=dev.resassance', command)
                main = root / 'android/app/src/main'
                main.mkdir(parents=True)
                gradle = root / 'android/app/build.gradle.kts'
                gradle.write_text('minSdk = flutter.minSdkVersion\nndkVersion = flutter.ndkVersion\nsigningConfig = signingConfigs.getByName("debug")\n')
                for platform in ['windows', 'linux']:
                    cmake = root / platform / 'CMakeLists.txt'
                    cmake.parent.mkdir(exist_ok=True)
                    cmake.write_text('set(BINARY_NAME "linkindrop")\n')
                for name in ['windows/runner/resources/app_icon.ico', 'windows/runner/Runner.rc', 'windows/runner/main.cpp', 'linux/runner/my_application.cc']:
                    target = root / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text('"linkindrop"\n')

            with patch('shutil.which', return_value='/fake/flutter'), patch('subprocess.run', side_effect=create_platforms):
                runpy.run_path(str(root / 'tool/bootstrap.py'), run_name='__main__')
            self.assertEqual((root / 'windows/runner/resources/app_icon.ico').read_bytes(), (root / 'assets/icons/tray.ico').read_bytes())
            self.assertIn('LinkInDrop', (root / 'windows/runner/main.cpp').read_text())
            self.assertIn('set(BINARY_NAME "LinkInDrop")', (root / 'windows/CMakeLists.txt').read_text())
            self.assertIn('LinkInDrop', (root / 'linux/runner/my_application.cc').read_text())
            self.assertFalse((root / 'android/app/src/main/res/drawable/tile_icon.xml').exists())
            self.assertTrue((root / 'android/app/src/main/res/drawable/tile_icon.png').exists())
            self.assertTrue((root / 'android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml').exists())
            self.assertTrue((root / 'android/app/src/main/kotlin/dev/resassance/linkindrop/NativeStrings.kt').exists())
            manifest = (root / 'android/app/src/main/AndroidManifest.xml').read_text()
            self.assertIn('android:label="LinkInDrop"', manifest)
            self.assertIn('dev.resassance.linkindrop.received', manifest)
            self.assertIn('linkindropRelease', (root / 'android/app/build.gradle.kts').read_text())


if __name__ == '__main__':
    unittest.main()
