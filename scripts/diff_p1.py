#!/usr/bin/env python3
"""A/B for the Phase 1 bench: latency deltas per stage AND a quality diff of
the composite cleanup output between two runs (e.g. a flag off vs on).

    python3 scripts/diff_p1.py docs/bench/p1_run2_off.txt docs/bench/p1_run2_on.txt

Quality is judged three ways, because none alone is enough:
  1. acceptance rate of individual model calls (the gate's verdict),
  2. how many clips produced DIFFERENT cleaned text between A and B,
  3. the texts themselves, side by side, for a human read.
"""
import sys
from collections import defaultdict

if len(sys.argv) != 3:
    sys.exit(__doc__)


def load(path):
    st = defaultdict(list); per = defaultdict(dict); ai = []; texts = defaultdict(set); chunks = {}; env = None
    for line in open(path):
        if not line.startswith("P1|"):
            continue
        if "Test Case" in line:  # xctest chatter interleaved into a buffered line: unusable
            continue
        p = line.rstrip("\n").split("|"); k = p[1]
        if k == "env":
            env = "|".join(p[2:])
        elif k in ("denoise", "asr", "vocab", "split", "cleanup", "e2e"):
            v = int(p[4]); st[k].append(v); per[(p[2], p[3])][k] = v
            if k == "split":
                chunks[p[3]] = int(p[5])
            if k == "cleanup" and len(p) > 7:
                texts[p[3]].add(p[7])
        elif k == "ai":
            ai.append((p[3], int(p[5]), p[9] == "true"))
    return dict(st=st, per=per, ai=ai, texts=texts, chunks=chunks, env=env)


def pct(xs, q):
    if not xs:
        return float("nan")
    xs = sorted(xs); k = (len(xs) - 1) * q; lo = int(k); hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


A, B = load(sys.argv[1]), load(sys.argv[2])
print(f"A: {sys.argv[1]}  [{A['env']}]")
print(f"B: {sys.argv[2]}  [{B['env']}]")
print()
print(f"{'stage':<12}{'A p50':>8}{'B p50':>8}{'Δ':>7}   {'A p95':>8}{'B p95':>8}{'Δ':>7}")
for k in ("asr", "cleanup", "e2e"):
    a, b = A["st"][k], B["st"][k]
    d50 = pct(b, .5) - pct(a, .5); d95 = pct(b, .95) - pct(a, .95)
    print(f"{k:<12}{pct(a, .5):8.0f}{pct(b, .5):8.0f}{d50:+7.0f}   {pct(a, .95):8.0f}{pct(b, .95):8.0f}{d95:+7.0f}")
print()
ca = sum(1 for _ in A["ai"]); cb = sum(1 for _ in B["ai"])
print(f"model calls: A {ca} → B {cb}  ({cb - ca:+d})   accepted: A {100 * sum(1 for x in A['ai'] if x[2]) / max(1, ca):.0f}% → B {100 * sum(1 for x in B['ai'] if x[2]) / max(1, cb):.0f}%")
print(f"chunks per clip: " + " ".join(f"{c}:{A['chunks'].get(c, '?')}→{B['chunks'].get(c, '?')}" for c in sorted(set(A["chunks"]) | set(B["chunks"]))))
print()
print("per-clip cleanup p50 (ms):")
for c in sorted(A["chunks"]):
    a = [v["cleanup"] for (r, cc), v in A["per"].items() if cc == c and "cleanup" in v]
    b = [v["cleanup"] for (r, cc), v in B["per"].items() if cc == c and "cleanup" in v]
    print(f"  clip {c}: {pct(a, .5):5.0f} → {pct(b, .5):5.0f}  ({pct(b, .5) - pct(a, .5):+5.0f})")
print()
same = diff = 0
for c in sorted(set(A["texts"]) | set(B["texts"])):
    ta, tb = A["texts"].get(c, set()), B["texts"].get(c, set())
    if ta == tb:
        same += 1
        continue
    diff += 1
    print(f"clip {c} — output differs (A has {len(ta)} variant(s), B has {len(tb)})")
    for t in sorted(ta):
        print(f"   A: {t}")
    for t in sorted(tb):
        print(f"   B: {t}")
print(f"\ncleaned text identical on {same} clips, differs on {diff}")
