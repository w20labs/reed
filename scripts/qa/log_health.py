#!/usr/bin/env python3
"""Tripwire: one line must not dominate a Reed log.

Review 2026-09-04: a device-inventory line logged at UI-tick rate was 89%
of reed.log on a fresh install. Lines are reduced to a SHAPE — category,
level and the message's leading label (the text before its first ': ' or
' — ' payload), digits folded — so one call site is one shape whatever its
numbers, quoted text or device names say. Below the minimum sample the
verdict is "too small", never a pass: a short log proves nothing.

    scripts/qa/log_health.py <log>                 # exit 0 healthy, 1 dominated, 2 no verdict
    scripts/qa/log_health.py --self-test           # the normaliser's own contract

The QA server calls `verdict()` after every unit row (`qa_server.py`).
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

DEFAULT_MAX_SHARE = 0.4
DEFAULT_MIN_LINES = 500

LINE = re.compile(r"^(?:\S+Z )?(\[[^\]]+\]) (\w+): (.*)$")
NUMBER = re.compile(r"\d+(\.\d+)?")
QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"")


def shape(line: str) -> str:
    """'2026-…Z [audio] INFO: availableDevices: 4 candidate id(s) -> 3 after
    filtering: fifine Microphone' -> '[audio] INFO: availableDevices'.
    A message with no payload separator keeps its text, digits folded."""
    m = LINE.match(line.strip())
    if not m:
        return NUMBER.sub("#", line.strip())
    category, level, message = m.groups()
    label = re.split(r": | — ", message, maxsplit=1)[0]
    label = QUOTED.sub("'…'", label)  # device names ride inside quotes
    return f"{category} {level}: {NUMBER.sub('#', label)}"


def verdict(lines: list[str], max_share: float = DEFAULT_MAX_SHARE,
            min_lines: int = DEFAULT_MIN_LINES) -> tuple[int, str]:
    """(0 healthy | 1 dominated | 2 no verdict, human line)."""
    lines = [ln for ln in lines if ln.strip()]
    if len(lines) < min_lines:
        return 2, f"too small: {len(lines)} lines (< {min_lines}); no verdict"
    counts = Counter(shape(ln) for ln in lines)
    top, n = counts.most_common(1)[0]
    share = n / len(lines)
    if share > max_share:
        return 1, f"dominated: {share:.1%} of {len(lines)} lines are one shape: {top}"
    return 0, f"healthy: top shape is {share:.1%} of {len(lines)} lines"


def verdict_for(path: Path, **kw) -> tuple[int, str]:
    try:
        return verdict(path.read_text(errors="replace").splitlines(), **kw)
    except OSError as exc:
        return 2, f"unreadable: {exc}"


def self_test() -> int:
    stamp = "2026-09-04T19:20:17Z "
    a = stamp + "[audio] INFO: availableDevices: 4 candidate id(s) -> 3 after filtering: Aram’s iPhone (2) Microphone, fifine Microphone"
    b = stamp + "[audio] INFO: availableDevices: 2 candidate id(s) -> 1 after filtering: OBSBOT Meet SE Microphone"
    c = stamp + "[audio] INFO: device(154 'fifine Microphone'): hasInputStreams=false isAlive=true"
    d = stamp + "[audio] INFO: device(99 'Studio Display'): hasInputStreams=false isAlive=false"
    e = stamp + "[parakeet] INFO: parakeet v3 ready"
    f = stamp + "[timings] NOTICE: total 1.8s · denoise 0.1s · asr 0.3s·parakeet"
    checks = [
        (shape(a) == shape(b), "device names and counts must not split one call site"),
        (shape(a) == "[audio] INFO: availableDevices", f"shape was {shape(a)!r}"),
        (shape(c) == shape(d), "per-device rejections are one shape"),
        (shape(c) == "[audio] INFO: device(# '…')", f"rejection shape was {shape(c)!r}"),
        (shape(e) != shape(a), "different call sites stay distinct"),
        (shape(f) == "[timings] NOTICE: total #s · denoise #s · asr #s·parakeet", f"no-payload line folds digits: {shape(f)!r}"),
        (verdict([a] * 450 + [e] * 50)[0] == 1, "89% one shape is dominated"),
        (verdict([a, b] * 100 + [c] * 100 + [e] * 100 + [f] * 100)[0] == 0, "40% is healthy (not above the ceiling)"),
        (verdict([a, b] * 101 + [c] * 100 + [e] * 100 + [f] * 98)[0] == 1, "just above the ceiling is dominated"),
        (verdict([a] * 10)[0] == 2, "below the minimum sample there is no verdict"),
        (verdict([a] * 499)[0] == 2, "one below the minimum is still no verdict"),
    ]
    failed = [msg for ok, msg in checks if not ok]
    for msg in failed:
        print(f"self-test FAILED: {msg}")
    print("self-test passed" if not failed else f"self-test: {len(failed)} failure(s)")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?", type=Path)
    ap.add_argument("--max-share", type=float, default=DEFAULT_MAX_SHARE)
    ap.add_argument("--min-lines", type=int, default=DEFAULT_MIN_LINES)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.log is None:
        ap.error("a log path or --self-test is required")
    code, message = verdict_for(args.log, max_share=args.max_share, min_lines=args.min_lines)
    print(message)
    return code


if __name__ == "__main__":
    sys.exit(main())
