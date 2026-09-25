#!/usr/bin/env python3
"""Phase 1 aggregator: per-stage p50/p95/p99 from P1| lines, the LLM-stage
share of end-to-end, and the spec's gate verdict.

    swift test ... | tee docs/bench/p1_run1.txt
    python3 scripts/analyze_p1.py docs/bench/p1_run1.txt
"""
import subprocess, sys
from collections import defaultdict

files = sys.argv[1:] or ["p1_run1.txt"]
stage = defaultdict(list)      # stage -> [ms]
ai_rows = []                   # (ms, in_chars, out_chars, repair, accepted)
chunks_per_clip = []
mem = []
thermals = defaultdict(int)
per_sample = defaultdict(dict) # (run, clip) -> {stage: ms}
env = load = None

for f in files:
    for line in open(f):
        if not line.startswith("P1|"):
            continue
        if "Test Case" in line:  # xctest chatter interleaved into a buffered line: unusable
            continue
        p = line.rstrip("\n").split("|")
        kind = p[1]
        if kind == "env":
            env = p[2:]
        elif kind == "load":
            load = int(p[2])
        elif kind in ("denoise", "asr", "vocab", "split", "cleanup", "e2e"):
            ms = int(p[4])
            stage[kind].append(ms)
            per_sample[(p[2], p[3])][kind] = ms
            if kind == "split":
                chunks_per_clip.append(int(p[5]))
        elif kind == "ai":
            ai_rows.append((int(p[5]), int(p[6]), int(p[7]), p[8] == "true", p[9] == "true"))
            stage["ai_per_chunk"].append(int(p[5]))
        elif kind == "mem":
            mem.append(int(p[4])); thermals[p[5]] += 1


def pct(xs, q):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def row(name, xs):
    return f"{name:<14} n={len(xs):<4} p50={pct(xs, .5):7.0f}  p95={pct(xs, .95):7.0f}  p99={pct(xs, .99):7.0f}  max={max(xs) if xs else 0:6d}"


chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
print(f"Phase 1 — on-device latency distribution (ms)   macOS {env[0] if env else '?'} · {chip}")
print(f"warm speech-model load: {load} ms · thermal states seen: {dict(thermals)} · RSS MB p50/max: {pct(mem, .5):.0f}/{max(mem) if mem else 0}")
print()
for name in ("denoise", "asr", "vocab", "split", "ai_per_chunk", "cleanup", "e2e"):
    print(row(name, stage[name]))
print()

# LLM-stage share of end-to-end, per sample (not ratio of percentiles — the
# spec wants where the latency GOES, so look at the share distribution).
shares = [s["cleanup"] / s["e2e"] for s in per_sample.values() if s.get("e2e") and s.get("cleanup") is not None]
asr_shares = [s["asr"] / s["e2e"] for s in per_sample.values() if s.get("e2e") and s.get("asr") is not None]
print(f"cleanup share of e2e:  p50={pct(shares, .5):.0%}  p95={pct(shares, .95):.0%}   (ratio of p95s: {pct(stage['cleanup'], .95) / pct(stage['e2e'], .95):.0%})")
print(f"ASR share of e2e:      p50={pct(asr_shares, .5):.0%}  p95={pct(asr_shares, .95):.0%}")
if chunks_per_clip:
    print(f"chunks per clip: mean {sum(chunks_per_clip) / len(chunks_per_clip):.1f}, max {max(chunks_per_clip)}")
if ai_rows:
    acc = sum(1 for r in ai_rows if r[4]) / len(ai_rows)
    rep = sum(1 for r in ai_rows if r[3]) / len(ai_rows)
    ms_per_in_char = sum(r[0] for r in ai_rows) / max(1, sum(r[1] for r in ai_rows))
    print(f"ai chunks: {len(ai_rows)} · accepted {acc:.0%} · repair-prompt {rep:.0%} · {ms_per_in_char * 100:.0f} ms per 100 input chars")
print()
gate_share = pct(stage["cleanup"], .95) / pct(stage["e2e"], .95) if stage["e2e"] else float("nan")
if gate_share < 0.20:
    print(f"GATE: cleanup is {gate_share:.0%} of e2e p95 (< 20%) → STOP. ASR dominates; optimize ASR instead.")
else:
    print(f"GATE: cleanup is {gate_share:.0%} of e2e p95 (≥ 20%) → the cleanup stage is worth restructuring.")
