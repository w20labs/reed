#!/usr/bin/env python3
"""The cleanup bench over REVIEWED local copies (P16).

Separate measures, never one score:
  edit distance   word-level Levenshtein between the typed text and the human
                  reference, normalised by the reference's length
  seam accuracy   at every pause seam, whether the typed text and the reference
                  agree on "sentence end here or not"
  restart P/R     a phrase re-spoken right after itself in what was heard is a
                  restart candidate; true when the reference keeps it once;
                  collapsed when the typed text keeps it once
  harmful edits   a word typed that was never heard, or a negation the reference
                  keeps that the typed text lost — a hard zero
  latency         totalSeconds p50 / p95 / max

    scripts/qa/review_bench.py [--dir DIR] [--json]

Exit 0 healthy, 1 any harmful edit, 2 no reviewed copies.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import local_review  # noqa: E402

NEGATIONS = {"not", "never", "cannot", "no", "n't"}
SENTENCE_END = re.compile(r"[.!?]$")


def words(text: str) -> list[str]:
    return [w for w in re.sub(r"[^\w'\s-]", " ", text.lower().replace("’", "'")).split() if w]


def tokens_with_marks(text: str) -> list[tuple[str, bool]]:
    """(word, ends a sentence) for every word of `text`."""
    out = []
    for raw in text.split():
        w = words(raw)
        if not w:
            continue
        out.append((w[0], bool(SENTENCE_END.search(raw))))
    return out


def edit_distance(a: list[str], b: list[str]) -> int:
    prev = list(range(len(b) + 1))
    for i, wa in enumerate(a, 1):
        cur = [i]
        for j, wb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (wa != wb)))
        prev = cur
    return prev[-1]


def normalised_edit_distance(typed: str, reference: str) -> float:
    ref = words(reference)
    return edit_distance(words(typed), ref) / max(1, len(ref))


def seam_positions(record: dict) -> list[int]:
    """Word offsets (into the heard text) of every pause seam."""
    positions, offset = [], 0
    segments = sorted(record.get("segments", []), key=lambda s: s.get("index", 0))
    for i, seg in enumerate(segments):
        if i > 0 and segments[i - 1].get("boundary") == "pause":
            positions.append(offset)
        offset += len(words(seg.get("corrected") or seg.get("raw", "")))
    return positions


def sentence_end_before(heard_words: list[str], text: str, position: int) -> bool | None:
    """Does `text` end a sentence right before heard word `position`? Aligns
    the text's words to the heard words; None when the seam's neighbour
    was deleted and the question has no answer."""
    marked = tokens_with_marks(text)
    if position == 0 or not marked:
        return None
    sm = difflib.SequenceMatcher(a=heard_words, b=[w for w, _ in marked], autojunk=False)
    target = position - 1  # the heard word before the seam
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal" and i1 <= target < i2:
            return marked[j1 + (target - i1)][1]
    return None


def seam_agreement(record: dict, reference: str) -> tuple[int, int]:
    """(agreements, decidable seams) between typed and reference."""
    heard = words(" ".join((s.get("corrected") or s.get("raw", "")) for s in sorted(record.get("segments", []), key=lambda s: s.get("index", 0))))
    agree = total = 0
    for pos in seam_positions(record):
        typed = sentence_end_before(heard, record.get("finalText", ""), pos)
        ref = sentence_end_before(heard, reference, pos)
        if typed is None or ref is None:
            continue
        total += 1
        agree += typed == ref
    return agree, total


def restart_candidates(heard: list[str], max_len: int = 8) -> list[tuple[str, ...]]:
    """Phrases re-spoken right after themselves: 'my name is my name is'."""
    found = []
    i = 0
    while i < len(heard):
        hit = None
        for n in range(min(max_len, (len(heard) - i) // 2), 1, -1):
            if heard[i:i + n] == heard[i + n:i + 2 * n]:
                hit = tuple(heard[i:i + n])
                break
        if hit:
            found.append(hit)
            i += len(hit)
        else:
            i += 1
    return found


def count_adjacent(phrase: tuple[str, ...], text_words: list[str]) -> bool:
    """True when `phrase` appears twice in a row in `text_words`."""
    n = len(phrase)
    return any(tuple(text_words[i:i + n]) == phrase and tuple(text_words[i + n:i + 2 * n]) == phrase
               for i in range(len(text_words) - 2 * n + 1))


def restart_outcomes(record: dict, reference: str) -> tuple[int, int, int]:
    """(true positives, false positives, false negatives)."""
    heard = words(" ".join((s.get("corrected") or s.get("raw", "")) for s in sorted(record.get("segments", []), key=lambda s: s.get("index", 0))))
    typed, ref = words(record.get("finalText", "")), words(reference)
    tp = fp = fn = 0
    for phrase in restart_candidates(heard):
        true_restart = not count_adjacent(phrase, ref)
        collapsed = not count_adjacent(phrase, typed)
        if collapsed and true_restart:
            tp += 1
        elif collapsed and not true_restart:
            fp += 1
        elif not collapsed and true_restart:
            fn += 1
    return tp, fp, fn


def harmful_edits(record: dict, reference: str) -> list[str]:
    heard = set(words(" ".join((s.get("corrected") or s.get("raw", "")) for s in record.get("segments", []))))
    typed = words(record.get("finalText", ""))
    ref = words(reference)
    harm = [f"invented:{w}" for w in typed if w not in heard]
    lost = [w for w in ref if w in NEGATIONS]
    typed_neg = [w for w in typed if w in NEGATIONS]
    if len(typed_neg) < len(lost):
        harm.append(f"lost-negation:{len(lost) - len(typed_neg)}")
    return harm


def bench(records: list[dict]) -> dict:
    reviewed = [r for r in records if r.get("reference") and r.get("finalText") is not None]
    if not reviewed:
        return {"reviewed": 0}
    dists, agree, seams, tp, fp, fn, harm, latencies = [], 0, 0, 0, 0, 0, [], []
    for r in reviewed:
        ref = r["reference"]["text"]
        dists.append(normalised_edit_distance(r["finalText"], ref))
        a, t = seam_agreement(r, ref)
        agree += a
        seams += t
        x, y, z = restart_outcomes(r, ref)
        tp += x
        fp += y
        fn += z
        harm.extend(f"{r.get('id', '?')}: {h}" for h in harmful_edits(r, ref))
        total = (r.get("timings") or {}).get("totalSeconds")
        if isinstance(total, (int, float)):
            latencies.append(float(total))
    latencies.sort()
    return {
        "reviewed": len(reviewed),
        "editDistance": {"mean": statistics.fmean(dists), "max": max(dists)},
        "seams": {"agree": agree, "total": seams, "accuracy": (agree / seams) if seams else None},
        "restarts": {"tp": tp, "fp": fp, "fn": fn,
                     "precision": tp / (tp + fp) if tp + fp else None,
                     "recall": tp / (tp + fn) if tp + fn else None},
        "harmful": harm,
        "latency": {"p50": _pct(latencies, 50), "p95": _pct(latencies, 95), "max": latencies[-1] if latencies else None},
    }


def _pct(sorted_values: list[float], q: int) -> float | None:
    if not sorted_values:
        return None
    k = max(0, min(len(sorted_values) - 1, round(q / 100 * (len(sorted_values) - 1))))
    return sorted_values[k]


def load_all(dir_: Path) -> list[dict]:
    out = []
    for row in local_review.listing(dir_):
        if row.get("unreadable"):
            continue
        rec = local_review.load(row["id"], dir_)
        rec["id"] = row["id"]
        out.append(rec)
    return out


def render(result: dict) -> str:
    if not result.get("reviewed"):
        return "no reviewed copies — accept or edit references on the QA page first"
    seams, rs, lat = result["seams"], result["restarts"], result["latency"]
    fmt = lambda v, f="{:.2f}": "n/a" if v is None else f.format(v)  # noqa: E731
    lines = [
        f"reviewed copies   {result['reviewed']}",
        f"edit distance     mean {result['editDistance']['mean']:.3f} · max {result['editDistance']['max']:.3f}  (words changed per reference word)",
        f"seam accuracy     {fmt(seams['accuracy'])}  ({seams['agree']} of {seams['total']} pause seams agree with the reference)",
        f"restarts          precision {fmt(rs['precision'])} · recall {fmt(rs['recall'])}  (tp {rs['tp']} fp {rs['fp']} fn {rs['fn']})",
        f"harmful edits     {len(result['harmful'])}  (hard zero)" + ("".join("\n    " + h for h in result["harmful"]) if result["harmful"] else ""),
        f"latency           p50 {fmt(lat['p50'], '{:.1f}s')} · p95 {fmt(lat['p95'], '{:.1f}s')} · max {fmt(lat['max'], '{:.1f}s')}",
    ]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", type=Path, default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    result = bench(load_all(args.dir or local_review.directory()))
    print(json.dumps(result, indent=2) if args.json else render(result))
    if not result.get("reviewed"):
        return 2
    return 1 if result["harmful"] else 0


if __name__ == "__main__":
    sys.exit(main())
