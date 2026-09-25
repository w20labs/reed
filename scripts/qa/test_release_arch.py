"""Apple Silicon only (DECIDED 2026-09-06), on the release side: a packaged
executable must be exactly arm64, and an arm64-only release tells Sparkle so
in the appcast, so an Intel install of an earlier universal build is never
offered an app it cannot launch.

    python3 -m unittest discover -s scripts/qa -p 'test_*.py'
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def build(archs: list[str], out: Path) -> Path:
    """A Mach-O with exactly these slices (system binaries are arm64e, not arm64)."""
    src = out.with_suffix(".c")
    src.write_text("int main(void) { return 0; }\n")
    flags = [f for a in archs for f in ("-arch", a)]
    subprocess.run(["xcrun", "clang", *flags, "-o", str(out), str(src)], check=True, capture_output=True)
    return out


class AssertArm64Tests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())

    def run_assert(self, path: Path):
        return subprocess.run([str(ROOT / "scripts" / "build" / "assert-arm64.sh"), str(path)], capture_output=True, text=True)

    def test_an_arm64_only_binary_passes(self):
        self.assertEqual(self.run_assert(build(["arm64"], self.dir / "arm")).returncode, 0)

    def test_an_x86_64_binary_is_refused(self):
        """The Rosetta host's "native" build."""
        out = self.run_assert(build(["x86_64"], self.dir / "x86"))
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("must be arm64 only, got: x86_64", out.stderr)

    def test_a_universal_binary_is_refused(self):
        out = self.run_assert(build(["x86_64", "arm64"], self.dir / "fat"))
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("must be arm64 only", out.stderr)


class CheckAppcastTests(unittest.TestCase):
    """The gate the release tooling runs on the freshly generated feed."""

    def check(self, xml: str, version: str):
        d = Path(tempfile.mkdtemp()); p = d / "appcast.xml"; p.write_text(xml)
        return subprocess.run([sys.executable, str(ROOT / "scripts" / "build" / "check-appcast.py"), str(p), version], capture_output=True, text=True)

    @staticmethod
    def feed(items: str) -> str:
        return f'<rss xmlns:sparkle="{SPARKLE}"><channel>{items}</channel></rss>'

    def test_passes_only_when_the_release_is_present_and_arm64(self):
        good = self.feed("<item><title>Reed 0.2.5</title><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements></item>")
        self.assertEqual(self.check(good, "0.2.5").returncode, 0)
        self.assertNotEqual(self.check(good, "0.2.6").returncode, 0, "the release being published must be in the feed")
        no_req = self.feed("<item><title>Reed 0.2.5</title></item>")
        self.assertNotEqual(self.check(no_req, "0.2.5").returncode, 0, "an item without the arm64 requirement is refused")
        self.assertNotEqual(self.check("not xml", "0.2.5").returncode, 0)


if __name__ == "__main__":
    unittest.main()
