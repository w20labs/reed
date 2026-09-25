#!/usr/bin/env python3
"""Summarize the long-input A/B (LongInputBenchTests LI| lines): per arm,
median ASR / cleanup / end-to-end, chunk count, and whether the cleaned
text is identical between arms.

    python3 scripts/summarize_long.py docs/bench/long_input_ab.txt
"""
import statistics as st
import sys
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else "docs/bench/long_input_ab.txt"
arms = defaultdict(list); texts = defaultdict(set); env = None
for line in open(path):
    if not line.startswith("LI|") or "Test Case" in line:
        continue
    p = line.rstrip("\n").split("|")
    if p[1] == "env":
        env = "|".join(p[2:]); continue
    arm, run, audio, asr, chunks, calls, cleanup, e2e, path_, reason = p[1], int(p[2]), float(p[3]), int(p[4]), int(p[5]), int(p[6]), int(p[7]), int(p[8]), p[9], p[10]
    text = "|".join(p[11:])
    arms[arm].append(dict(run=run, audio=audio, asr=asr, chunks=chunks, cleanup=cleanup, e2e=e2e, path=path_, reason=reason, text=text))
    texts[arm].add(text)

print(f"env: {env}")
audio = next(iter(arms.values()))[0]["audio"]
print(f"long input: {audio:.1f} s of audio, {len(arms.get('off', []))} runs per arm\n")
print(f"{'':<10}{'chunks':>8}{'ASR p50':>10}{'cleanup p50':>13}{'e2e p50':>10}{'e2e max':>10}   path")
for arm in ("off", "on"):
    r = arms[arm]
    if not r:
        continue
    print(f"{arm:<10}{st.median(x['chunks'] for x in r):>8.0f}{st.median(x['asr'] for x in r):>10.0f}{st.median(x['cleanup'] for x in r):>13.0f}{st.median(x['e2e'] for x in r):>10.0f}{max(x['e2e'] for x in r):>10}   {r[0]['path']} ({r[0]['reason']})")
if arms["off"] and arms["on"]:
    a, b = arms["off"], arms["on"]
    ca, cb = st.median(x["cleanup"] for x in a), st.median(x["cleanup"] for x in b)
    ea, eb = st.median(x["e2e"] for x in a), st.median(x["e2e"] for x in b)
    print(f"\ncleanup: {ca:.0f} → {cb:.0f} ms ({100 * (cb - ca) / ca:+.0f}%)   e2e: {ea:.0f} → {eb:.0f} ms ({100 * (eb - ea) / ea:+.0f}%)   calls: {st.median(x['chunks'] for x in a):.0f} → {st.median(x['chunks'] for x in b):.0f}")
    same = texts["off"] == texts["on"]
    print(f"cleaned text identical across arms: {same}  (off variants {len(texts['off'])}, on variants {len(texts['on'])})")
    if not same:
        for arm in ("off", "on"):
            for t in sorted(texts[arm]):
                print(f"  {arm}: {t}")
    else:
        print(f"  text: {next(iter(texts['on']))[:400]}")
