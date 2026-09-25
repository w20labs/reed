"""The QA page's side of local review copies: state, listing, loading with
path confinement, references written in place, delete-all, and the pane's
derived views. Runs against a temp directory; never the developer's own.

    python3 -m unittest discover -s scripts/qa -p 'test_*.py'
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import local_review  # noqa: E402


def record(final="Hello there.", reference=None, segments=None, chunks=None, total=0.8):
    return {
        "id": "x", "startedAt": "2026-09-04T22:48:32Z", "deliveredAt": "2026-09-04T22:48:33Z",
        "mode": "localOnly", "engine": "parakeet",
        "versions": {"app": "0.2.4 (1)", "prompt": "v5", "gate": "2026-09-06-r3", "schema": 3, "flags": {}},
        "segments": segments or [{"index": 0, "boundary": "tail", "raw": "hello there", "corrected": "hello there", "cleanupPath": "ai"}],
        "chunks": chunks or [{"segments": [0], "input": "hello there", "attempts": [{"kind": "generic", "proposal": "Hello there.", "verdict": "accepted", "seconds": 0.3}],
                              "delivered": "Hello there.", "outcome": "modelAccepted"}],
        "finalText": final, "timings": {"totalSeconds": total}, "counts": {"chunks": 1}, "reference": reference,
    }


def copy_id(stamp="2026-09-04T22-48-32Z"):
    return f"{stamp}-{str(uuid.uuid4()).upper()}.json"


class LocalReviewTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        os.environ["REED_REVIEW_DOMAIN"] = f"com.local.reed.test-{uuid.uuid4().hex[:6]}"

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)
        os.environ.pop("REED_REVIEW_DOMAIN", None)

    def write(self, rec, cid=None):
        cid = cid or copy_id()
        (self.dir / cid).write_text(json.dumps(rec))
        return cid

    def test_state_counts_bytes_unreviewed_and_the_key(self):
        s = local_review.state(self.dir)
        self.assertEqual((s["count"], s["bytes"], s["unreviewed"], s["oldestExpires"]), (0, 0, 0, None))
        self.assertFalse(s["collecting"], "a throwaway domain has no key")
        self.write(record())
        self.write(record(reference={"text": "Hello there.", "setBy": "human", "setAt": "x", "edited": False}))
        s = local_review.state(self.dir)
        self.assertEqual((s["count"], s["unreviewed"]), (2, 1))
        self.assertGreater(s["bytes"], 0)
        self.assertRegex(s["oldestExpires"], r"^\d{4}-\d{2}-\d{2}T")

    def test_listing_marks_reviewed_and_previews_the_typed_text(self):
        long = "word " * 40
        a = self.write(record(final=long))
        rows = local_review.listing(self.dir)
        self.assertEqual([r["id"] for r in rows], [a])
        self.assertFalse(rows[0]["reviewed"])
        self.assertTrue(rows[0]["preview"].endswith("…"))
        self.assertEqual(rows[0]["segments"], 1)
        self.assertEqual(rows[0]["pauses"], 0)

    def test_listing_counts_pause_seams_so_they_can_be_reviewed_first(self):
        rec = record()
        rec["segments"] = [{"index": 0, "boundary": "pause", "raw": "a", "corrected": "a"},
                           {"index": 1, "boundary": "cap", "raw": "b", "corrected": "b"},
                           {"index": 2, "boundary": "pause", "raw": "c", "corrected": "c"},
                           {"index": 3, "boundary": "tail", "raw": "d", "corrected": "d"}]
        self.write(rec)
        self.assertEqual(local_review.listing(self.dir)[0]["pauses"], 2)

    def test_only_copy_ids_load_and_never_outside_the_directory(self):
        cid = self.write(record())
        self.assertEqual(local_review.load(cid, self.dir)["finalText"], "Hello there.")
        for bad in ["../etc/passwd", "notes.json", "2026-09-04T22-48-32Z-x.json", "/tmp/x.json"]:
            with self.assertRaises(ValueError):
                local_review.load(bad, self.dir)

    def test_only_a_fully_formed_name_on_a_regular_file_is_a_copy(self):
        """Review 2026-09-05 (P2): a malformed id is not a copy and is never touched."""
        strays = [
            "2026-09-04T22-48-32Z-" + "-" * 36 + ".json",
            "2026-09-04T22-48-32Z-notes-from-the-team-kept-here-long.json",
            "2026-13-04T22-48-32Z-8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json",
            "2026-09-04T22-48-32Z_8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json",
        ]
        for name in strays:
            self.write(record(), name)
            self.assertFalse(local_review.is_copy_id(name), name)
            with self.assertRaises(ValueError):
                local_review.load(name, self.dir)
        real = "2026-09-04T22-48-32Z-8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json"
        (self.dir / real).mkdir()  # a directory named like a copy is not a copy
        self.assertTrue(local_review.is_copy_id(real))
        with self.assertRaises(ValueError):
            local_review.load(real, self.dir)
        self.assertEqual(local_review.listing(self.dir), [])
        self.assertEqual(local_review.state(self.dir)["count"], 0)
        self.assertEqual(local_review.delete_all(self.dir), {"removed": 0, "failed": []})
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), sorted(strays + [real]))

    def test_a_trailing_newline_or_a_symlink_is_not_a_copy(self):
        """Review 2026-09-05 (P2): the whole string must be the name, and a
        symlink named like a copy is refused before it is resolved."""
        cid = self.write(record())
        self.assertFalse(local_review.is_copy_id(cid + "\n"))
        with self.assertRaises(ValueError):
            local_review.load(cid + "\n", self.dir)
        link = copy_id()
        (self.dir / link).symlink_to(self.dir / cid)  # points INSIDE the directory
        with self.assertRaises(ValueError):
            local_review.load(link, self.dir)
        with self.assertRaises(ValueError):
            local_review.save_reference(link, "x", False, self.dir)
        self.assertEqual([r["id"] for r in local_review.listing(self.dir)], [cid])
        self.assertEqual(local_review.delete_all(self.dir)["removed"], 1)
        self.assertTrue((self.dir / link).is_symlink(), "the link was never touched")

    def test_a_recording_beside_a_copy_is_listed_counted_served_and_deleted_with_it(self):
        """2026-09-06: the dictation's WAV lives beside the copy under the same name."""
        cid = self.write(dict(record(), audioFile=None))
        with_audio = self.write(dict(record(), audioFile="x"))
        (self.dir / local_review.audio_name(with_audio)).write_bytes(b"RIFF" + b"\0" * 96)
        rows = {r["id"]: r for r in local_review.listing(self.dir)}
        self.assertFalse(rows[cid]["audio"])
        self.assertTrue(rows[with_audio]["audio"])
        st = local_review.state(self.dir)
        self.assertEqual(st["withAudio"], 1)
        self.assertEqual(st["recordings"], 1)
        self.assertEqual(st["bytes"], sum(p.stat().st_size for p in self.dir.iterdir()), "bytes count the recording")
        self.assertEqual(local_review.audio_path(with_audio, self.dir), (self.dir / local_review.audio_name(with_audio)).resolve())
        self.assertIsNone(local_review.audio_path(cid, self.dir))
        with self.assertRaises(ValueError):
            local_review.audio_path("../x.json", self.dir)
        link = local_review.audio_name(copy_id())
        (self.dir / link).symlink_to(self.dir / local_review.audio_name(with_audio))
        with self.assertRaises(ValueError):
            local_review.audio_path(link[:-4] + ".json", self.dir)
        self.assertEqual(local_review.delete_all(self.dir)["removed"], 3, "two copies and one recording; the link is not a recording")
        self.assertTrue((self.dir / link).is_symlink())

    def test_an_orphaned_recording_is_counted_and_deletable(self):
        """Review 2026-09-07: a recording whose copy is gone still shows in the
        state (so Delete is offered) and goes with delete-all."""
        (self.dir / local_review.audio_name(copy_id())).write_bytes(b"RIFF" + b"\0" * 60)
        st = local_review.state(self.dir)
        self.assertEqual((st["count"], st["recordings"], st["withAudio"]), (0, 1, 0))
        self.assertGreater(st["bytes"], 0)
        self.assertEqual(local_review.delete_all(self.dir), {"removed": 1, "failed": []})
        self.assertEqual(local_review.state(self.dir)["recordings"], 0)

    def test_expiry_comes_from_the_name_not_the_filesystem(self):
        old_id = copy_id("2026-08-01T10-00-00Z")
        self.write(record(), old_id)
        rows = {r["id"]: r for r in local_review.listing(self.dir)}
        self.assertEqual(rows[old_id]["expiresAt"], "2026-08-15T10:00:00Z")
        self.assertEqual(local_review.state(self.dir)["oldestExpires"], "2026-08-15T10:00:00Z")

    def test_a_reference_is_written_in_place_and_keeps_the_creation_time(self):
        cid = self.write(record())
        path = self.dir / cid
        st = path.stat()
        born = getattr(st, "st_birthtime", None)
        inode = st.st_ino
        ref = local_review.save_reference(cid, "Hello there, friend.", edited=True, dir_=self.dir)
        self.assertEqual(ref["setBy"], "human")
        self.assertTrue(ref["edited"])
        again = local_review.load(cid, self.dir)
        self.assertEqual(again["reference"]["text"], "Hello there, friend.")
        self.assertEqual(again["finalText"], "Hello there.", "the typed text is never overwritten")
        self.assertEqual(path.stat().st_ino, inode, "written in place, not replaced")
        if born is not None:
            self.assertEqual(path.stat().st_birthtime, born, "the creation time the app expires on is untouched")

    def test_delete_all_removes_every_copy_and_reports(self):
        self.write(record()); self.write(record())
        (self.dir / "not-a-copy.txt").write_text("keep me")
        out = local_review.delete_all(self.dir)
        self.assertEqual(out, {"removed": 2, "failed": []})
        self.assertEqual(local_review.listing(self.dir), [])
        self.assertTrue((self.dir / "not-a-copy.txt").exists(), "only copies are touched")

    def test_heard_and_chunk_lines_are_ordered_and_content_free_where_promised(self):
        rec = record(segments=[{"index": 1, "boundary": "tail", "raw": "b", "corrected": "b", "joinedBy": "gluedBreath"},
                               {"index": 0, "boundary": "pause", "raw": "a", "corrected": "a"}],
                     chunks=[{"segments": [0], "input": "a", "attempts": [{"kind": "repair", "verdict": "gate:truncation", "seconds": 0.4},
                                                                          {"kind": "generic", "verdict": "accepted", "seconds": 0.3}],
                              "delivered": "A.", "outcome": "modelAccepted"}])
        heard = local_review.heard(rec)
        self.assertEqual([h["index"] for h in heard], [0, 1])
        self.assertEqual(heard[1]["joinedBy"], "gluedBreath")
        lines = local_review.chunk_lines(rec)
        self.assertEqual(lines, ["chunk (seg 0) · modelAccepted · repair→gate:truncation 0.4s, generic→accepted 0.3s"])
        self.assertNotIn("A.", lines[0], "chunk lines carry outcomes, not text")


if __name__ == "__main__":
    unittest.main()
