"""A release strips the shipped executable only after its dSYM holds the symbols."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MAKE_APP = (ROOT / "scripts/make-app.sh").read_text(encoding="utf-8")
RELEASE_BLOCK_START = 'if [[ "$CONFIG" == release ]]; then\n  dsymutil'


def release_block() -> str:
    start = MAKE_APP.index(RELEASE_BLOCK_START)
    return MAKE_APP[start:MAKE_APP.index("\nfi\n", start) + 4]


class ReleaseSymbolOrderTests(unittest.TestCase):
    def test_symbols_leave_the_binary_after_the_copy_and_before_signing(self):
        copy = MAKE_APP.index('cp "$BIN" "$APP/Contents/MacOS/portavoz-app"')
        block = MAKE_APP.index(RELEASE_BLOCK_START)
        strip = MAKE_APP.index('strip -x -S "$APP/Contents/MacOS/portavoz-app"')

        self.assertLess(copy, block)
        self.assertLess(block, MAKE_APP.index("Section __debug_info:"))
        self.assertLess(MAKE_APP.index("Section __debug_info:"), strip)
        self.assertLess(strip, MAKE_APP.index("codesign "))

    def test_a_new_build_never_keeps_an_older_dsym(self):
        self.assertIn('rm -rf "$APP" "$APP.dSYM"', MAKE_APP)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("dsymutil"), "needs the Xcode toolchain")
class ReleaseSymbolBehaviorTests(unittest.TestCase):
    def run_block(self, root: Path, *, debug_info: bool) -> tuple[subprocess.CompletedProcess[str], Path]:
        source = root / "crash.c"
        source.write_text("static int hidden(int x) { return x * 3; }\nint main(int c, char **v) { return hidden(c); }\n")
        binary = root / "Portavoz.app/Contents/MacOS/portavoz-app"
        binary.parent.mkdir(parents=True)
        objects = root / "crash.o"
        flags = ["-g"] if debug_info else []
        subprocess.run(["clang", *flags, "-O0", "-c", source, "-o", objects], check=True)
        subprocess.run(["clang", objects, "-o", binary], check=True)
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", f'CONFIG=release\nAPP="$1"\n{release_block()}', "-", root / "Portavoz.app"],
            capture_output=True, text=True,
        )
        return result, binary

    def symbols(self, binary: Path) -> str:
        return subprocess.run(["nm", "-ap", binary], check=True, capture_output=True, text=True).stdout

    def test_the_dsym_symbolicates_what_the_stripped_binary_lost(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result, binary = self.run_block(root, debug_info=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("_hidden", self.symbols(binary))
            self.assertNotIn(" OSO ", self.symbols(binary))
            dwarf = root / "Portavoz.app.dSYM/Contents/Resources/DWARF/portavoz-app"
            address = next(
                line.split()[0] for line in self.symbols(dwarf).splitlines() if line.endswith(" _hidden"))
            located = subprocess.run(
                ["atos", "-o", dwarf, "-l", "0x100000000", f"0x{address}"],
                check=True, capture_output=True, text=True,
            ).stdout
            self.assertIn("hidden", located)
            self.assertIn("crash.c:1", located)

    def test_a_binary_without_debug_info_is_not_stripped(self):
        with tempfile.TemporaryDirectory() as directory:
            result, binary = self.run_block(Path(directory), debug_info=False)

            self.assertEqual(result.returncode, 70)
            self.assertIn("no debug info", result.stderr)
            self.assertIn("_hidden", self.symbols(binary))


if __name__ == "__main__":
    unittest.main()
