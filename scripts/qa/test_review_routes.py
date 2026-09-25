"""The QA server's review routes over HTTP, against a temp review directory:
GET /review, GET /review/copy (bad ids refused), POST /review/reference
(header-guarded, written in place), POST /review/delete.

    python3 -m unittest discover -s scripts/qa -p 'test_*.py'
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class ReviewRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        os.environ["REED_REVIEW_DIR"] = cls.dir
        os.environ["REED_REVIEW_DOMAIN"] = f"com.local.reed.test-{uuid.uuid4().hex[:6]}"
        import qa_server  # noqa: E402  (after the env is set)
        cls.qa = qa_server
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), qa_server.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        shutil.rmtree(cls.dir, ignore_errors=True)
        os.environ.pop("REED_REVIEW_DIR", None)
        os.environ.pop("REED_REVIEW_DOMAIN", None)

    def setUp(self):
        for f in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, f))
        self.cid = f"2026-09-04T22-48-32Z-{str(uuid.uuid4()).upper()}.json"
        with open(os.path.join(self.dir, self.cid), "w") as fh:
            json.dump({"startedAt": "2026-09-04T22:48:32Z", "mode": "localOnly", "engine": "parakeet",
                       "segments": [{"index": 0, "boundary": "tail", "raw": "hello there", "corrected": "hello there"}],
                       "chunks": [{"segments": [0], "input": "hello there", "attempts": [], "delivered": "Hello there.", "outcome": "rulesOnly"}],
                       "finalText": "Hello there.", "timings": {"totalSeconds": 0.4}, "counts": {}, "reference": None}, fh)

    def get(self, path):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}") as r:
            return r.status, json.loads(r.read())

    def post(self, path, body=None, header=True):
        data = json.dumps(body).encode() if body is not None else b""
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method="POST")
        if header:
            req.add_header("X-Reed-QA", "1")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            with e:
                return e.code, e.read().decode()

    def test_review_lists_state_and_copies(self):
        status, body = self.get("/review")
        self.assertEqual(status, 200)
        self.assertEqual(body["state"]["count"], 1)
        self.assertEqual(body["state"]["unreviewed"], 1)
        self.assertFalse(body["state"]["collecting"])
        self.assertEqual(body["copies"][0]["id"], self.cid)

    def test_copy_returns_the_record_with_heard_and_chunk_lines(self):
        status, body = self.get(f"/review/copy?id={self.cid}")
        self.assertEqual(status, 200)
        self.assertEqual(body["record"]["finalText"], "Hello there.")
        self.assertEqual(body["heard"][0]["raw"], "hello there")
        self.assertEqual(body["chunkLines"], ["chunk (seg 0) · rulesOnly"])

    def test_bad_ids_are_refused(self):
        for bad in ["../x.json", "x.json", "2026-09-04T22-48-32Z-nope.json"]:
            with self.assertRaises(urllib.error.HTTPError) as cm:
                self.get(f"/review/copy?id={bad}")
            self.assertEqual(cm.exception.code, 400, bad)
            cm.exception.close()
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.get(f"/review/copy?id=2026-09-04T22-48-32Z-{str(uuid.uuid4()).upper()}.json")
        self.assertEqual(cm.exception.code, 404)
        cm.exception.close()

    def test_the_recording_is_served_for_a_copy_that_has_one(self):
        """2026-09-06: the review pane's player reads /review/audio?id=; same id rules as /review/copy."""
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.get(f"/review/audio?id={self.cid}")
        self.assertEqual(cm.exception.code, 404, "no recording beside this copy")
        cm.exception.close()
        wav = b"RIFF" + b"\0" * 60
        with open(os.path.join(self.dir, self.cid[:-5] + ".wav"), "wb") as fh:
            fh.write(wav)
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/review/audio?id={self.cid}")
        with urllib.request.urlopen(req) as r:
            self.assertEqual(r.headers.get("Content-Type"), "audio/wav")
            self.assertEqual(r.read(), wav)
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.get("/review/audio?id=../x.json")
        self.assertEqual(cm.exception.code, 400)
        cm.exception.close()
        # A player seeks with byte ranges (review 2026-09-07): the same sender as the bench clips.
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/review/audio?id={self.cid}", headers={"Range": "bytes=0-9"})
        with urllib.request.urlopen(req) as r:
            self.assertEqual(r.status, 206)
            self.assertEqual(r.headers.get("Content-Range"), f"bytes 0-9/{len(wav)}")
            self.assertEqual(r.read(), wav[:10])
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/review/audio?id={self.cid}", headers={"Range": "bytes=999999-"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req)
        self.assertEqual(cm.exception.code, 416)
        cm.exception.close()

    def test_reference_needs_the_header_and_text_and_lands_in_the_copy(self):
        self.assertEqual(self.post(f"/review/reference?id={self.cid}", {"text": "x"}, header=False)[0], 403)
        self.assertEqual(self.post(f"/review/reference?id={self.cid}", {"text": "   "})[0], 400)
        status, body = self.post(f"/review/reference?id={self.cid}", {"text": "Hello there, friend.", "edited": True})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["edited"], True)
        _, copy = self.get(f"/review/copy?id={self.cid}")
        self.assertEqual(copy["record"]["reference"]["text"], "Hello there, friend.")
        self.assertEqual(copy["record"]["finalText"], "Hello there.")
        self.assertEqual(self.get("/review")[1]["state"]["unreviewed"], 0)

    def test_delete_removes_every_copy(self):
        self.assertEqual(self.post("/review/delete", header=False)[0], 403)
        status, body = self.post("/review/delete")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"removed": 1, "failed": []})
        self.assertEqual(self.get("/review")[1]["state"]["count"], 0)


if __name__ == "__main__":
    unittest.main()
