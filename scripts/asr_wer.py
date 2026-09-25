#!/usr/bin/env python3
"""Summarize ASREngineBenchTests output: per-engine latency percentiles and
word error rate against voice-tests/clips_ref.json ("verbatim", normalized:
lowercase, punctuation stripped). Usage: asr_wer.py docs/bench/asr_engines.txt"""
import json, os, re, statistics, sys, collections

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
clips = json.load(open(os.path.join(ROOT, "voice-tests", "clips_ref.json")))
ref = {c["id"]: c["verbatim"] for c in clips}
# Either rendering of a number/currency is right ("$3,162" and "three thousand
# one hundred sixty two" are the same words spoken): score against the
# verbatim AND the formatted clean reference, keep the better per clip.
ref_clean = {c["id"]: c["clean"] for c in clips}

def norm(s):
    s = s.lower().replace("’", "'")
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    return s.split()

def wer(r, h):
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev = cur
    return d[len(h)], len(r)

rows = collections.defaultdict(list)
loads = {}
for line in open(sys.argv[1]):
    if not line.startswith("AE|") or "Test Case" in line: continue
    p = line.rstrip("\n").split("|")
    if p[1] == "env": continue
    if p[1] == "load": loads[p[2]] = int(p[3]); continue
    rows[p[1]].append((p[2], int(p[3]), int(p[4]), "|".join(p[5:])))

def best(clip, text):
    a = wer(norm(ref[clip]), norm(text)); b = wer(norm(ref_clean[clip]), norm(text))
    return a if a[0] / max(a[1], 1) <= b[0] / max(b[1], 1) else b

def pct(v, q):
    v = sorted(v); k = (len(v) - 1) * q; f = int(k); c = min(f + 1, len(v) - 1)
    return v[f] + (v[c] - v[f]) * (k - f)

print(f"{'engine':9} {'n':>3} {'p50 ms':>7} {'p95 ms':>7} {'max':>6} {'WER':>6} {'errs/words':>11} {'load ms':>8}")
for eng, items in rows.items():
    ms = [m for _, _, m, _ in items]
    errs = words = 0
    seen = set()
    for clip, run, _, text in items:
        if run != 1: continue
        e, w = best(clip, text); errs += e; words += w
    print(f"{eng:9} {len(ms):>3} {pct(ms,.5):>7.0f} {pct(ms,.95):>7.0f} {max(ms):>6} {100*errs/words:>5.1f}% {errs:>4}/{words:<6} {loads.get(eng,'-'):>8}")
print()
for eng, items in rows.items():
    print(f"## {eng}")
    for clip, run, _, text in items:
        if run != 1: continue
        e, w = best(clip, text)
        if e: print(f"  clip{clip} ({e}/{w}): {text}")
