"""The local-review opt-in script: explicit on, explicit off, honest status,
and nothing else in the QA tooling writes the key (P16 review, 2026-09-04).

    python3 -m unittest discover -s scripts/qa -p 'test_*.py'
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "review.sh")
LAUNCHER = os.path.join(HERE, "qa.sh")


class ReviewSwitchTests(unittest.TestCase):
    def setUp(self):
        # A throwaway defaults domain and an empty copies directory.
        self.domain = f"com.local.reed.test-{uuid.uuid4().hex[:8]}"
        self.dir = tempfile.mkdtemp()
        self.env = dict(os.environ, REED_REVIEW_DOMAIN=self.domain, REED_REVIEW_DIR_FOR_STATUS=self.dir)

    def tearDown(self):
        subprocess.run(["defaults", "delete", self.domain], capture_output=True)

    def run_script(self, *args):
        return subprocess.run(["bash", SCRIPT, *args], capture_output=True, text=True, env=self.env)

    def key(self):
        out = subprocess.run(["defaults", "read", self.domain, "reed.localReview"], capture_output=True, text=True)
        return out.stdout.strip() if out.returncode == 0 else None

    def test_off_by_default_and_status_says_so(self):
        self.assertIsNone(self.key())
        out = self.run_script("status")
        self.assertEqual(out.returncode, 0)
        self.assertIn("local review: OFF", out.stdout)
        self.assertIn("0 copies", out.stdout)

    def test_on_writes_the_key_and_says_what_it_did_and_how_to_stop(self):
        out = self.run_script("on")
        self.assertEqual(out.returncode, 0)
        self.assertEqual(self.key(), "1")
        self.assertIn("local review: ON", out.stdout)
        self.assertIn("the recording (WAV)", out.stdout)
        self.assertIn("review.sh off", out.stdout)
        self.assertIn("local review: ON", self.run_script("status").stdout)

    def test_off_removes_the_key_and_keeps_copies(self):
        self.run_script("on")
        copy = "2026-09-04T22-48-32Z-8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json"
        for name in [copy, "2026-09-04T22-48-32Z-abc.json"]:  # the second is not a copy (review 2026-09-05)
            with open(os.path.join(self.dir, name), "w") as fh:
                fh.write("{}")
        out = self.run_script("off")
        self.assertEqual(out.returncode, 0)
        self.assertIsNone(self.key())
        self.assertIn("local review: OFF", out.stdout)
        self.assertIn("1 copies · 2 bytes", out.stdout, "off reports the copies it left behind, and only copies")
        self.assertTrue(os.path.exists(os.path.join(self.dir, copy)))

    def test_status_fails_closed_when_the_inventory_cannot_be_taken(self):
        """Review 2026-09-05 (P2): an unreadable directory is not zero copies."""
        with open(os.path.join(self.dir, "2026-09-04T22-48-32Z-8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json"), "w") as fh:
            fh.write("{}")
        os.chmod(self.dir, 0)
        try:
            out = self.run_script("status")
        finally:
            os.chmod(self.dir, 0o700)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("inventory unavailable", out.stderr)
        self.assertNotIn("0 copies", out.stdout + out.stderr)

    def test_off_when_already_off_is_not_an_error(self):
        self.assertEqual(self.run_script("off").returncode, 0)

    def test_no_argument_is_a_usage_error(self):
        out = self.run_script()
        self.assertEqual(out.returncode, 2)
        self.assertIn("usage", out.stderr)

    def test_the_launcher_never_writes_the_key(self):
        with open(LAUNCHER, encoding="utf-8") as fh:
            launcher = fh.read()
        writes = [line for line in launcher.splitlines()
                  if "defaults write" in line and "localReview" in line and not line.strip().startswith("#")]
        self.assertEqual(writes, [], "qa.sh must not write reed.localReview; only review.sh on does")


if __name__ == "__main__":
    unittest.main()
