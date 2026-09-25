"""Tests for the log tripwire and its wiring into the QA page's unit rows.

    python3 -m unittest discover -s scripts/qa -p 'test_*.py'
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
import log_health  # noqa: E402
import qa_server  # noqa: E402

STAMP = "2026-09-04T19:20:17Z "
FLOOD = STAMP + "[audio] INFO: availableDevices: 4 candidate id(s) -> 3 after filtering: fifine Microphone"
QUIET = [STAMP + "[parakeet] INFO: parakeet v3 ready",
         STAMP + "[timings] NOTICE: total 1.8s · asr 0.3s·parakeet",
         STAMP + "[pipeline] INFO: state -> recording",
         STAMP + "[inject] INFO: posted ⌘V CGEvents"]


class ShapeTests(unittest.TestCase):
    def test_normaliser_contract(self):
        self.assertEqual(log_health.self_test(), 0)


class VerdictTests(unittest.TestCase):
    def test_dominated_healthy_and_too_small(self):
        self.assertEqual(log_health.verdict([FLOOD] * 450 + QUIET * 13)[0], 1)
        self.assertEqual(log_health.verdict(QUIET * 130)[0], 0)
        self.assertEqual(log_health.verdict([FLOOD] * 499)[0], 2)

    def test_unreadable_file_is_no_verdict_not_a_pass(self):
        code, message = log_health.verdict_for(Path("/nonexistent/reed.log"))
        self.assertEqual(code, 2)
        self.assertIn("unreadable", message)


class QAWiringTests(unittest.TestCase):
    """Each unit row is judged on ITS OWN run's app log (the sibling
    `<row>.txt.app.log`), never a shared file: dominated fails the row,
    too small is a warning tile and never a pass."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.run = os.path.join(self.tmp, "unit_core.txt")
        with open(self.run, "w") as fh:
            fh.write("Executed 10 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _with_app_log(self, lines, path=None):
        with open(qa_server.app_log_path(path or self.run), "w") as fh:
            fh.write("\n".join(lines) + "\n")

    def test_dominated_sibling_log_is_a_bad_metric(self):
        self._with_app_log([FLOOD] * 450 + QUIET * 13)
        m = qa_server.log_health_metric(self.run)
        self.assertEqual((m["status"], m["value"]), ("bad", "DOMINATED"))
        self.assertIn("availableDevices", m["note"])

    def test_healthy_sibling_log_is_ok(self):
        self._with_app_log(QUIET * 40)
        self.assertEqual(qa_server.log_health_metric(self.run)["status"], "ok")

    def test_small_or_missing_sibling_log_is_a_warning_never_a_pass(self):
        self.assertEqual(qa_server.log_health_metric(self.run)["status"], "warn")  # no sibling at all
        self._with_app_log(QUIET * 5)
        m = qa_server.log_health_metric(self.run)
        self.assertEqual((m["status"], m["value"]), ("warn", "no verdict"))

    def test_a_dominated_app_log_fails_the_row_even_when_every_case_passed(self):
        self._with_app_log([FLOOD] * 450 + QUIET * 13)
        status, message = qa_server.sum_unit(self.run)
        self.assertEqual(status, "fail")
        self.assertIn("LOG DOMINATED", message)

    def test_a_healthy_app_log_leaves_a_green_row_green(self):
        self._with_app_log(QUIET * 40)
        self.assertEqual(qa_server.sum_unit(self.run)[0], "ok")

    def test_a_small_app_log_does_not_fail_a_filtered_row(self):
        self._with_app_log(QUIET * 5)
        status, message = qa_server.sum_unit(self.run)
        self.assertEqual(status, "ok")
        self.assertNotIn("DOMINATED", message)

    def test_the_row_judges_its_own_run_not_another_rows_or_a_shared_file(self):
        other = os.path.join(self.tmp, "unit_pipeline.txt")
        self._with_app_log([FLOOD] * 450 + QUIET * 13, path=other)  # someone else's flood
        self._with_app_log(QUIET * 40)                               # this row's run
        self.assertEqual(qa_server.sum_unit(self.run)[0], "ok")

    def test_the_process_is_told_to_write_the_running_app_log(self):
        env = qa_server.run_env({"env": {"REED_X": "1"}}, self.run)
        self.assertEqual(env[qa_server.APP_LOG_ENV], self.run + ".running.app.log")
        self.assertEqual(env["REED_X"], "1")

    def test_a_run_starts_without_a_previous_attempts_files(self):
        for stale in (self.run + ".running", self.run + ".running.app.log"):
            open(stale, "w").close()
        tmp = qa_server.prepare_run(self.run)
        self.assertEqual(tmp, self.run + ".running")
        self.assertFalse(os.path.exists(tmp))
        self.assertFalse(os.path.exists(tmp + ".app.log"))

    def test_promotion_moves_stdout_and_app_log_together(self):
        self._with_app_log(QUIET * 40)                       # last good run's sibling
        tmp = self.run + ".running"
        open(tmp, "w").write("new run\n")
        self._with_app_log([FLOOD] * 450, path=tmp)
        qa_server.promote_run(tmp, self.run)
        self.assertEqual(open(self.run).read(), "new run\n")
        self.assertIn("availableDevices", open(qa_server.app_log_path(self.run)).read())
        self.assertFalse(os.path.exists(tmp) or os.path.exists(tmp + ".app.log"))

    def test_promotion_of_a_run_that_wrote_no_app_log_leaves_no_stale_sibling(self):
        self._with_app_log([FLOOD] * 450)                    # an old flood beside the last run
        tmp = self.run + ".running"
        open(tmp, "w").write("bench run\n")
        qa_server.promote_run(tmp, self.run)
        self.assertFalse(os.path.exists(qa_server.app_log_path(self.run)), "an old sibling must not be judged as this run's")

    def test_dropping_an_archived_run_drops_its_app_log_too(self):
        hist = os.path.join(self.tmp, "unit_core-20260904-120000.txt")
        open(hist, "w").close(); open(qa_server.app_log_path(hist), "w").close()
        qa_server.remove_archived(hist)
        self.assertFalse(os.path.exists(hist) or os.path.exists(qa_server.app_log_path(hist)))
        qa_server.remove_archived(hist)  # already gone: not an error

    def test_every_unit_row_carries_the_metric(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
            fh.write("Executed 10 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n")
        try:
            for bid in [a[0] for a in qa_server._UNIT_AREAS]:
                labels = [m["label"] for m in qa_server.metrics_for(bid, fh.name)]
                self.assertIn("log health", labels, bid)
        finally:
            os.unlink(fh.name)


if __name__ == "__main__":
    unittest.main()
