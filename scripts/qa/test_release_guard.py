"""The release guard (review 2026-09-08): a release cut forces release/arm64
whatever the shell inherited, and artifact verification rejects a bundle
that is not stamped release/arm64."""
import os
import plistlib
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def resolve(env):
    full = dict(os.environ)
    for k in ("CONFIG", "ARCH", "BUILD_MODE"):
        full.pop(k, None)
    full.update(env)
    out = subprocess.run(["bash", os.path.join(ROOT, "build-app.sh"), "--resolve-only"], env=full, capture_output=True, text=True, cwd=ROOT)
    return out.returncode, out.stdout


def check(plist):
    with tempfile.NamedTemporaryFile("wb", suffix=".plist", delete=False) as f:
        plistlib.dump(plist, f)
    try:
        out = subprocess.run([os.path.join(ROOT, "scripts/build/check-build-config.sh"), f.name], capture_output=True, text=True)
        return out.returncode
    finally:
        os.unlink(f.name)


class ReleaseGuardTests(unittest.TestCase):
    def test_a_release_cut_forces_release_arm64_over_an_inherited_debug_shell(self):
        code, out = resolve({"BUILD_MODE": "release", "CONFIG": "debug", "ARCH": "native"})
        self.assertEqual(code, 0, out)
        self.assertIn("resolved: release arm64", out)
        self.assertIn("forcing CONFIG=release ARCH=arm64", out)

    def test_a_local_build_keeps_what_the_shell_asked_for(self):
        code, out = resolve({"CONFIG": "debug", "ARCH": "native"})
        self.assertEqual(code, 0, out)
        self.assertIn("resolved: debug native", out)

    def test_verification_rejects_missing_unknown_or_debug_stamps(self):
        self.assertEqual(check({"CFBundleShortVersionString": "0.2.5"}), 1, "missing stamp")
        self.assertEqual(check({"ReedBuildConfiguration": "debug", "ReedBuildArch": "arm64"}), 1, "debug")
        self.assertEqual(check({"ReedBuildConfiguration": "release", "ReedBuildArch": "native"}), 1, "native arch")
        self.assertEqual(check({"ReedBuildConfiguration": "weird", "ReedBuildArch": "arm64"}), 1, "unknown")
        self.assertEqual(check({"ReedBuildConfiguration": "release", "ReedBuildArch": "arm64"}), 0, "release arm64 passes")


if __name__ == "__main__":
    unittest.main()
