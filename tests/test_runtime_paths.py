import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class RuntimePathTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler is unavailable")
    def test_swift_runtime_path_fixtures(self):
        with tempfile.TemporaryDirectory(prefix="aircard-runtime-tests-") as temporary:
            temporary = Path(temporary)
            executable = temporary / "runtime-path-tests"
            command = [
                shutil.which("swiftc"),
                "-module-cache-path", str(temporary / "module-cache"),
                str(ROOT / "Sources" / "AppRuntimePaths.swift"),
                str(ROOT / "tests" / "runtime_paths.swift"),
                "-o", str(executable),
            ]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            checked = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertIn("Runtime path regression checks passed", checked.stdout)


if __name__ == "__main__":
    unittest.main()
