"""The cleanup bench's measures, each on a synthetic record whose answer is
known, plus the aggregate and the exit codes.

    python3 -m unittest discover -s scripts/qa -p 'test_*.py'
"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import review_bench as rb  # noqa: E402


def rec(segments, final, reference=None, total=1.0):
    return {"id": "r", "segments": segments, "finalText": final, "timings": {"totalSeconds": total},
            "reference": {"text": reference, "setBy": "human", "setAt": "x", "edited": True} if reference is not None else None}


def seg(index, boundary, text):
    return {"index": index, "boundary": boundary, "raw": text, "corrected": text}


class EditDistanceTests(unittest.TestCase):
    def test_identical_is_zero_and_one_change_per_word(self):
        self.assertEqual(rb.normalised_edit_distance("Hello there.", "hello there"), 0.0)
        self.assertEqual(rb.normalised_edit_distance("drag their food", "drag their feet"), 1 / 3)
        self.assertEqual(rb.edit_distance(["a", "b", "c"], ["a", "c"]), 1)


class SeamTests(unittest.TestCase):
    def test_a_pause_kept_as_a_period_agrees_with_a_reference_that_breaks_there(self):
        r = rec([seg(0, "pause", "tell me"), seg(1, "tail", "that intake is hard")], "Tell me. That intake is hard.", "Tell me. That intake is hard.")
        self.assertEqual(rb.seam_agreement(r, r["reference"]["text"]), (1, 1))

    def test_a_wrong_period_at_a_pause_disagrees_with_the_reference(self):
        r = rec([seg(0, "pause", "other firms tell me"), seg(1, "tail", "that intake is hard")],
                "Other firms tell me. That intake is hard.", "Other firms tell me that intake is hard.")
        self.assertEqual(rb.seam_agreement(r, r["reference"]["text"]), (0, 1))

    def test_cap_seams_are_not_counted_and_a_deleted_neighbour_is_undecidable(self):
        r = rec([seg(0, "cap", "the quick"), seg(1, "tail", "brown fox")], "The quick brown fox.", "The quick brown fox.")
        self.assertEqual(rb.seam_agreement(r, r["reference"]["text"]), (0, 0))
        r = rec([seg(0, "pause", "um"), seg(1, "tail", "hello")], "Hello.", "Hello.")
        self.assertEqual(rb.seam_agreement(r, r["reference"]["text"]), (0, 0), "'um' was deleted: no answer at that seam")


class RestartTests(unittest.TestCase):
    def test_candidates_are_phrases_re_spoken_right_after_themselves(self):
        self.assertEqual(rb.restart_candidates(rb.words("hi my name is my name is aram")), [("my", "name", "is")])
        self.assertEqual(rb.restart_candidates(rb.words("very very good")), [], "single words are never candidates")
        self.assertEqual(rb.restart_candidates(rb.words("no no no")), [])

    def test_precision_and_recall_cases(self):
        heard = [seg(0, "tail", "hi my name is my name is aram")]
        tp = rec(heard, "Hi, my name is Aram.", "Hi, my name is Aram.")
        self.assertEqual(rb.restart_outcomes(tp, tp["reference"]["text"]), (1, 0, 0))
        fn = rec(heard, "Hi my name is my name is Aram.", "Hi, my name is Aram.")
        self.assertEqual(rb.restart_outcomes(fn, fn["reference"]["text"]), (0, 0, 1))
        emphasis = [seg(0, "tail", "it was so cold so cold that night")]
        fp = rec(emphasis, "It was so cold that night.", "It was so cold, so cold that night.")
        self.assertEqual(rb.restart_outcomes(fp, fp["reference"]["text"]), (0, 1, 0))


class HarmfulTests(unittest.TestCase):
    def test_an_invented_word_and_a_lost_negation_are_harmful(self):
        r = rec([seg(0, "tail", "the meeting is not at noon")], "The meeting is at noon tomorrow.", "The meeting is not at noon.")
        self.assertEqual(rb.harmful_edits(r, r["reference"]["text"]), ["invented:tomorrow", "lost-negation:1"])
        clean = rec([seg(0, "tail", "the meeting is not at noon")], "The meeting is not at noon.", "The meeting is not at noon.")
        self.assertEqual(rb.harmful_edits(clean, clean["reference"]["text"]), [])


class BenchTests(unittest.TestCase):
    def test_unreviewed_copies_are_not_scored(self):
        self.assertEqual(rb.bench([rec([seg(0, "tail", "hello")], "Hello.")]), {"reviewed": 0})
        self.assertIn("no reviewed copies", rb.render({"reviewed": 0}))

    def test_aggregate_reports_each_measure_separately(self):
        rs = [rec([seg(0, "pause", "tell me"), seg(1, "tail", "that is hard")], "Tell me. That is hard.", "Tell me. That is hard.", total=0.5),
              rec([seg(0, "tail", "my name is my name is aram")], "My name is Aram.", "My name is Aram.", total=1.5)]
        out = rb.bench(rs)
        self.assertEqual(out["reviewed"], 2)
        self.assertEqual(out["editDistance"]["max"], 0.0)
        self.assertEqual(out["seams"], {"agree": 1, "total": 1, "accuracy": 1.0})
        self.assertEqual((out["restarts"]["tp"], out["restarts"]["precision"], out["restarts"]["recall"]), (1, 1.0, 1.0))
        self.assertEqual(out["harmful"], [])
        self.assertEqual((out["latency"]["p50"], out["latency"]["max"]), (0.5, 1.5))
        text = rb.render(out)
        for label in ["edit distance", "seam accuracy", "restarts", "harmful edits", "latency"]:
            self.assertIn(label, text)


if __name__ == "__main__":
    unittest.main()
