import pathlib
import subprocess
import tempfile
import unittest


class MediaOrderTest(unittest.TestCase):
    def test_recent_media_uses_capture_date_with_file_dates_as_fallback(self):
        source = pathlib.Path(__file__).resolve().parent.parent / 'platform_assets/android/MediaOrder.java'
        with tempfile.TemporaryDirectory(prefix='linkindrop-media-order-') as directory:
            root = pathlib.Path(directory)
            runner = root / 'RecentMediaTest.java'
            runner.write_text('''import dev.resassance.linkindrop.MediaOrder;
import java.util.ArrayList;
import java.util.Arrays;
public class RecentMediaTest {
    public static void main(String[] args) {
        long[][] rows = {
            {1, 1000, 9, 100},
            {2, 3000, 1, 100},
            {3, 0, 4, 1},
            {4, 0, 0, 5},
            {5, 3000, 1, 100}
        };
        var sorted = new ArrayList<long[]>(Arrays.asList(rows));
        sorted.sort((a,b) -> MediaOrder.compare(a[1],a[2],a[3],a[0],b[1],b[2],b[3],b[0]));
        long[] expected = {4,3,5,2,1};
        for (int i=0;i<expected.length;i++) {
            if (sorted.get(i)[0] != expected[i]) throw new AssertionError("Wrong recent-media order at " + i);
        }
    }
}
''', encoding='utf-8')
            compiled = subprocess.run(['javac', '-d', directory, str(source), str(runner)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run(['java', '-cp', directory, 'RecentMediaTest'], capture_output=True, text=True)
            self.assertEqual(executed.returncode, 0, executed.stderr)


if __name__ == '__main__':
    unittest.main()
