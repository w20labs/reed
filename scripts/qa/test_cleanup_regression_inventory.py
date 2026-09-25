"""Keep the retained review regressions in the normal Text pipeline run."""
import json
import os
import re
import sys
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
import qa_server


class CleanupRegressionInventoryTests(unittest.TestCase):
    def test_text_pipeline_selects_every_retained_review_test(self):
        suite = "CleanupReviewRegressionTests"
        areas = qa_server._UNIT_AREAS
        owners = [area[0] for area in areas if suite in area[3]]
        self.assertEqual(owners, ["unit_text"])
        row = next(area for area in areas if area[0] == "unit_text")
        command = row[4]["cmd"]
        selection = command[command.index("--filter") + 1]
        cases = qa_server.case_inventory("unit_text", suite)
        self.assertTrue(cases, "the retained regression suite must not disappear from the inventory")
        for case in cases:
            with self.subTest(case=case):
                self.assertIsNotNone(re.search(selection, f"ReedTests.{suite}/{case}"))

    def test_live_page_exposes_the_suite_before_its_first_run(self):
        suite = "CleanupReviewRegressionTests"
        with ThreadingHTTPServer(("127.0.0.1", 0), qa_server.Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                base = f"http://127.0.0.1:{server.server_address[1]}"
                with urllib.request.urlopen(base + "/progress?id=unit_text", timeout=5) as response:
                    progress = json.load(response)
                self.assertIn(suite, progress["inventory"])
                with urllib.request.urlopen(base + f"/suite?id=unit_text&name={suite}", timeout=5) as response:
                    detail = json.load(response)
                self.assertIn("testQuotedInstructionsAndNestedQuotesAreNotRestarts", detail["inventory"])
                self.assertIn("testAcceptedModelPostPassRetainsTheSameReviewCases", detail["inventory"])
            finally:
                server.shutdown()
                worker.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
