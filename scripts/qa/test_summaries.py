"""The seam bench scorer never turns green on nothing (review 2026-09-07):
a failed or skipped reviewed copy is an incomplete run, a broken seam fails,
and a run that decided no seam — none at all, or all undecidable — is not ok."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import qa_server  # noqa: E402


def score_sweep(text):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(text)
    try:
        return qa_server.sum_sweep(f.name)
    finally:
        os.unlink(f.name)


def sweep_tally(**kv):
    base = dict(recordings=14, offsets=868, collapses=5, affected=3, per_mille=5.8, whole_p50_ms=110, slice_p50_ms=114, synthetic_offsets=225, synthetic_collapses=0, step=40, back=2500, synthetic_pairs=3, synthetic_back=3000)
    base.update(kv)
    return "SS|tally|" + " ".join(f"{k}={v}" for k, v in base.items()) + "\n"


class SweepScorerTests(unittest.TestCase):
    def test_under_the_ceiling_is_ok(self):
        self.assertEqual(score_sweep(sweep_tally())[0], "ok")

    def test_over_the_ceiling_fails(self):
        self.assertEqual(score_sweep(sweep_tally(collapses=39, per_mille=44.9))[0], "fail")

    def test_incomplete_coverage_or_collapsed_controls_fail(self):
        self.assertEqual(score_sweep(sweep_tally(offsets=0, collapses=0, per_mille=0))[0], "fail", "nothing measured is not zero collapses")
        self.assertEqual(score_sweep(sweep_tally(offsets=800))[0], "fail", "fewer offsets than planned")
        self.assertEqual(score_sweep(sweep_tally(synthetic_collapses=225))[0], "fail", "every control collapsed")
        self.assertEqual(score_sweep(sweep_tally(synthetic_offsets=0, synthetic_collapses=0))[0], "fail", "controls not measured")
        self.assertEqual(score_sweep(sweep_tally(step=3001, offsets=0, collapses=0, per_mille=0, synthetic_offsets=0))[0], "fail")

    def test_control_coverage_is_exact_and_the_rate_is_derived_not_read(self):
        for offsets in (1, 224, 226):
            self.assertEqual(score_sweep(sweep_tally(synthetic_offsets=offsets))[0], "fail", f"{offsets} synthetic offsets where 225 are planned")
        self.assertEqual(score_sweep(sweep_tally(collapses=39, per_mille=0))[0], "fail", "39 of 868 is over the ceiling whatever the line claims")
        self.assertEqual(score_sweep(sweep_tally(collapses=39, per_mille="nan"))[0], "fail")
        self.assertEqual(score_sweep(sweep_tally(collapses=5, per_mille=99))[0], "ok", "5 of 868 is under the ceiling whatever the line claims")
        self.assertEqual(score_sweep(sweep_tally(offsets="nan"))[0], "fail")

    def test_no_tail_warns_and_a_missing_tally_or_field_fails(self):
        self.assertEqual(score_sweep(sweep_tally(recordings=0, offsets=0, collapses=0, per_mille=0))[0], "warn")
        self.assertEqual(score_sweep("SS|env|x\n")[0], "fail")
        self.assertEqual(score_sweep("SS|tally|recordings=1 offsets=62\n")[0], "fail")


def score(text):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(text)
    try:
        return qa_server.sum_seam(f.name)
    finally:
        os.unlink(f.name)


def tally(**kv):
    base = dict(copies=1, seams=1, corrected=1, broken=0, same_right=0, same_wrong=0, undecidable=0, skipped=0, failed=0, no_recording=0, unreviewed_with_seams=0)
    base.update(kv)
    return "SR|tally|" + " ".join(f"{k}={v}" for k, v in base.items()) + "\n"


class SeamScorerTests(unittest.TestCase):
    def test_a_decided_seam_with_nothing_broken_is_ok(self):
        self.assertEqual(score(tally())[0], "ok")

    def test_a_failed_or_skipped_reviewed_copy_is_an_incomplete_run(self):
        self.assertEqual(score("SR|copy|a|1|1|0|0|0|0\n" + tally(copies=1, failed=1))[0], "fail")
        self.assertEqual(score(tally(skipped=1))[0], "fail")

    def test_a_copy_without_a_recording_is_reported_not_failed(self):
        status, text = score(tally(no_recording=2))
        self.assertEqual(status, "ok")
        self.assertIn("2 reviewed copies have no recording", text)

    def test_a_broken_seam_fails(self):
        self.assertEqual(score(tally(seams=2, corrected=1, broken=1))[0], "fail")

    def test_no_decided_seam_is_never_green(self):
        self.assertEqual(score(tally(copies=0, seams=0, corrected=0))[0], "warn")
        self.assertEqual(score(tally(seams=2, corrected=0, undecidable=2))[0], "warn")

    def test_a_missing_tally_or_field_fails(self):
        self.assertEqual(score("SR|env|x\n")[0], "fail")
        self.assertEqual(score("SR|tally|copies=1 seams=1 corrected=1 broken=0\n")[0], "fail")


def score_reading(text):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(text)
    try:
        return qa_server.sum_seam_reading(f.name)
    finally:
        os.unlink(f.name)


def reading_tally(**kv):
    base = dict(copies=5, reviewed=0, seams=6, located=6, read=6, period=3, comma=2, nothing=1, undecided=0, changed=3, words_changed=0,
                ms_p50=120, ms_max=300, scored=0, corrected=0, broken=0, same_right=0, same_wrong=0, unscorable=0, mismatch=0, unreadable=0,
                missing=0, no_recording=0, gapped=0, unfaithful=0, cued=0)
    base.update(kv)
    return "SW|tally|" + " ".join(f"{k}={v}" for k, v in base.items()) + "\n"


class SeamReadingScorerTests(unittest.TestCase):
    def test_nothing_scored_is_a_warning_never_green(self):
        status, text = score_reading(reading_tally())
        self.assertEqual(status, "warn")
        self.assertIn("5 copies with a pause await review", text)

    def test_a_changed_word_or_an_unreadable_or_missing_recording_fails(self):
        self.assertEqual(score_reading(reading_tally(words_changed=1))[0], "fail")
        self.assertEqual(score_reading(reading_tally(unreadable=1))[0], "fail")
        self.assertEqual(score_reading(reading_tally(missing=1))[0], "fail")

    def test_skipped_copies_are_reported_not_hidden(self):
        status, text = score_reading(reading_tally(gapped=2, unfaithful=3, no_recording=1, cued=1))
        self.assertEqual(status, "warn")
        self.assertIn("2 copies skipped: a segment index is missing", text)
        self.assertIn("1 copies skipped: a correction cue crosses a pause", text)
        self.assertIn("3 older copies skipped", text)
        self.assertIn("1 copies have no recording", text)

    def test_a_tally_without_the_skip_fields_fails(self):
        line = reading_tally().replace(" missing=0 no_recording=0 gapped=0 unfaithful=0 cued=0", "")
        self.assertEqual(score_reading(line)[0], "fail")

    def test_scored_seams_decide_by_corrected_against_broken(self):
        self.assertEqual(score_reading(reading_tally(reviewed=2, scored=4, corrected=3, broken=0, same_right=1))[0], "ok")
        self.assertEqual(score_reading(reading_tally(reviewed=2, scored=4, corrected=3, broken=1))[0], "warn")
        self.assertEqual(score_reading(reading_tally(reviewed=2, scored=4, corrected=1, broken=1))[0], "fail")
        self.assertEqual(score_reading(reading_tally(reviewed=2, scored=4, corrected=0, broken=0, same_right=4))[0], "warn")

    def test_a_missing_tally_or_field_fails(self):
        self.assertEqual(score_reading("SW|env|x\n")[0], "fail")
        self.assertEqual(score_reading("SW|tally|copies=1 seams=1\n")[0], "fail")


if __name__ == "__main__":
    unittest.main()
