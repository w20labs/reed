#!/usr/bin/env python3
"""Reed QA page — local only, never shipped.

Serves an HTML page listing every bench and test suite with its last
status, summary and run time, and runs any of them on demand (one at a
time) via `swift test` with the Xcode toolchain. Results land in
docs/bench/qa/<id>.txt (gitignored). Start with scripts/qa/qa.sh.
"""
import shutil
import collections, html, json, os, pathlib, re, statistics, subprocess, sys, threading, time
import log_health  # scripts/qa/log_health.py, beside this file
import local_review  # the app's review copies (P16), read directly from disk
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "docs", "bench", "qa")
STATE = os.path.join(OUT, "state.json")
PORT = int(os.environ.get("REED_QA_PORT", "8797"))
ENV = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
SWIFT = ["xcrun", "--toolchain", "XcodeDefault", "swift"]

# ---------------------------------------------------------------- summaries

def pct(v, q):
    v = sorted(v); k = (len(v) - 1) * q; f = int(k); c = min(f + 1, len(v) - 1)
    return v[f] + (v[c] - v[f]) * (k - f)

def lines(path, prefix):
    try:
        return [l.rstrip("\n").split("|") for l in open(path, errors="replace")
                if l.startswith(prefix + "|") and "Test Case" not in l]
    except FileNotFoundError:
        return []

def exec_line(path):
    try:
        ex = [l for l in open(path, errors="replace") if "Executed" in l and "with" in l]
        return ex[-1].strip() if ex else None
    except FileNotFoundError:
        return None

def sum_unit(path):
    e = exec_line(path)
    if not e: return "fail", "no result"
    m = re.search(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", e)
    if not m: return "fail", e
    n, s, f = m.group(1), m.group(2) or "0", m.group(3)
    status, summary = ("ok" if f == "0" else "fail"), f"{n} tests · {s} skipped · {f} failures"
    # The log tripwire is part of the verdict, not a tile beside it (review
    # 2026-09-04, round 2): a dominated app log fails the row even when every
    # XCTest case passed. Too small is not a failure here — a filtered row
    # writes few lines — the metric tile says "no verdict".
    code, message = log_health_verdict(path)
    if code == 1: return "fail", f"{summary} · LOG DOMINATED: {message}"
    return status, summary

BASELINES_PATH = os.path.join(ROOT, "docs", "bench", "baselines.json")

# The shipped arms: each MUST have a committed line. A missing or malformed
# ceilings file, or a missing line for one of these, is a FAIL on the page
# (review 2026-09-01: it used to read "measured, not gated" — green). Only
# an experimental arm outside these sets may run ungated, and says so.
KNOWN_ARMS = {"p1": ("v3",), "asr": ("v3", "ctc110m")}

def baselines():
    """The ceilings dict, or a problem string when it cannot be trusted."""
    try:
        with open(BASELINES_PATH) as f: data = json.load(f)
    except FileNotFoundError: return None, "ceilings file missing (docs/bench/baselines.json)"
    except Exception as ex: return None, f"ceilings file malformed (docs/bench/baselines.json): {ex}"
    if not isinstance(data, dict): return None, "ceilings file malformed: expected an object"
    return data, None

def ceiling(path, known):
    """(value, problem) for a key path. A known arm's absent or non-numeric
    line is a problem; an experimental arm's absent line is (None, None)."""
    data, problem = baselines()
    if problem: return None, problem
    node = data
    for key in path:
        if not isinstance(node, dict): return None, f"ceilings file malformed at {'.'.join(path)}"
        if key not in node: return (None, f"no committed ceiling {'.'.join(path)} for a known arm") if known else (None, None)
        node = node[key]
    if isinstance(node, bool) or not isinstance(node, (int, float)): return None, f"ceiling {'.'.join(path)} is not a number"
    return float(node), None

def bench_env_str(path, key, default):
    """A bench's configured setting, read from its spec (by the log's bench
    id) so the expected matrix can never drift from the command that
    produced the log. Works for the current log and archived history files."""
    bid = os.path.basename(path).split("-")[0].removesuffix(".txt")
    spec = BY_ID.get(bid, (None, None, None, {"env": {}}))[3]
    return str(spec["env"].get(key, default))

def bench_env(path, key, default):
    try: return int(bench_env_str(path, key, default))
    except ValueError: return int(default)

def sum_p1(path):
    # P1|e2e|<run>|<clip>|<ms> lines, aggregated by the analyzer script.
    try:
        out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "analyze_p1.py"), path], capture_output=True, text=True, timeout=60).stdout
        m = re.search(r"e2e\s+n=\s*(\d+)\s+p50=\s*(\d+)\s+p95=\s*(\d+)", out)
        c = re.search(r"cleanup share of e2e:\s+p50=(\d+)%", out)
        eng = re.search(r"engine=(\w+)", open(path, errors="replace").read())
        if not m: return "fail", "no P1 lines"
        p95 = int(m.group(3))
        got = int(m.group(1))
        expected_n = bench_env(path, "REED_P1_RUNS", 10) * len(clip_list("p1"))
        # The arm is the engine the env line names; an engine with no
        # committed line (v2, ctc110m) is measured, not judged against v3's.
        arm = eng.group(1) if eng else "v3"
        limit, problem = ceiling(["p1", "e2e_p95_ms", arm], known=arm in KNOWN_ARMS["p1"])
        over = limit is not None and p95 > limit
        text = f"e2e p50 {m.group(2)} ms · p95 {m.group(3)} ms · cleanup {c.group(1) if c else '?'}% of the wait · n={m.group(1)} · engine {eng.group(1) if eng else '?'}"
        if over: text += f" · OVER CEILING {int(limit)} ms"
        if problem: text += " · NOT GATED: " + problem
        elif limit is None: text += f" · no committed ceiling for experimental arm {arm} — measured, not gated"
        if expected_n and got < expected_n:
            return "fail", text + f" · INCOMPLETE RUN (n={got}/{expected_n})"
        return ("fail" if (over or problem) else "ok"), text
    except Exception as ex:
        return "fail", str(ex)

def sum_overlap(path):
    rows = lines(path, "OV")
    ov = [int(r[4]) for r in rows if r[1] == "overlap"]
    sg = [int(r[3]) for r in rows if r[1] == "single"]
    if not ov: return "fail", "no OV lines"
    texts = {r[1]: "|".join(r[5:] if r[1] == "overlap" else r[4:]) for r in rows if r[1] in ("overlap", "single")}
    import difflib
    a = texts.get("single", "").split(); b = texts.get("overlap", "").split()
    diffs = sum(1 for op in difflib.SequenceMatcher(None, a, b).get_opcodes() if op[0] != "equal")
    text = f"after release {statistics.median(ov):.0f} ms (single-pass {statistics.median(sg):.0f} ms) · {diffs} text diffs vs single-pass"
    runs = bench_env(path, "REED_OVERLAP_RUNS", 2)
    if len(ov) < runs or len(sg) < runs:
        return "fail", text + f" · INCOMPLETE RUN (overlap {len(ov)}/{runs}, single {len(sg)}/{runs})"
    return ("ok" if diffs <= 12 else "warn"), text

def sum_seam(path):
    rows = lines(path, "SR")
    tally = next((r for r in rows if r[1] == "tally"), None)
    if tally is None: return "fail", "no SR tally line (incomplete run)"
    kv = dict(part.split("=", 1) for part in tally[2].split())
    def n(key): return int(kv.get(key, "-1"))   # a missing field is not a zero
    text = (f"{kv.get('copies')} reviewed copies · {kv.get('seams')} pause seams · corrected {kv.get('corrected')} · broken {kv.get('broken')}"
            f" · already right {kv.get('same_right')} · still wrong {kv.get('same_wrong')} · undecidable {kv.get('undecidable')}")
    unreviewed = n("unreviewed_with_seams")
    if unreviewed > 0: text += f" · {unreviewed} copies with seams await review"
    if n("no_recording") > 0: text += f" · {n('no_recording')} reviewed copies have no recording (older than 2026-09-06)"
    if min(n("copies"), n("seams"), n("corrected"), n("broken"), n("undecidable"), n("skipped"), n("failed")) < 0:
        return "fail", text + " · tally line incomplete"
    if n("skipped") + n("failed") > 0:
        return "fail", text + f" · INCOMPLETE RUN ({n('skipped')} reviewed copies not replayed, {n('failed')} failed a replay arm)"
    if n("broken") > 0: return "fail", text + " · the rules broke a seam"
    if n("seams") - n("undecidable") <= 0: return "warn", text + " · no seam decided yet: review a copy with a pause"
    return "ok", text

def sum_seam_reading(path):
    rows = lines(path, "SW")
    tally = next((r for r in rows if r[1] == "tally"), None)
    if tally is None: return "fail", "no SW tally line (incomplete run)"
    kv = dict(part.split("=", 1) for part in tally[2].split())
    def n(key): return int(kv.get(key, "-1"))   # a missing field is not a zero
    text = (f"{kv.get('copies')} copies with a pause seam · {kv.get('seams')} seams, {kv.get('located')} located · read {kv.get('read')}:"
            f" period {kv.get('period')} · comma {kv.get('comma')} · nothing {kv.get('nothing')} · undecided {kv.get('undecided')}"
            f" · would change {kv.get('changed')} · read p50 {kv.get('ms_p50')} ms, max {kv.get('ms_max')} ms")
    if min(n("copies"), n("seams"), n("located"), n("read"), n("changed"), n("words_changed"), n("scored"), n("corrected"), n("broken"),
           n("unreadable"), n("missing"), n("no_recording"), n("gapped"), n("unfaithful"), n("cued")) < 0:
        return "fail", text + " · tally line incomplete"
    if n("unreadable") + n("missing") > 0:
        return "fail", text + f" · INCOMPLETE RUN ({n('unreadable')} recordings unreadable, {n('missing')} named but missing)"
    if n("words_changed") > 0: return "fail", text + f" · a reading changed the words of {n('words_changed')} copies"
    for key, label in (("no_recording", "copies have no recording (older than 2026-09-06)"), ("gapped", "copies skipped: a segment index is missing"),
                       ("unfaithful", "older copies skipped: their rebuilt segments do not re-assemble to their own text"),
                       ("cued", "copies skipped: a correction cue crosses a pause (its text depends on a model call)"),
                       ("mismatch", "copies re-assemble differently from their own text")):
        if n(key) > 0: text += f" · {n(key)} {label}"
    if n("scored") == 0:
        return "warn", text + f" · nothing scored yet: {n('copies') - n('reviewed')} copies with a pause await review"
    text += f" · against {n('reviewed')} reviewed: corrected {n('corrected')} · broken {n('broken')} · already right {n('same_right')} · still wrong {n('same_wrong')}"
    if n("broken") > 0 and n("broken") >= n("corrected"): return "fail", text + " · breaks as many seams as it corrects"
    if n("broken") > 0: return "warn", text + " · corrects more than it breaks; read the broken seams"
    if n("corrected") == 0: return "warn", text + " · corrects nothing yet"
    return "ok", text

def sum_sweep(path):
    rows = lines(path, "SS")
    tally = next((r for r in rows if r[1] == "tally"), None)
    if tally is None: return "fail", "no SS tally line (incomplete run)"
    kv = dict(part.split("=", 1) for part in tally[2].split())
    def n(key):
        try: value = float(kv[key])
        except (KeyError, ValueError): return -1.0
        return value if value == value else -1.0   # nan is not a count
    derived = f"{n('collapses') * 1000 / n('offsets'):.1f}" if n("offsets") > 0 else "-"
    text = (f"{int(n('recordings'))} corpus tails · {int(n('collapses'))} collapsed of {int(n('offsets'))} start offsets ({derived} per 1000) on {int(n('affected'))} recordings"
            f" · synthetic {int(n('synthetic_collapses'))} of {int(n('synthetic_offsets'))} · whole recording p50 {int(n('whole_p50_ms'))} ms · slice p50 {int(n('slice_p50_ms'))} ms")
    counts = ("recordings", "offsets", "collapses", "affected", "synthetic_offsets", "synthetic_collapses", "step", "back", "synthetic_pairs", "synthetic_back")
    if any(n(k) < 0 for k in counts):   # missing, non-numeric or nan
        return "fail", text + " · tally line incomplete"
    # Coverage and controls, the same rules the bench asserts (review 2026-09-08): every planned
    # offset measured, exactly the planned synthetic offsets, and the synthetic pairs — which have
    # never collapsed — still do not. The rate is derived here from the validated counts, never read.
    if n("step") <= 0 or n("offsets") != n("recordings") * (n("back") // n("step")):
        return "fail", text + " · INCOMPLETE RUN: not every planned offset was measured"
    if n("synthetic_offsets") != n("synthetic_pairs") * (n("synthetic_back") // n("step")) or n("synthetic_offsets") <= 0:
        return "fail", text + " · INCOMPLETE RUN: the synthetic controls were not all measured"
    if n("synthetic_collapses") > 0:
        return "fail", text + " · the synthetic controls collapsed"
    if n("recordings") == 0: return "warn", text + " · no corpus tail to sweep: dictate with a pause first"
    per_mille = n("collapses") * 1000 / n("offsets")
    ceil, problem = ceiling(["asr", "slice_collapse_per_mille_max"], True)
    if problem: return "fail", text + " · " + problem
    if per_mille > ceil: return "fail", text + f" · {per_mille:.1f} per 1000 is over the {ceil:.0f} ceiling"
    return "ok", text

def sum_perclip(path):
    rows = lines(path, "OV")
    clips = [r for r in rows if r[1] == "clip"]
    if not clips: return "fail", "no clip lines"
    same = sum(1 for r in clips if r[6] == "true")
    ov = statistics.mean(int(r[4]) for r in clips); sg = statistics.mean(int(r[5]) for r in clips)
    text = f"{same}/{len(clips)} identical · overlapped {ov:.0f} ms vs single {sg:.0f} ms mean"
    expected = len(clip_list("overlap_perclip"))
    if expected and len(clips) < expected:
        return "fail", text + f" · INCOMPLETE RUN ({len(clips)}/{expected} clips)"
    return ("ok" if same == len(clips) else "warn"), text

def sum_idle(path):
    rows = lines(path, "ID")
    d = collections.defaultdict(list)
    for r in rows:
        if r[1] in ("natural", "tickled"): d[(r[1], int(r[2]))].append(int(r[5]))
    if not d: return "fail", "no ID lines"
    nat = statistics.median(d.get(("natural", 15), [0])); tick = statistics.median(d.get(("tickled", 15), [0]))
    text = f"cleanup after 15 s idle: natural {nat:.0f} ms · kept warm {tick:.0f} ms"
    arms = [a for a in bench_env_str(path, "REED_IDLE_ARMS", "natural,tickled").split(",") if a]
    runs = bench_env(path, "REED_IDLE_RUNS", 3)
    got = sum(len(v) for v in d.values()); expected = len(arms) * 4 * runs  # 4 idle lengths in the bench
    if got < expected:
        return "fail", text + f" · INCOMPLETE RUN ({got}/{expected} samples)"
    return ("ok" if tick and tick < 900 else "warn"), text

def sum_gate(path):
    t = [r for r in lines(path, "GT") if r[1] == "tally"]
    if not t: return "fail", "no tally"
    tally = dict(kv.split("=") for kv in t[0][2].split())
    rej = sum(int(v) for k, v in tally.items() if not k.startswith("accept"))
    # The committed ceiling, the same one the bench itself asserts (#308):
    # past it the row is red, not amber — the ceilings file says FAIL.
    limit, problem = ceiling(["gate", "max_refusals"], known=True)
    text = f"{tally.get('accept','0')} accepted, {tally.get('accept-unchanged','0')} unchanged, {rej} refused ({', '.join(f'{k} {v}' for k, v in tally.items() if not k.startswith('accept'))})"
    if problem: return "fail", text + " · NOT GATED: " + problem
    if rej > limit: return "fail", text + f" · OVER CEILING {int(limit)} refusals"
    return "ok", text

def sum_asr(path):
    try:
        out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "asr_wer.py"), path], capture_output=True, text=True, timeout=60, cwd=ROOT).stdout
        rows = [l for l in out.splitlines() if re.match(r"^(%s)\s" % "|".join(KNOWN_ARMS["asr"]), l)]
        parts, over, problems = [], [], []
        for l in rows:
            f = l.split()
            parts.append(f"{f[0]} {f[2]} ms / {f[5]}")
            try:
                wer = float(f[5].rstrip("%")); p50 = float(f[2])
                known = f[0] in KNOWN_ARMS["asr"]
                wmax, wp = ceiling(["asr", "wer_max_pct", f[0]], known); lmax, lp = ceiling(["asr", "p50_max_ms", f[0]], known)
                problems += [p for p in (wp, lp) if p and p not in problems]
                if wmax is not None and wer > wmax: over.append(f"{f[0]} WER {wer}% > {wmax}%")
                if lmax is not None and p50 > lmax: over.append(f"{f[0]} p50 {p50:.0f} ms > {lmax:.0f} ms")
            except (ValueError, IndexError): pass
        text = " · ".join(parts) or "no AE lines"
        if problems: text += " · NOT GATED: " + "; ".join(problems)
        missing = [e for e in KNOWN_ARMS["asr"] if not any(l.split()[0] == e for l in rows)]
        if missing: text += " · MISSING ARM: " + ", ".join(missing)
        # Every arm must carry the full matrix (clips × runs) before its
        # percentiles mean anything (review 2026-09-01).
        expected = bench_env(path, "REED_ASR_RUNS", 5) * len(clip_list("asr"))
        short = [f"{l.split()[0]} {l.split()[1]}/{expected}" for l in rows if expected and int(l.split()[1]) < expected]
        if short: text += " · INCOMPLETE ARM: " + ", ".join(short)
        if over: text += " · OVER CEILING: " + "; ".join(over)
        status = "fail" if (over or missing or short or problems or not rows) else "ok"
        return status, text
    except Exception as ex:
        return "fail", str(ex)

def nb_fields(r):
    """NB|id|engine|raw|vocab|clean|ref — clean is model output and may
    contain '|'; ref is always last, so re-join the middle."""
    return r[1], r[2], "|".join(r[5:-1]) if len(r) > 7 else r[5], r[-1]

def sum_itn(path):
    rows = lines(path, "NB")
    if not rows: return "fail", "no NB lines"
    correct, total = {}, {}
    for r in rows:
        if len(r) < 7: continue
        _, eng, clean, ref = nb_fields(r)
        total[eng] = total.get(eng, 0) + 1
        if clean.strip().lower().rstrip(".") == ref.strip().lower().rstrip("."):
            correct[eng] = correct.get(eng, 0) + 1
    # The bench drives off numbers_ref.json, so that is the case count — not
    # whatever .wav files happen to sit next to it.
    try: expected = len(json.load(open(os.path.join(ROOT, "voice-tests", "numbers", "numbers_ref.json"))))
    except Exception: expected = len(clip_list("itn")) or max(total.values(), default=0)
    def label(eng, name):
        if eng not in total: return f"{name} MISSING"
        note = f"/{expected}" if total[eng] != expected else ""
        return f"{name} {correct.get(eng, 0)}/{total[eng]}{note}"
    summary = label('v3', 'Parakeet')
    incomplete = [n for e, n in (("v3", "Parakeet"),) if total.get(e, 0) != expected]
    if incomplete:
        return "fail", summary + f" — incomplete matrix ({', '.join(incomplete)} short of {expected} cases)"
    status = "ok" if correct.get("v3", 0) == total["v3"] else "warn"
    return status, summary

def sum_case(path):
    t = [r for r in lines(path, "CB") if r[1] == "tally"]
    if not t: return "fail", "no CB lines"
    lost, total = t[0][2].split()[0].split("/")
    return ("ok" if int(lost) <= 1 else "warn"), f"{lost} of {total} proper nouns lost their capital"

def sum_review_corpus(path):
    t = [r for r in lines(path, "RC") if r[1] == "tally"]
    if not t: return "fail", "no RC lines — no reviewed copy with a recording, or the run crashed"
    tally = dict(kv.split("=") for kv in t[0][2].split())
    replayed, exact = int(tally.get("replayed", 0)), int(tally.get("exact", 0))
    missing, unusable, failed = int(tally.get("missing", 0)), int(tally.get("unusable", 0)), int(tally.get("failed", 0))
    if replayed == 0: return "fail", "nothing replayed — review some dictations first"
    if missing or unusable or failed:
        return "fail", f"INCOMPLETE — {missing} recording(s) missing, {unusable} unusable, {failed} failed · {replayed} replayed"
    return "ok", f"{replayed} replayed · {exact} exact · mean edit distance {tally.get('mean_ned', '?')}"

def sum_repair(path):
    t = [r for r in lines(path, "RB") if r[1] == "tally"]
    if not t: return "fail", "no RB lines"
    parts = t[0][2:]
    fixed = [p for p in parts if p.startswith("pipeline fixed")]
    n = int(fixed[0].split()[-1]) if fixed else 0
    return ("ok" if n >= 6 else "warn"), " · ".join(parts)

def sum_long(path):
    try:
        out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "summarize_long.py"), path], capture_output=True, text=True, timeout=60, cwd=ROOT).stdout
        m = re.search(r"e2e:\s*(\d+) → (\d+) ms \(([-+\d]+)%\)", out); ident = "identical" in out and "True" in out
        return ("ok" if m else "fail"), (f"e2e {m.group(1)} → {m.group(2)} ms ({m.group(3)}%) with coalesce · text identical: {ident}" if m else "no LI lines")
    except Exception as ex:
        return "fail", str(ex)

def sum_probe(path):
    e = exec_line(path)
    return sum_unit(path) if e else ("fail", "no result")

def swift_test(filter_, **env):
    return {"cmd": SWIFT + ["test", "--filter", filter_], "env": env}

# ---- unit-suite areas: the monolithic run split into meaningful sections ----
# Suites are discovered from the test files at startup, so new files appear
# automatically; anything unclassified lands in the App bucket, never dropped.
def unit_areas():
    import glob as _g
    names = set()
    for f in _g.glob(os.path.join(ROOT, "Tests", "ReedTests", "*.swift")):
        names.update(re.findall(r"class\s+(\w+)\s*:\s*XCTestCase", open(f, errors="replace").read()))
    names = sorted(n for n in names
                   # Gated benches are named *BenchTests; anything else is a
                   # unit suite (BenchScoringTests, BenchBaselinesTests are
                   # unit tests OF the bench tooling — review 2026-09-01).
                   if not n.endswith("BenchTests") and "Probe" not in n
                   and n not in ("PromptIterTests", "DenoiseABTests"))
    areas = [
        ("unit_text",  "Unit · Text pipeline", "Chunking, cleanup rules, the acceptance gate, stumble and correction detection, number formatting, vocabulary, injection safety — the words themselves — plus the bench scoring arithmetic (WER, percentiles, ceilings loader) the rows below are judged with.",
         ["Cleanup", "Chunker", "Stumble", "Correction", "Vocab", "Number", "Injector", "BenchScoring", "BenchBaselines"]),
        ("unit_audio", "Unit · Audio & recording", "Capture, segmentation, overlap sessions and assembly, denoising, metering, keep-warm, WAV headers, config-change recovery — the audio path.",
         ["Segmenter", "Overlap", "Audio", "WAV", "Denoise", "Meter", "KeepWarm", "Silence", "ConfigChange", "ModelPrep", "SpeechModelStore", "LongAudio", "CoordinatorInit"]),
        ("unit_auth",  "Unit · Network, privacy & gates", "The network guarantee and host allowlist, the no-telemetry guard and its cleanup, legacy-data purge, terms acceptance, Keychain shield, feature flags.",
         ["Terms", "GateURL", "Network", "KeyStore", "FeatureFlag", "Telemetry", "LegacyPaidData"]),
        ("unit_app",   "Unit · App, UI & input", "Onboarding flow, hotkeys and hold triggers, Bluetooth handling, error copy, logs, layout — everything the user touches.", None),
    ]
    buckets = {aid: [] for aid, *_ in areas}
    for n in names:
        for aid, _t, _d, keys in areas:
            if keys and any(k in n for k in keys):
                buckets[aid].append(n); break
        else:
            buckets["unit_app"].append(n)
    out = []
    for aid, title, desc, _k in areas:
        suites = buckets[aid]
        flt = "\\.(" + "|".join(suites) + ")/"
        out.append((aid, title, desc, suites, {"cmd": SWIFT + ["test", "--filter", flt], "env": {}}))
    return out

_UNIT_AREAS = unit_areas()


# What each bench actually does — shown when a row is expanded, so the page
# is not a black box (user request, 2026-08-30).
DESCRIPTIONS = {
    **{a[0]: (a[2] + " Together the four unit rows are exactly the fast CI suite; the detail below lists each suite by name with its test count, and any failing case is called out in full at the top.",
              f"{len(a[3])} suites · no audio, no models") for a in _UNIT_AREAS},
    "long_probe": ("Feeds the 10 corpus clips concatenated (86 s) to Parakeet in one call and asserts every sentence survives: 'auth module … GitHub' present, ends with '$20', no 'orthogon', no '. Spend' break at a cut; plus a 43 s half reaching 'Baker Street'.", "voice-tests/clips/clip01–10.wav concatenated · real Parakeet"),
    "gate": ("Runs 22 field stumbles + 10 corpus verbatims + 10 email dictations through the real cleanup model and prints every gate verdict with the rule that fired. Baseline: 10 refusals, all correct.", "hand corpus in GateBenchTests.swift · real Foundation Model"),
    "itn": ("16 synthesized clips of spoken amounts, dates, times, phone numbers, versions, ordinals — raw recognizer → vocabulary pass → cleanup, against a reference, per engine.", "voice-tests/numbers/*.wav (scripts/make_numbers.sh) · Parakeet"),
    "case": ("3 long run-ons with 24 known proper nouns through cleanup; counts nouns that lost their capital in resplit fragments. Baseline: 1 of 24.", "texts in CaseBenchTests.swift · real Foundation Model"),
    "repair": ("12 field stumbles each under the generic prompt, the repair prompt, and the full pipeline (trigger + gate + retry). Baseline: pipeline fixes 6/12.", "texts in RepairBenchTests.swift · real Foundation Model"),
    "review_corpus": ("Every reviewed local copy that kept its recording, replayed through the live pipeline at real-time pace — segmenter, Parakeet, cleanup, assembly — and scored against the human reference (word edit distance, exact matches). The end-to-end regression on the developer's own speech; informational until the first reviewed batch is committed as the baseline.", "~/Library/Application Support/Reed/Review · reviewed copies with audio · real models"),
    "seam": ("Seam verdicts A/B on the human-reviewed corpus: every reviewed copy with a recording and two or more segments replayed through the live pipeline with the seam rules off and on; each pause seam read in both texts and the reference (sentence end, clause, nothing) by aligning words to what was heard. Corrected, broken (a hard zero), already right, still wrong. Counts only; content never reaches the log.", "~/Library/Application Support/Reed/Review · reviewed copies with seams · real models"),
    "seam_reading": ("The seam experiment (2026-09-10): every local copy with a recording and a pause seam is re-assembled from the texts the app delivered per segment, with and without a reading of the audio across each seal (two seconds each side, where the app sealed), and each seam is read against the human reference when there is one. Reports verdicts, seams the reading would change, words preserved, latency per read; scores corrected / broken against reviewed copies. Informational until the reviewed pause copies exist; it ships only if it corrects more than it breaks.", "~/Library/Application Support/Reed/Review · copies with a pause · real Parakeet"),
    "asr_sweep": ("The recognizer's slice-start collapse (2026-09-08), held to its ceiling: every corpus tail's start swept over the 2.5 s before its seal in 40 ms steps through the production recognizer with the second reading on; collapsed slices per 1000 offsets, healthy whole-recording fingerprints, latency, and three synthetic pairs that never collapse. Counts only.", "~/Library/Application Support/Reed/Review · corpus tails · real Parakeet"),
    "asr": ("The 10 corpus clips × 5 runs through Parakeet v3 and ctc110m; latency percentiles + word error rate vs the reference (either number rendering accepted).", "voice-tests/clips + clips_ref.json · both Parakeet variants"),
    "p1": ("The full pipeline stage by stage — denoise, recognition, vocabulary, split, per-chunk cleanup — over 10 clips × 10 warm runs; percentiles per stage, gate acceptance, per-call model cost.", "voice-tests/clips · default engine (Parakeet)"),
    "long_input": ("83 s of audio (the corpus concatenated) single-pass, 5 runs with sentence-coalescing OFF then ON; e2e and cleanup medians, text identity.", "voice-tests/clips concatenated · default engine"),
    "overlap_corpus": ("Replays 86 s with natural pauses through the live segmenter at wall-clock pace — segments recognized and cleaned while 'speaking' — and measures the wait after release vs single-pass, with a word-level text diff.", "voice-tests/clips + 0.9 s pauses · real-time replay"),
    "overlap_runon": ("Same replay on a 43 s single sentence with no pauses — exercises the 20 s cap cuts, pre-roll and seam trims.", "voice-tests/long_runon.wav (scripts/make_runon.sh)"),
    "overlap_breaths": ("Same replay on the run-on with five 900 ms mid-sentence breaths — exercises pause seals that are not sentence ends and the fragment glue at assembly.", "voice-tests/long_breaths.wav"),
    "overlap_perclip": ("Each everyday clip alone through the segmenter with idle parity — proves short dictations are unchanged by overlap (text identical, equal time).", "voice-tests/clips, one at a time"),
    "idle": ("Recognition and cleanup timed after 0/3/8/15 s of idle, with and without the keep-warm loop — the cold-model penalty and its cure.", "clip03 · real models"),
}


BENCHES = [
    # id, title, group, spec, summarizer, ~minutes
    (_UNIT_AREAS[0][0], _UNIT_AREAS[0][1], "Unit tests", _UNIT_AREAS[0][4], sum_unit, 1),
    (_UNIT_AREAS[1][0], _UNIT_AREAS[1][1], "Unit tests", _UNIT_AREAS[1][4], sum_unit, 1),
    (_UNIT_AREAS[2][0], _UNIT_AREAS[2][1], "Unit tests", _UNIT_AREAS[2][4], sum_unit, 1),
    (_UNIT_AREAS[3][0], _UNIT_AREAS[3][1], "Unit tests", _UNIT_AREAS[3][4], sum_unit, 1),
    ("long_probe", "86 s take · every sentence kept", "Recognition", swift_test("LongAudioChunkerTests/testParakeetKeepsEverySentenceOfTheLongTake", REED_LONG_PROBE="1"), sum_probe, 1),
    ("gate",       "Gate verdicts",    "Cleanup quality", swift_test("GateBenchTests", REED_GATE_BENCH="1"), sum_gate, 2),
    ("itn",        "Numbers, dates, times",      "Cleanup quality", swift_test("ITNBenchTests", REED_ITN_BENCH="1"), sum_itn, 2),
    ("case",       "Proper nouns survive resplit",      "Cleanup quality", swift_test("CaseBenchTests", REED_CASE_BENCH="1"), sum_case, 2),
    ("repair",     "Field stumbles · repair", "Cleanup quality", swift_test("RepairBenchTests", REED_REPAIR_BENCH="1"), sum_repair, 3),
    ("review_corpus", "Review corpus · replayed", "Cleanup quality", swift_test("ReviewCorpusBenchTests", REED_REVIEW_BENCH="1"), sum_review_corpus, 4),
    ("seam",       "Seam verdicts · reviewed corpus", "Cleanup quality", swift_test("SeamRulesBenchTests", REED_SEAM_BENCH="1"), sum_seam, 3),
    ("seam_reading", "Seam reading · audio across the seal", "Cleanup quality", swift_test("SeamReadingBenchTests", REED_SEAM_READ_BENCH="1"), sum_seam_reading, 3),
    ("asr",        "Engines · latency + WER",          "Recognition", swift_test("ASREngineBenchTests", REED_ASR_BENCH="1"), sum_asr, 3),
    ("asr_sweep",  "Slice-start collapse · sweep",     "Recognition", swift_test("SliceStartSweepBenchTests", REED_SWEEP_BENCH="1"), sum_sweep, 6),
    ("p1",         "Phase 1 · everyday clips (Parakeet)", "Latency", swift_test("Phase1LatencyBenchTests", REED_P1_BENCH="1", REED_P1_RUNS="10"), sum_p1, 5),
    ("long_input", "Long input · coalesce A/B", "Latency", swift_test("LongInputBenchTests", REED_LONG_BENCH="1"), sum_long, 4),
    ("overlap_corpus", "16 sentences with pauses", "Overlap", swift_test("OverlapBenchTests/testOverlapAgainstSinglePass", REED_OVERLAP_BENCH="1"), sum_overlap, 4),
    ("overlap_runon",  "43 s run-on, no pauses",        "Overlap", swift_test("OverlapBenchTests/testOverlapAgainstSinglePass", REED_OVERLAP_BENCH="1", REED_OVERLAP_INPUT="voice-tests/long_runon.wav"), sum_overlap, 3),
    ("overlap_breaths","43 s with five breaths",         "Overlap", swift_test("OverlapBenchTests/testOverlapAgainstSinglePass", REED_OVERLAP_BENCH="1", REED_OVERLAP_INPUT="voice-tests/long_breaths.wav"), sum_overlap, 3),
    ("overlap_perclip","Everyday clips, one at a time",   "Overlap", swift_test("OverlapBenchTests/testEverydayClipsThroughTheSegmenter", REED_OVERLAP_PERCLIP="1"), sum_perclip, 4),
    ("idle",       "Idle penalty · kept warm", "Latency", swift_test("IdleBenchTests", REED_IDLE_BENCH="1", REED_IDLE_ARMS="natural,tickled"), sum_idle, 4),
]
BY_ID = {b[0]: b for b in BENCHES}

# Audio inputs per bench — shown in the detail view with an inline player.
CLIPS = {
    "p1": "clips", "asr": "clips", "overlap_perclip": "clips",
    "long_input": "clips", "long_probe": "clips", "overlap_corpus": "clips",
    "itn": "numbers",
    "overlap_runon": ["voice-tests/long_runon.wav"],
    "overlap_breaths": ["voice-tests/long_breaths.wav"],
    "idle": ["voice-tests/clips/clip03.wav"],
}

def clip_list(bid):
    import glob as _glob, wave
    spec = CLIPS.get(bid)
    if spec is None: return []
    if spec == "clips": paths = sorted(_glob.glob(os.path.join(ROOT, "voice-tests", "clips", "clip*.wav")))
    elif spec == "numbers": paths = sorted(_glob.glob(os.path.join(ROOT, "voice-tests", "numbers", "*.wav")))
    else: paths = [os.path.join(ROOT, rel) for rel in spec]
    out = []
    for fp in paths:
        rel = os.path.relpath(fp, ROOT)
        secs = None
        try:
            with wave.open(fp) as w: secs = round(w.getnframes() / w.getframerate(), 1)
        except Exception: pass
        out.append({"name": os.path.basename(fp), "url": "/audio?f=" + rel, "secs": secs})
    return out

def unit_suite_rows(path):
    try: txt = open(path, errors="replace").read()
    except FileNotFoundError: return []
    rows = []
    for m in re.finditer(r"Test Suite '([^']+)' (passed|failed) at [^\n]*\n\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", txt):
        name, verdict, n, sk, nf = m.groups()
        if name in ("All tests", "Selected tests") or name.endswith(".xctest"): continue
        rows.append({"name": name, "tests": int(n), "skipped": int(sk or 0), "failures": int(nf)})
    return sorted(rows, key=lambda r: r["name"])

def suite_cases(path, suite):
    try: txt = open(path, errors="replace").read()
    except FileNotFoundError: return []
    out = []
    for m in re.finditer(r"Test Case '-\[ReedTests\.%s (\w+)\]' (passed|failed|skipped)(?: \(([\d.]+) seconds\))?" % re.escape(suite), txt):
        name, status, secs = m.groups()
        out.append({"name": name, "status": status, "secs": secs or ""})
    dedup = {}
    for c in out: dedup[c["name"]] = c   # 'started' lines excluded by regex; keep last verdict
    return sorted(dedup.values(), key=lambda c: c["name"])

def case_inventory(bid, suite):
    """The test methods of `suite` that row `bid` WILL run (review
    2026-09-02, twice): read from the source — the class body AND every
    `extension Suite` body, in any test file, since XCTest discovers
    those too — and narrowed to the row's `--filter` when that names a
    single method (the long-take probe runs one case of a four-case suite)."""
    spec = BY_ID[bid][3] if bid in BY_ID else {"cmd": []}
    cmd = spec["cmd"]
    flt = cmd[cmd.index("--filter") + 1] if "--filter" in cmd and cmd.index("--filter") + 1 < len(cmd) else ""
    single = re.fullmatch(r"(\w+)/(\w+)", flt)
    if single: return [single.group(2)] if single.group(1) == suite else []
    import glob as _g
    names = set()
    decl = re.compile(r"^[ \t]*(?:(?:final|@\w+)\s+)*(?:class\s+%s\s*:|extension\s+%s\b)[^\n]*\{" % (re.escape(suite), re.escape(suite)), re.M)
    next_type = re.compile(r"^(?:(?:final|@\w+)\s+)*(?:class|struct|enum|extension|actor|protocol)\s+\w+", re.M)
    for f in _g.glob(os.path.join(ROOT, "Tests", "ReedTests", "*.swift")):
        txt = open(f, errors="replace").read()
        for m in decl.finditer(txt):
            rest = txt[m.end():]
            nxt = next_type.search(rest)
            body = rest[:nxt.start()] if nxt else rest
            names.update(re.findall(r"^\s*(?:@\w+(?:\([^\n]*\))?\s+)*func\s+(test\w*)\s*\(\s*\)", body, re.M))
    return sorted(names)

def suite_doc(suite):
    """The doc comment above the suite's class declaration in its test file."""
    import glob as _g
    for f in _g.glob(os.path.join(ROOT, "Tests", "ReedTests", "*.swift")):
        txt = open(f, errors="replace").read()
        m = re.search(r"((?:^[ \t]*///[^\n]*\n)+)(?:^[ \t]*@\w+(?:\([^\n]*\))?[ \t]*\n)*[ \t]*(?:final\s+)?class\s+%s\s*:" % re.escape(suite), txt, re.M)
        if m:
            lines = [re.sub(r"^[ \t]*///\s?", "", l) for l in m.group(1).splitlines()]
            return " ".join(l for l in lines if l.strip())
        if re.search(r"class\s+%s\s*:" % re.escape(suite), txt): return ""
    return ""

def progress_for(bid):
    """Live per-case state while a row runs (user request 2026-09-01: the
    marks clear on Run and come back one by one as suites and cases finish).
    Parses the growing `.running` log; falls back to the finished log."""
    running_path = os.path.join(OUT, f"{bid}.txt.running")
    live = os.path.isfile(running_path)
    path = running_path if live else os.path.join(OUT, f"{bid}.txt")
    # The inventory is what WILL run — discovered from the test files at
    # startup — not what the previous log happened to contain (review
    # 2026-09-02: removed suites stayed hollow forever, new ones appeared
    # only once they started, a fresh install had nothing to clear).
    inventory = next((sorted(a[3]) for a in _UNIT_AREAS if a[0] == bid), ["LongAudioChunkerTests"] if bid == "long_probe" else [])
    try: txt = open(path, errors="replace").read()
    except FileNotFoundError: return {"running": live, "inventory": inventory, "suites": [], "cases": {}, "lines": []}
    if bid.startswith("unit") or bid == "long_probe":
        suites, cases = {}, collections.defaultdict(dict)
        skip = lambda n: n in ("All tests", "Selected tests") or n.endswith(".xctest")
        for m in re.finditer(r"Test Suite '([^']+)' started", txt):
            if not skip(m.group(1)): suites.setdefault(m.group(1), {"name": m.group(1), "tests": 0, "failures": 0, "skipped": 0, "done": False})
        for m in re.finditer(r"Test Case '-\[ReedTests\.(\w+) (\w+)\]' (passed|failed|skipped)", txt):
            cases[m.group(1)][m.group(2)] = m.group(3)
        for m in re.finditer(r"Test Suite '([^']+)' (passed|failed) at [^\n]*\n\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", txt):
            if not skip(m.group(1)):
                suites[m.group(1)] = {"name": m.group(1), "tests": int(m.group(3)), "failures": int(m.group(5)), "skipped": int(m.group(4) or 0), "done": True}
        return {"running": live, "inventory": inventory, "suites": sorted(suites.values(), key=lambda s: s["name"]),
                "cases": {k: [{"name": a, "status": b} for a, b in sorted(v.items())] for k, v in cases.items()}, "lines": []}
    return {"running": live, "inventory": inventory, "suites": [], "cases": {}, "lines": detail_lines(bid, path)}

def detail_lines(bid, path):
    """The last run's per-case lines, humanized, capped."""
    try:
        if bid.startswith("unit"):
            txt = open(path, errors="replace").read()
            out, fails = [], []
            for m in re.finditer(r"Test Suite '([^']+)' (passed|failed) at [^\n]*\n\s*Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures?", txt):
                name, verdict, n, nf = m.groups()
                if name in ("All tests", "Selected tests") or name.endswith(".xctest"):
                    continue
                mark = "✓" if verdict == "passed" else "✗"
                out.append(f"{mark} {name:<46} {n:>3} tests" + (f" · {nf} FAILED" if nf != "0" else ""))
            for m in re.finditer(r"Test Case '-\[ReedTests\.([^\]]+)\]' failed", txt):
                fails.append(f"  ✗ FAILED: {m.group(1)}")
            return (fails + sorted(out))[:140]
        if bid == "gate":
            out = [f"{r[2]:20} {r[4][:150]}" for r in lines(path, "GT")
                   if len(r) > 4 and r[1] != "tally" and not r[2].startswith("accept") and r[2] != "unchanged"]
            t = [r for r in lines(path, "GT") if r[1] == "tally"]
            return (["refused (rule · input):"] + out + ["", t[0][2] if t else ""])[:24]
        if bid == "itn":
            rows = lines(path, "NB")
            out = []
            for r in rows:
                if len(r) < 7: continue
                rid, eng_key, clean, ref = nb_fields(r)
                ok = "✓" if clean.strip().lower().rstrip(".") == ref.strip().lower().rstrip(".") else "✗"
                eng = "parakeet" if eng_key == "v3" else eng_key
                out.append(f"{ok} {rid} {eng:8} {clean[:110]}")
            return out[:36]
        if bid == "case":
            return [f"text {r[1]}: lost {r[2]}  {('(' + r[3] + ')') if r[3] else ''}" for r in lines(path, "CB") if r[1] != "tally"][:8]
        if bid == "repair":
            return [f"{r[1]:2} hint={r[2]:14} pipeline={r[7]:9} {r[8][:100]}" for r in lines(path, "RB") if r[1] != "tally"][:14]
        if bid == "asr":
            out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "asr_wer.py"), path], capture_output=True, text=True, timeout=60, cwd=ROOT).stdout
            return out.splitlines()[:30]
        if bid == "p1":
            out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "analyze_p1.py"), path], capture_output=True, text=True, timeout=60).stdout
            return [l for l in out.splitlines() if l.strip()][:20]
        if bid == "long_input":
            out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "summarize_long.py"), path], capture_output=True, text=True, timeout=60, cwd=ROOT).stdout
            return [l for l in out.splitlines() if l.strip()][:14]
        if bid.startswith("overlap"):
            rows = lines(path, "OV")
            out = []
            for r in rows:
                if r[1] == "overlap": out.append(f"overlap run {r[2]}: {r[3]} segments · {r[4]} ms after release")
                elif r[1] == "single": out.append(f"single  run {r[2]}: {r[3]} ms · {r[4][:110]}")
                elif r[1] == "clip": out.append(f"clip {r[2]}: overlapped {r[4]} ms · single {r[5]} ms · identical {r[6]}")
            return out[:24]
        if bid == "idle":
            return [f"{r[1]:8} idle {r[2]:>2} s · run {r[3]} · asr {r[4]} ms · cleanup {r[5]} ms" for r in lines(path, "ID") if r[1] != "env"][:26]
        if bid == "long_probe":
            return [l[3:].strip()[:160] for l in open(path, errors="replace") if l.startswith("LP|")][:6]
    except FileNotFoundError:
        return ["(no run yet)"]
    except Exception as ex:
        return [f"(detail error: {ex})"]
    return []

# ---------------------------------------------------------------- metrics
# Structured numbers per bench (design A, 2026-09-01): the first metric is
# the row's headline in the sidebar; each one may carry a ceiling and a
# 0..1 share so the page draws a bar with a tick at the committed line.

def _m(label, value, unit="", ceiling=None, share=None, status="ok", note="", headline=None):
    return {"label": label, "value": value, "unit": unit, "ceiling": ceiling, "share": share,
            "status": status, "note": note, "headline": headline}

def _vs_ceiling(label, value, unit, path, known, fmt="{:.0f}"):
    """A max-ceiling metric: share = value/ceiling, red past it, and the
    page's fail-closed rule for a known arm with no line."""
    limit, problem = ceiling(path, known)
    if problem: return _m(label, fmt.format(value), unit, status="bad", note="NOT GATED: " + problem)
    if limit is None: return _m(label, fmt.format(value), unit, note="no committed ceiling — measured, not gated")
    over = value > limit
    head = 1 - value / limit if limit else 0
    note = f"ceiling {fmt.format(limit)} {unit} · " + (f"{fmt.format(value - limit)} {unit} OVER" if over else f"{int(round(head * 100))}% headroom")
    return _m(label, fmt.format(value), unit, ceiling=limit, share=min(value / limit, 1.0) if limit else None,
              status="bad" if over else ("warn" if head < 0.1 else "ok"), note=note)

# The app's own log as written by the test process (FileLog), PER RUN: the
# runner hands each row's process its own file through REED_TEST_LOG_FILE and
# keeps it beside the row's log, so the tripwire judges the lines that run
# wrote — not a shared 72-hour file where an old flood fails a clean row and
# diverse history dilutes a new one (review 2026-09-04, round 3). Startup
# reconciliation re-judges the same sibling.
APP_LOG_ENV = "REED_TEST_LOG_FILE"
# One full suite run writes ~120 lines (measured 2026-09-04); a tick-rate flood
# writes thousands. Half a run is enough sample for this log; CI uses the same.
TESTS_LOG_MIN_LINES = 60

def app_log_path(path):
    """The app log that belongs to the run whose stdout is at `path`."""
    return path + ".app.log"

def run_env(spec, path):
    """The environment for a row's process: the row's own env plus the
    app-log redirect pointing at the RUNNING file, promoted with the run."""
    env = dict(ENV, **spec["env"])
    env[APP_LOG_ENV] = app_log_path(path + ".running")
    return env

def prepare_run(path):
    """Clear a previous interrupted attempt's files; returns the running stdout path."""
    tmp_path = path + ".running"
    for stale in (tmp_path, app_log_path(tmp_path)):
        try: os.remove(stale)
        except FileNotFoundError: pass
    return tmp_path

def promote_run(tmp_path, path):
    """A finished run replaces the last good one — stdout and app log together.
    An interrupted run never reaches here, so it never clobbers either."""
    os.replace(tmp_path, path)
    try: os.replace(app_log_path(tmp_path), app_log_path(path))
    except FileNotFoundError:
        # The process wrote no app log at all (a bench arm that never touches
        # FileLog); leave no stale sibling behind to be judged.
        try: os.remove(app_log_path(path))
        except FileNotFoundError: pass

def remove_archived(hist_path):
    """Drop an archived run — its stdout and its app-log sibling together."""
    for victim in (app_log_path(hist_path), hist_path):
        try: os.remove(victim)
        except FileNotFoundError: pass

def log_health_verdict(path):
    return log_health.verdict_for(pathlib.Path(app_log_path(path)), min_lines=TESTS_LOG_MIN_LINES)

def log_health_metric(path):
    code, message = log_health_verdict(path)
    status = {0: "ok", 1: "bad", 2: "warn"}[code]
    return _m("log health", {0: "healthy", 1: "DOMINATED", 2: "no verdict"}[code], status=status, note=message)

def metrics_for(bid, path):
    try: return _metrics(bid, path)
    except Exception as ex: return [_m("metrics", "?", status="warn", note=f"could not compute: {ex}", headline="?")]

def _metrics(bid, path):
    if not os.path.isfile(path): return []
    if bid.startswith("unit") or bid == "long_probe":
        m = re.search(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", exec_line(path) or "")
        if not m: return [_m("result", "none", status="bad", note="no XCTest completion footer in the log", headline="no result")]
        n, s, f = int(m.group(1)), int(m.group(2) or 0), int(m.group(3))
        return [_m("tests", n, headline=f"{n}" + (f" · {s} skip" if s else "")),
                _m("failures", f, status="bad" if f else "ok", note="every case must pass"),
                _m("skipped", s, note="gated or environment-dependent cases"),
                log_health_metric(path)]
    if bid == "p1":
        out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "analyze_p1.py"), path], capture_output=True, text=True, timeout=60).stdout
        m = re.search(r"e2e\s+n=\s*(\d+)\s+p50=\s*(\d+)\s+p95=\s*(\d+)", out)
        c = re.search(r"cleanup share of e2e:\s+p50=(\d+)%", out)
        eng = re.search(r"engine=(\w+)", open(path, errors="replace").read())
        if not m: return [_m("e2e", "none", status="bad", note="no P1 lines", headline="no result")]
        got, p50, p95 = int(m.group(1)), int(m.group(2)), int(m.group(3))
        arm = eng.group(1) if eng else "v3"
        expected = bench_env(path, "REED_P1_RUNS", 10) * len(clip_list("p1"))
        p95m = _vs_ceiling("e2e p95", p95, "ms", ["p1", "e2e_p95_ms", arm], arm in KNOWN_ARMS["p1"]); p95m["headline"] = f"p95 {p95}"
        share = int(c.group(1)) if c else None
        incomplete = bool(expected) and got < expected
        samples = _m("samples", f"{got} / {expected}" if expected else got, share=(got / expected) if expected else None,
                     status="bad" if incomplete else "ok", note="INCOMPLETE RUN — thresholds not applied" if incomplete else "complete matrix",
                     headline=f"{got} / {expected}" if incomplete else None)
        if incomplete: p95m["headline"] = None  # the incomplete matrix is the headline, not a p95 nobody should trust
        return ([samples] if incomplete else []) + [p95m,
                _m("e2e p50", p50, "ms", share=min(p50 / p95m["ceiling"], 1.0) if p95m.get("ceiling") else None, note="what the user typically waits"),
                _m("cleanup share", share if share is not None else "?", "%", share=(share or 0) / 100, status="warn" if (share or 0) > 50 else "ok", note="of the wait is the language model")] + ([] if incomplete else [samples])
    if bid == "asr":
        out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "asr_wer.py"), path], capture_output=True, text=True, timeout=60, cwd=ROOT).stdout
        rows = [l.split() for l in out.splitlines() if re.match(r"^(%s)\s" % "|".join(KNOWN_ARMS["asr"]), l)]
        if not rows: return [_m("engines", "none", status="bad", note="no AE lines", headline="no result")]
        ms = []
        names = {"v3": "Parakeet v3", "ctc110m": "Parakeet ctc110m"}
        for f in sorted(rows, key=lambda f: ("v3", "ctc110m").index(f[0]) if f[0] in ("v3", "ctc110m") else 9):
            wer = float(f[5].rstrip("%")); p50 = float(f[2]); known = f[0] in KNOWN_ARMS["asr"]
            w = _vs_ceiling(f"{names.get(f[0], f[0])} WER", wer, "%", ["asr", "wer_max_pct", f[0]], known, "{:.1f}")
            l = _vs_ceiling(f"{names.get(f[0], f[0])} p50", p50, "ms", ["asr", "p50_max_ms", f[0]], known)
            if f[0] == "v3": w["headline"] = f"v3 {wer:.1f}%"
            ms += [w, l]
        return ms
    if bid == "gate":
        t = [r for r in lines(path, "GT") if r[1] == "tally"]
        if not t: return [_m("verdicts", "none", status="bad", note="no tally", headline="no result")]
        tally = dict(kv.split("=") for kv in t[0][2].split())
        rej = sum(int(v) for k, v in tally.items() if not k.startswith("accept"))
        r = _vs_ceiling("refused", rej, "", ["gate", "max_refusals"], True); r["headline"] = f"{rej} refused"
        r["note"] = r["note"].replace("  ", " ").strip()
        return [r, _m("accepted", int(tally.get("accept", 0)), note="model output taken as-is"),
                _m("unchanged", int(tally.get("accept-unchanged", 0)), note="model returned the input")]
    if bid == "itn":
        rows = [r for r in lines(path, "NB") if len(r) >= 7]
        try: expected = len(json.load(open(os.path.join(ROOT, "voice-tests", "numbers", "numbers_ref.json"))))
        except Exception: expected = 0
        correct, total = {}, {}
        for r in rows:
            _, eng, clean, ref = nb_fields(r); total[eng] = total.get(eng, 0) + 1
            if clean.strip().lower().rstrip(".") == ref.strip().lower().rstrip("."): correct[eng] = correct.get(eng, 0) + 1
        if not rows: return [_m("cases", "none", status="bad", note="no NB lines", headline="no result")]
        def one(eng, name, must_all):
            c, n = correct.get(eng, 0), total.get(eng, 0); exp = expected or n
            bad = n < exp; st = "bad" if bad else ("warn" if (must_all and c < n) else "ok")
            return _m(name, f"{c} / {exp}", share=(c / exp) if exp else None, status=st,
                      note="INCOMPLETE RUN" if bad else ("every case must render correctly" if must_all else "the fallback engine, informational"), headline=f"{c} / {exp}" if eng == "v3" else None)
        return [one("v3", "Parakeet correct", True)]
    if bid == "review_corpus":
        t = [r for r in lines(path, "RC") if r[1] == "tally"]
        if not t: return [_m("copies", "none", status="bad", note="no RC lines: review some dictations on the Local review pane first", headline="no result")]
        tally = dict(kv.split("=") for kv in t[0][2].split())
        replayed, exact, copies = int(tally.get("replayed", 0)), int(tally.get("exact", 0)), int(tally.get("copies", 0))
        missing, unusable, none = int(tally.get("missing", 0)), int(tally.get("unusable", 0)), int(tally.get("no_recording", 0))
        failed, fallback = int(tally.get("failed", 0)), int(tally.get("fallback", 0))
        ned = float(tally.get("mean_ned", 1))
        incomplete = missing + unusable + failed
        return [_m("replayed", f"{replayed} / {copies}", status="bad" if replayed == 0 or incomplete else "ok",
                   note=("INCOMPLETE — every reviewed copy counts" if incomplete else "every reviewed copy")
                        + (f" · {none} from before recordings were kept" if none else ""),
                   headline=f"{replayed} replayed" + (" · INCOMPLETE" if incomplete else "")),
                _m("missing, unusable or failed", incomplete, status="bad" if incomplete else "ok",
                   note="a copy naming a recording that is not there, a recording too short to replay, or one the recognizer failed even single-pass"),
                _m("single-pass fallbacks", fallback, status="warn" if fallback else "ok", note="a segment failed and the whole take ran single-pass, as the app would"),
                _m("mean edit distance", f"{ned:.3f}", share=min(ned, 1.0), status="ok" if ned < 0.15 else "warn", note="word-level, over the reference's length; informational until the baseline is committed"),
                _m("exact", exact, share=(exact / replayed) if replayed else None, note="produced the reference's words in order")]
    if bid == "case":
        t = [r for r in lines(path, "CB") if r[1] == "tally"]
        if not t: return [_m("nouns", "none", status="bad", note="no CB lines", headline="no result")]
        lost, total = (int(x) for x in t[0][2].split()[0].split("/"))
        return [_m("capitals lost", f"{lost} / {total}", share=lost / total if total else None, status="ok" if lost <= 1 else "warn", note="baseline 1 of 24", headline=f"{lost} / {total} lost")]
    if bid == "repair":
        t = [r for r in lines(path, "RB") if r[1] == "tally"]
        if not t: return [_m("stumbles", "none", status="bad", note="no RB lines", headline="no result")]
        vals = {}
        for p in t[0][2:]:
            k, _, v = p.rpartition(" ")
            n = re.match(r"(\d+)(?:/\d+)?$", v)  # "hinted 5/12" carries its denominator (review 2026-09-02)
            if n: vals[k.strip()] = int(n.group(1))
        fixed = vals.get("pipeline fixed", 0)
        return [_m("pipeline fixed", f"{fixed} / 12", share=fixed / 12, status="ok" if fixed >= 6 else "warn", note="baseline 6 of 12", headline=f"{fixed} / 12 fixed"),
                _m("repair prompt fixed", vals.get("repair fixed", 0), note="the targeted prompt alone"),
                _m("generic fixed", vals.get("generic fixed", 0), note="the generic prompt alone"),
                _m("hinted", vals.get("hinted", 0), note="stumbles the detector flagged")]
    if bid == "long_input":
        out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "summarize_long.py"), path], capture_output=True, text=True, timeout=60, cwd=ROOT).stdout
        m = re.search(r"e2e:\s*(\d+) → (\d+) ms \(([-+\d]+)%\)", out)
        if not m: return [_m("e2e", "none", status="bad", note="no LI lines", headline="no result")]
        ident = "identical" in out and "True" in out
        return [_m("e2e with coalesce", int(m.group(2)), "ms", note=f"{m.group(3)}% vs {m.group(1)} ms without", headline=f"{m.group(3)}%"),
                _m("e2e without", int(m.group(1)), "ms", note="the same take, coalescing off"),
                _m("text identical", "yes" if ident else "no", status="ok" if ident else "warn", note="coalescing must not change the words")]
    if bid == "idle":
        rows = lines(path, "ID"); d = collections.defaultdict(list)
        for r in rows:
            if r[1] in ("natural", "tickled", "warmed", "fm-only"): d[(r[1], int(r[2]))].append(int(r[5]))
        if not d: return [_m("idle", "none", status="bad", note="no ID lines", headline="no result")]
        nat = statistics.median(d.get(("natural", 15), [0])); tick = statistics.median(d.get(("tickled", 15), [0]))
        return [_m("kept warm, after 15 s", int(tick), "ms", ceiling=900, share=min(tick / 900, 1.0), status="ok" if tick and tick < 900 else "warn", note="warn past 900 ms", headline=f"{int(tick)} ms warm"),
                _m("natural, after 15 s", int(nat), "ms", note="the cold-model penalty the keep-warm loop hides")]
    if bid == "overlap_perclip":
        clips = [r for r in lines(path, "OV") if r[1] == "clip"]
        if not clips: return [_m("clips", "none", status="bad", note="no clip lines", headline="no result")]
        same = sum(1 for r in clips if r[6] == "true"); n = len(clips)
        return [_m("identical", f"{same} / {n}", share=same / n, status="ok" if same == n else "warn", note="text must not change under overlap", headline=f"{same} / {n}"),
                _m("overlapped mean", int(statistics.mean(int(r[4]) for r in clips)), "ms"),
                _m("single-pass mean", int(statistics.mean(int(r[5]) for r in clips)), "ms")]
    if bid.startswith("overlap"):
        rows = lines(path, "OV")
        ov = [int(r[4]) for r in rows if r[1] == "overlap"]; sg = [int(r[3]) for r in rows if r[1] == "single"]
        if not ov: return [_m("overlap", "none", status="bad", note="no OV lines", headline="no result")]
        texts = {r[1]: "|".join(r[5:] if r[1] == "overlap" else r[4:]) for r in rows if r[1] in ("overlap", "single")}
        import difflib
        diffs = sum(1 for op in difflib.SequenceMatcher(None, texts.get("single", "").split(), texts.get("overlap", "").split()).get_opcodes() if op[0] != "equal")
        after = int(statistics.median(ov)); single = int(statistics.median(sg)) if sg else 0
        return [_m("wait after release", after, "ms", share=min(after / single, 1.0) if single else None, note=f"single-pass {single} ms", headline=f"{after} ms"),
                _m("text diffs vs single-pass", diffs, ceiling=12, share=min(diffs / 12, 1.0), status="ok" if diffs <= 12 else "warn", note="word-level edits; warn past 12"),
                _m("single-pass", single, "ms", note="the same audio without overlap")]
    return []

# ---------------------------------------------------------------- runner

lock = threading.Lock()
state = {"running": None, "queue": [], "results": {}, "history": {}, "log": ""}
current_proc = None

def _terminate(signum, frame):
    proc = current_proc
    if proc and proc.poll() is None:
        try: proc.terminate()
        except Exception: pass
    raise SystemExit(0)
HIST_DIR = os.path.join(OUT, "history")
HIST_KEEP = 30

def sweep_interrupted():
    """A leftover .running file means a previous server was killed mid-run:
    the last good log/result pair is untouched (see run_one's promote), but
    the interruption itself must be visible in history."""
    import glob as _g
    for f in _g.glob(os.path.join(OUT, "*.txt.running")):
        bid = os.path.basename(f)[:-len(".txt.running")]
        state["history"].setdefault(bid, []).insert(0, {
            "when": time.strftime("%Y-%m-%d %H:%M:%S"), "status": "fail",
            "summary": "interrupted — server stopped mid-run; showing the last completed run", "seconds": 0, "file": ""})
        try: os.remove(f)
        except Exception: pass
        save_state()  # the entry must outlive this server process, not just the next completed run

def load_state():
    try:
        data = json.load(open(STATE))
        if "results" in data and isinstance(data.get("results"), dict):
            state["results"] = data["results"]; state["history"] = data.get("history", {})
        else:  # legacy: the file was just the results dict
            state["results"] = data
        # Rows that no longer exist (the archived Glue bench, the pre-split
        # monolithic unit row) must not linger as remembered verdicts.
        for stale in [b for b in state["results"] if b not in BY_ID]: del state["results"][stale]
        for stale in [b for b in state["history"] if b not in BY_ID]: del state["history"][stale]
    except Exception: pass

def save_state():
    os.makedirs(OUT, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"results": state["results"], "history": state["history"]}, f, indent=2)
    os.replace(tmp, STATE)

def verdict(bid, path, returncode=0):
    """The status/summary for a finished log. The process verdict outranks
    the summarizer's (review 2026-09-01): a bench that crashed after
    emitting some lines, or that failed as XCTest (a ceiling assertion,
    #308), is red no matter how its data looks."""
    summarize = BY_ID[bid][4]
    try:
        status, summary = summarize(path)
    except Exception as ex:  # a broken summarizer must not erase a completed run
        status, summary = "fail", f"summarizer error: {ex} (raw log kept)"
    m = re.search(r"Executed \d+ tests?, with (?:\d+ tests? skipped and )?(\d+) failures?", exec_line(path) or "")
    xc_failures = int(m.group(1)) if m else 0
    if returncode != 0 and status != "fail":
        status, summary = "fail", f"process exited {returncode} · " + summary
    elif xc_failures and status != "fail":
        status, summary = "fail", f"{xc_failures} XCTest failure(s) · " + summary
    return status, summary

def reconcile_results():
    """Startup: the stored verdict for every bench is recomputed from the
    log on disk. A result and its log can disagree when the log was written
    by a server older than the promote-on-completion rule, or when the
    summarizer's rules changed since the run — the page must show what the
    log supports, never a remembered green (review 2026-09-01, round 3)."""
    changed = []
    for bid, r in list(state["results"].items()):
        path = os.path.join(OUT, f"{bid}.txt")
        if bid not in BY_ID or not os.path.isfile(path): continue
        if "exit" in r and r["exit"] is None: continue  # a runner error owns no log; the log on disk is an older run's
        # The stored exit status travels with the re-judgement (round 4: a
        # crashed run's partial-but-complete-looking log came back green).
        # Results older than the "exit" field carry it in the summary text.
        m = re.match(r"process exited (-?\d+)", r.get("summary", ""))
        exit_code = r.get("exit", int(m.group(1)) if m else 0)
        status, summary = verdict(bid, path, exit_code)
        if r.get("status") == "fail" and status != "fail" and r.get("exit") is None:
            # Legacy result with no exit on record: a stored failure may only
            # turn green on a conclusive, clean XCTest footer.
            footer = re.search(r"Executed \d+ tests?, with (?:\d+ tests? skipped and )?0 failures", exec_line(path) or "")
            if not footer: continue
        note = " · re-evaluated at startup from the log on disk"
        # Metrics are derived data: always refreshed from the log at startup,
        # so a change in how they are computed reaches stored results too.
        fresh = metrics_for(bid, path)
        if fresh != r.get("metrics"):
            r["metrics"] = fresh; changed.append(f"{bid}: metrics")
        if status == r.get("status") and summary == r.get("summary", "").split(note)[0]: continue
        r.update({"status": status, "summary": summary + note + f" (run of {r.get('when', '?')})", "exit": exit_code, "metrics": metrics_for(bid, path)})
        changed.append(f"{bid}: {status}")
    if changed:
        save_state()
        print("reconciled stored results with their logs: " + ", ".join(changed))

def run_one(bid):
    _, title, _, spec, summarize, _ = BY_ID[bid]
    path = os.path.join(OUT, f"{bid}.txt")
    subprocess.run(["defaults", "delete", "com.apple.dt.xctest.tool", "reed.debugParakeet"], capture_output=True, timeout=10)
    env = run_env(spec, path)
    t0 = time.time()
    tmp_path = prepare_run(path)
    with open(tmp_path, "w") as f:
        proc = subprocess.Popen(spec["cmd"], cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
        global current_proc
        current_proc = proc
        while proc.poll() is None:
            time.sleep(2)
            try: state["log"] = "".join(open(tmp_path, errors="replace").readlines()[-12:])
            except Exception: pass
    promote_run(tmp_path, path)  # promote only a finished run — an interrupted one never clobbers the last good log
    when = time.strftime("%Y-%m-%d %H:%M:%S")
    os.makedirs(HIST_DIR, exist_ok=True)
    hist_name = f"{bid}-{time.strftime('%Y%m%d-%H%M%S')}.txt"
    try:
        shutil.copyfile(path, os.path.join(HIST_DIR, hist_name))
        if os.path.isfile(app_log_path(path)): shutil.copyfile(app_log_path(path), app_log_path(os.path.join(HIST_DIR, hist_name)))
    except Exception: hist_name = ""
    status, summary = verdict(bid, path, proc.returncode)
    with lock:
        # "exit" is persisted so a restart can re-judge the log without
        # forgetting that the process died (review 2026-09-01, round 4).
        state["results"][bid] = {"status": status, "summary": summary, "when": when, "seconds": int(time.time() - t0),
                                 "file": os.path.relpath(path, ROOT), "exit": proc.returncode, "metrics": metrics_for(bid, path)}
        entries = state["history"].setdefault(bid, [])
        entries.insert(0, {"when": when, "status": status, "summary": summary, "seconds": int(time.time() - t0), "file": hist_name})
        for stale in entries[HIST_KEEP:]:
            if stale.get("file"):
                try: remove_archived(os.path.join(HIST_DIR, stale["file"]))
                except Exception: pass
        del entries[HIST_KEEP:]
        save_state()

def worker():
    while True:
      try:
        with lock:
            bid = state["queue"].pop(0) if state["queue"] else None
            state["running"] = bid
        if bid is None:
            time.sleep(1); continue
        try: run_one(bid)
        except Exception as ex:
            with lock:
                # exit=None: no log belongs to this result, so startup must not re-judge an older one under its date
                state["results"][bid] = {"status": "fail", "summary": f"runner error: {ex}", "when": time.strftime("%Y-%m-%d %H:%M:%S"), "seconds": 0, "file": "", "exit": None}
                save_state()
        with lock: state["running"] = None; state["log"] = ""
      except Exception:
        try:
            with lock: state["running"] = None
        except Exception: pass
        time.sleep(1)

# ---------------------------------------------------------------- page

PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Reed QA</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root{color-scheme:light dark;--ground:#f4f5f3;--stage:#fff;--ink:#171a1f;--ink2:#4b5160;--mute:#8a909c;--hair:#e3e6ea;--row:#eef0f2;--acc:#2f5ba8;--acc-ink:#fff;--ok:#2e7d4f;--warn:#b9791c;--bad:#c23b2b;--run:#2f5ba8}
@media(prefers-color-scheme:dark){:root{--ground:#131519;--stage:#1a1d22;--ink:#e8eaee;--ink2:#b3b8c2;--mute:#7f8794;--hair:#2a2f37;--row:#22262d;--acc:#7fa6f0;--acc-ink:#0f1420;--ok:#6fcf97;--warn:#e0a84a;--bad:#e56b5b;--run:#7fa6f0}}
*{box-sizing:border-box}html,body{height:100%}
body{margin:0;display:grid;grid-template-columns:300px 1fr;background:var(--ground);color:var(--ink);font:13.5px/1.45 "IBM Plex Sans",-apple-system,"Helvetica Neue",Arial,sans-serif;overflow:hidden}
.mono{font-family:"IBM Plex Mono",ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums}
button{font:inherit;border-radius:7px;border:1px solid var(--hair);background:var(--stage);color:var(--ink);cursor:pointer}
button:disabled{opacity:.45;cursor:default}
button:focus-visible,.row:focus-visible{outline:2px solid var(--acc);outline-offset:1px}
.st{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:500;line-height:1.6}
.st.ok{background:color-mix(in srgb,var(--ok) 14%,transparent);color:var(--ok)}
.st.warn{background:color-mix(in srgb,var(--warn) 16%,transparent);color:var(--warn)}
.st.fail{background:color-mix(in srgb,var(--bad) 15%,transparent);color:var(--bad)}
.st.running{background:color-mix(in srgb,var(--run) 15%,transparent);color:var(--run)}
.st.queued{background:var(--row);color:var(--mute)}.never{color:var(--mute);font-size:11px}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block;flex:none;background:var(--mute)}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.dot.fail{background:var(--bad)}.dot.running,.dot.queued{background:var(--run)}.dot.never{background:transparent;border:1.5px solid var(--mute)}
.dot.running{animation:pulse 1.2s ease-in-out infinite}@keyframes pulse{50%{opacity:.35}}
@media(prefers-reduced-motion:reduce){.dot.running{animation:none}}
/* ---- sidebar: the whole inventory ---- */
.rv{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:8px}.rvcol .cap{font:500 10.5px/1 "IBM Plex Mono",monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--mute);margin-bottom:6px}
.rvtext{line-height:1.6;font-size:13.5px}.rvtext .bd{color:var(--mute);font-size:11px}.rvtext .seam{color:var(--acc);font-family:"IBM Plex Mono",monospace;font-size:11px}
.rvpre{font:11.5px/1.5 "IBM Plex Mono",monospace;color:var(--mute);white-space:pre-wrap;margin:0}
#ref{width:100%;box-sizing:border-box;font:13.5px/1.55 "IBM Plex Sans",sans-serif;padding:8px 10px;border:1px solid var(--hair);border-radius:8px;background:#fff;color:var(--ink)}
.rvbtns{display:flex;gap:8px;justify-content:flex-end;margin-top:8px}
#side{background:var(--stage);border-right:1px solid var(--hair);display:flex;flex-direction:column;min-height:0}
#side .brand{display:flex;align-items:baseline;justify-content:space-between;padding:14px 16px 8px}
#side .brand b{font-size:15px;font-weight:600}
#side .brand small{color:var(--mute);font-size:11px}
#tree{flex:1;overflow-y:auto;min-height:0;padding-bottom:8px}
.grp{display:flex;align-items:center;gap:8px;padding:12px 16px 4px;font:500 10.5px/1 "IBM Plex Mono",monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--mute);user-select:none}
.grp .st{margin-left:auto;text-transform:none;letter-spacing:0;font-family:"IBM Plex Sans",sans-serif}
.grp button{padding:1px 7px;font-size:10.5px;border-radius:5px;color:var(--mute)}
.row{display:grid;grid-template-columns:8px 1fr auto;gap:10px;align-items:center;padding:5px 14px 5px 13px;border-left:3px solid transparent;cursor:pointer;user-select:none}
.row:hover{background:var(--row)}.row.sel{background:var(--row);border-left-color:var(--acc)}
.row .n{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:13px}
.row .m{font:11.5px "IBM Plex Mono",monospace;font-variant-numeric:tabular-nums;color:var(--mute);white-space:nowrap}
.row.fail .m{color:var(--bad)}.row.warn .m{color:var(--warn)}
#side .note{padding:10px 16px;border-top:1px solid var(--hair);color:var(--mute);font-size:11px;line-height:1.45}
#side .note b{color:var(--ink2)}
#side .actions{padding:10px 16px 12px;border-top:1px solid var(--hair)}
#side .actions button{width:100%;padding:8px 0;background:var(--ink);color:var(--ground);border-color:var(--ink);font-weight:500}
/* ---- detail ---- */
#detail{overflow-y:auto;padding:22px 32px 40px;min-height:0}
.dwrap{max-width:980px}
.empty{color:var(--mute);padding-top:40vh;text-align:center;font-size:13px}
.d-head{display:flex;align-items:flex-start;gap:12px;margin-bottom:2px}
.d-head h2{margin:0;font-size:19px;font-weight:600;letter-spacing:-.01em;flex:1;line-height:1.25}
.d-head .st{margin-top:3px}
.d-head button.run{padding:7px 18px;font-weight:500;background:var(--acc);color:var(--acc-ink);border-color:var(--acc)}
.meta{color:var(--mute);font-size:12px;margin:2px 0 16px}
.meta b{color:var(--ink2);font-weight:500}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:0 0 16px}
.tile{background:var(--stage);border:1px solid var(--hair);border-radius:8px;padding:11px 13px 10px}
.tile .l{font:500 10.5px "IBM Plex Mono",monospace;letter-spacing:.08em;text-transform:uppercase;color:var(--mute);margin-bottom:5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tile .v{font-size:21px;font-weight:600;line-height:1.1;font-variant-numeric:tabular-nums;margin-bottom:8px;white-space:nowrap}
.tile .v small{font-size:12px;font-weight:500;color:var(--mute);margin-left:4px}
.tile .v.bad{color:var(--bad)}.tile .v.warn{color:var(--warn)}
.bar{height:5px;border-radius:3px;background:var(--row);position:relative}
.bar i{display:block;height:100%;border-radius:3px;background:var(--ok)}
.bar i.warn{background:var(--warn)}.bar i.bad{background:var(--bad)}
.bar em{position:absolute;top:-3px;right:0;width:2px;height:11px;background:var(--ink);opacity:.5}
.tile .c{font-size:11px;color:var(--mute);margin-top:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tile .c.bad{color:var(--bad)}
.banner{background:color-mix(in srgb,var(--warn) 12%,transparent);border:1px solid color-mix(in srgb,var(--warn) 40%,transparent);border-radius:7px;padding:8px 12px;font-size:12.5px;margin:0 0 14px;display:flex;gap:10px;align-items:center}
.banner button{margin-left:auto;padding:3px 10px;font-size:12px}
.tabs{display:flex;gap:2px;border-bottom:1px solid var(--hair);margin:4px 0 14px}
.tabs span{padding:7px 12px;color:var(--mute);font-weight:500;border-bottom:2px solid transparent;margin-bottom:-1px;cursor:pointer;user-select:none}
.tabs span.on{color:var(--ink);border-bottom-color:var(--ink)}
.tabs span:hover{color:var(--ink)}
.sec{font:500 10.5px/1 "IBM Plex Mono",monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--mute);margin:18px 0 8px}
.d-desc{color:var(--ink);font-size:13.5px;max-width:72ch;margin:0 0 6px;line-height:1.55}
.d-inputs{color:var(--mute);font-size:12.5px;margin:0 0 12px}
.cmd{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:11.5px;color:var(--ink2);background:var(--stage);border:1px solid var(--hair);border-radius:7px;padding:9px 12px;overflow-x:auto;white-space:nowrap}
.clips{background:var(--stage);border:1px solid var(--hair);border-radius:7px;overflow:hidden}
.clip{display:flex;align-items:center;gap:12px;padding:7px 12px;border-bottom:1px solid var(--hair)}
.clip:last-child{border-bottom:0}
.clip .play{width:28px;height:28px;min-width:28px;border-radius:50%;padding:0;font-size:11px;line-height:1;display:flex;align-items:center;justify-content:center}
.clip .cname{font-family:"IBM Plex Mono",monospace;font-size:11.5px;color:var(--ink2);min-width:110px}
.clip .pbar{flex:1;height:4px;background:var(--row);border-radius:2px;overflow:hidden}
.clip .pbar i{display:block;height:100%;width:0;background:var(--acc)}
.clip .ct{font-family:"IBM Plex Mono",monospace;font-size:11px;color:var(--mute);min-width:72px;text-align:right}
.hist{background:var(--stage);border:1px solid var(--hair);border-radius:7px;overflow:hidden}
.hrow{display:flex;align-items:center;gap:12px;padding:7px 12px;border-bottom:1px solid var(--hair);cursor:pointer;font-size:12.5px}
.hrow:last-child{border-bottom:0}.hrow:hover{background:color-mix(in srgb,var(--row) 55%,transparent)}
.hrow.sel{background:var(--row)}.hrow.dead{opacity:.55;cursor:default}
.hwhen{color:var(--ink2);font-size:11.5px;min-width:130px}
.hsum{color:var(--mute);flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:12px}
.htook{color:var(--mute);font-size:11px;min-width:44px;text-align:right}
.suites{background:var(--stage);border:1px solid var(--hair);border-radius:7px;overflow:hidden}
.srow{display:flex;align-items:center;gap:10px;padding:7px 12px;border-top:1px solid var(--hair);cursor:pointer;user-select:none}
.suites>.srow:first-child{border-top:0}
.srow:hover{background:color-mix(in srgb,var(--row) 55%,transparent)}
.srow.failed{background:color-mix(in srgb,var(--bad) 8%,transparent)}
.smark{width:14px;text-align:center;font-size:11px}.okc{color:var(--ok)}.badc{color:var(--bad)}.skc{color:var(--mute)}
.pendc{color:var(--mute);opacity:.6}.runc{color:var(--run);animation:pulse 1.2s ease-in-out infinite}
.livehead{display:flex;align-items:center;gap:10px;font-size:12.5px;color:var(--ink2);margin:0 0 10px}
.livehead .prog{flex:1;height:5px;border-radius:3px;background:var(--row);overflow:hidden}.livehead .prog i{display:block;height:100%;background:var(--run);transition:width .4s}
@media(prefers-reduced-motion:reduce){.runc{animation:none}.livehead .prog i{transition:none}}
.sname{font-size:12px;color:var(--ink)}
.scount{font-size:11px;color:var(--mute);margin-left:auto}
.schev{color:var(--mute);font-size:10px;width:12px}
.sbody{border-top:1px solid var(--hair);background:color-mix(in srgb,var(--row) 45%,var(--stage));padding:8px 12px 10px 36px}
.sdoc{color:var(--ink2);font-size:12.5px;margin:2px 0 8px;max-width:80ch}
.scase{display:flex;align-items:center;gap:8px;padding:2px 0;font-size:12.5px;color:var(--ink)}
.scase .sms{margin-left:auto;font-size:10.5px;color:var(--mute)}
.fails{background:color-mix(in srgb,var(--bad) 8%,transparent);border:1px solid color-mix(in srgb,var(--bad) 35%,transparent);border-radius:7px;padding:8px 12px;margin:0 0 10px;font-size:12.5px}
.fails b{color:var(--bad);display:block;margin-bottom:4px}
.fails div{font-family:"IBM Plex Mono",monospace;font-size:11.5px}
pre.d-lines{margin:0;font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:11.5px;line-height:1.6;background:var(--stage);border:1px solid var(--hair);border-radius:7px;padding:12px 14px;max-height:56vh;overflow:auto;white-space:pre-wrap;color:var(--ink2)}
pre#log{font-family:"IBM Plex Mono",monospace;background:var(--stage);border:1px solid var(--hair);border-radius:7px;padding:10px 12px;font-size:11px;max-height:140px;overflow:auto;color:var(--ink2);white-space:pre-wrap;margin:0}
kbd{font:11px "IBM Plex Mono",monospace;border:1px solid var(--hair);border-bottom-width:2px;border-radius:4px;padding:0 5px;color:var(--ink2)}
</style></head><body>
<aside id="side"><div class="brand"><b>Reed QA</b><small>Parakeet v3</small></div><div id="tree"></div>
<div class="note"><b>Don't dictate while a bench runs.</b> Apple's cleanup model is shared system-wide. <kbd>↑</kbd><kbd>↓</kbd> rows · <kbd>R</kbd> run · <kbd>1</kbd>–<kbd>4</kbd> tabs</div>
<div class="actions"><button onclick="runAll()">Run everything · ~__TOTAL_MIN__ min</button></div></aside>
<main id="detail"></main>
<script>
const B=__BENCHES__;let S={};const cache={};
const groups=[...new Set(B.map(b=>b.group))];
const q=new URLSearchParams(location.search);
let selTest=q.get('t')==='review'?'review':q.get('t')&&B.some(b=>b.id===q.get('t'))?q.get('t'):(groups.includes(q.get('g'))?B.find(b=>b.group===q.get('g')).id:B[0].id);
let tab=['results','history','about','audio'].includes(q.get('tab'))?q.get('tab'):'results';
const NL=String.fromCharCode(10);
let histRun=null;const openSuites=new Set();const suiteCache={};
let live=null;  // /progress of the selected row while it runs: suites and cases fill in as they finish
async function fetchLive(){if(!selTest||!['running','queued'].includes(stOf(selTest))){live=null;return}
  try{const p=await (await fetch('/progress?id='+selTest)).json();
    live=stOf(selTest)==='queued'?{queued:true,inventory:p.inventory||[],suites:[],cases:{},lines:[]}:p}catch(e){}}
function dkey(){return selTest+(histRun?'|'+histRun:'')}
function skey(n){return dkey()+'|'+n}
function human(n){const t=n.replace(/^test/,'').replace(/([a-z0-9])([A-Z])/g,'$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g,'$1 $2');return t.charAt(0)+t.slice(1).toLowerCase().replace(/\b(fm|itn|asr|wav|api|url|ui|id|rms|db|ci|s3|hal)\b/g,m=>m.toUpperCase())}
function esc(x){return String(x==null?'':x).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function stOf(id){const r=(S.results||{})[id];return S.running===id?'running':(S.queue||[]).includes(id)?'queued':r?r.status:null}
function chip(st){return st?`<span class="st ${st}">${st}</span>`:'<span class="never">never run</span>'}
function worst(ids){const o={fail:0,warn:1,running:2,queued:3,ok:4};let w=null;for(const id of ids){const st=stOf(id);if(st&&(w===null||o[st]<o[w]))w=st}return w}
function fmt(t){if(t==null||isNaN(t))return'0:00';const m=Math.floor(t/60),x=Math.floor(t%60);return m+':'+(x<10?'0':'')+x}
function took(s){if(s==null)return'';return s>=90?Math.round(s/60)+' min':s+' s'}
function ago(when){if(!when)return'';const t=Date.parse(when.replace(' ','T'));if(isNaN(t))return when;const d=(Date.now()-t)/1000;
  if(d<90)return'just now';if(d<3600)return Math.round(d/60)+' min ago';if(d<86400*1.5)return Math.round(d/3600)+' h ago';return Math.round(d/86400)+' days ago'}
function headline(r){const m=r&&r.metrics&&r.metrics.length?r.metrics.find(x=>x.headline)||r.metrics[0]:null;if(!m)return'';
  return m.headline||(m.value+(m.unit?' '+m.unit:''))}
const inflight=new Set();
async function fetchKey(k){if(inflight.has(k)||(cache[k]&&cache[k].command))return;inflight.add(k);
  try{const parts=k.split('|'),bid=parts[0],runf=parts.slice(1).join('|');
    const d=await (await fetch('/detail?id='+bid+(runf?'&run='+encodeURIComponent(runf):''))).json();
    const r=(S.results||{})[bid];d._when=r?r.when:null;cache[k]=d;
  }catch(e){}finally{inflight.delete(k)}renderDetail()}
function fetchDetail(){return fetchKey(dkey())}
function stopAudio(){if(ply.a){ply.a.pause();ply.a=null;ply.url=null}}
function viewRun(f){histRun=f||null;openSuites.clear();tab='results';renderDetail();fetchDetail()}
function setTab(t){tab=t;history.replaceState(null,'','?t='+selTest+'&tab='+t);renderDetail();if(t==='audio')syncPlayer()}
async function toggleSuite(n){if(openSuites.has(n)){openSuites.delete(n);renderDetail();return}
  openSuites.add(n);renderDetail();
  if(!suiteCache[skey(n)]){
    try{suiteCache[skey(n)]=await (await fetch('/suite?id='+selTest+'&name='+encodeURIComponent(n)+(histRun?'&run='+encodeURIComponent(histRun):''))).json()}
    catch(e){suiteCache[skey(n)]={doc:'',cases:[],error:'could not load this suite ('+e+')'}}
    renderDetail()}}
/* ---- player: lives in JS, survives any re-render ---- */
const ply={url:null,a:null};
function playClip(url){
  if(ply.url===url&&ply.a){if(ply.a.paused)ply.a.play();else ply.a.pause();syncPlayer();return}
  if(ply.a){ply.a.pause();ply.a=null}
  ply.url=url;ply.a=new Audio(url);
  ply.a.addEventListener('timeupdate',syncPlayer);
  ply.a.addEventListener('ended',()=>{ply.url=null;ply.a=null;renderDetail()});
  ply.a.addEventListener('pause',syncPlayer);ply.a.addEventListener('play',syncPlayer);
  ply.a.play();renderDetail();
}
function syncPlayer(){
  document.querySelectorAll('.clip').forEach(el=>{
    const u=el.dataset.url,me=ply.a&&ply.url===u;
    el.querySelector('.play').textContent=me&&!ply.a.paused?'❚❚':'▶';
    el.querySelector('.pbar i').style.width=me&&ply.a.duration?(100*ply.a.currentTime/ply.a.duration)+'%':'0';
    const d=el.dataset.secs;el.querySelector('.ct').textContent=(me?fmt(ply.a.currentTime):'0:00')+' / '+fmt(+d);
  });
}
/* ---- sidebar ---- */
/* ---- Local review (P16): not a bench row — the app's review copies, read from disk ---- */
let RV={state:null,copies:[],open:null,copy:null};
async function fetchReview(){try{const r=await (await fetch('/review')).json();RV.state=r.state;RV.copies=r.copies}catch(e){}}
async function openCopy(id){RV.open=id;RV.copy=null;renderDetail();try{RV.copy=await (await fetch('/review/copy?id='+encodeURIComponent(id))).json()}catch(e){}renderDetail()}
function nextUnreviewed(after){const list=RV.copies.filter(c=>!c.reviewed&&!c.unreadable&&c.id!==after).sort((a,b)=>(b.pauses||0)-(a.pauses||0));return list.length?list[0].id:null}
async function saveReference(id,edited){const ta=document.getElementById('ref');if(!ta)return;const text=ta.value.trim();if(!text)return;
  const r=await fetch('/review/reference?id='+encodeURIComponent(id),{method:'POST',headers:{'X-Reed-QA':'1','Content-Type':'application/json'},body:JSON.stringify({text,edited})});
  if(!r.ok){alert('not saved: '+await r.text());return}
  await fetchReview();const n=nextUnreviewed(id);if(n)openCopy(n);else{RV.open=null;RV.copy=null;renderAll()}}
function acceptTyped(id){const ta=document.getElementById('ref');if(ta&&RV.copy)ta.value=RV.copy.record.finalText||'';saveReference(id,false)}
function skipCopy(id){const n=nextUnreviewed(id);if(n)openCopy(n);else{RV.open=null;RV.copy=null;renderAll()}}
async function deleteCopies(){const n=RV.state?RV.state.count:0,rec=RV.state?RV.state.recordings||0:0;if(!confirm('Delete '+n+' review copies'+(rec?' and '+rec+' recording'+(rec===1?'':'s'):'')+'? Every copy, reference and recording on this Mac is removed. This can\u2019t be undone.'+(RV.state&&RV.state.collecting?' You are still opted in \u2014 run scripts/qa/review.sh off to stop collecting.':'')))return;
  const r=await (await fetch('/review/delete',{method:'POST',headers:{'X-Reed-QA':'1'}})).json();if(r.failed&&r.failed.length)alert('not removed: '+r.failed.join(', '));RV.open=null;RV.copy=null;await fetchReview();renderAll()}
function kb(b){return b<1024?b+' B':b<1048576?(b/1024).toFixed(1)+' KB':(b/1048576).toFixed(1)+' MB'}
function reviewRow(){const st=RV.state;const hl=!st?'':st.collecting?(st.unreviewed?st.unreviewed+' unreviewed':st.count+' copies'):'off';
  return `<div class="grp">Local review<span class="st" style="visibility:hidden"></span></div><div class="row ${selTest==='review'?'sel':''}" tabindex="0" onclick="pickTest('review')" title="Review copies on this Mac"><span class="dot ${st&&st.collecting?'ok':'never'}"></span><span class="n">Review copies</span><span class="m">${esc(hl)}</span></div>`}
function renderReview(){const el=document.getElementById('detail');const st=RV.state;
  let h=`<div class="dwrap"><div class="d-head"><h2>Local review</h2>${st?`<span class="st ${st.collecting?'ok':'never'}">${st.collecting?'collecting':'not collecting'}</span>`:''}<button class="run" ${st&&(st.count||st.recordings)?'':'disabled'} onclick="deleteCopies()">Delete review copies…</button></div>`;
  if(!st)h+=`<div class="meta">loading…</div>`;
  else{h+=`<div class="meta">${st.count} ${st.count===1?'copy':'copies'}${st.recordings?` · ${st.recordings} recording${st.recordings===1?'':'s'}`:''}${st.recordings>(st.withAudio||0)?` · <b>${st.recordings-(st.withAudio||0)} orphaned</b>`:''} · ${kb(st.bytes)}${st.oldestExpires?' · the oldest expires '+esc(st.oldestExpires.slice(0,10)):''} · ${st.unreviewed} unreviewed · <code>${esc(st.directory)}</code></div>`;
    h+=`<div class="d-inputs">${st.collecting?'Collecting because you ran <code>scripts/qa/review.sh on</code>. Stop with <code>review.sh off</code>.':'Not collecting. Opt in with <code>scripts/qa/review.sh on</code>.'} Copies are text plus the dictation\u2019s recording (WAV, for the corpus bench), never leave this Mac, and expire after 14 days. Only a human sets a reference; the typed text is never promoted by software.</div>`;
    const unrev=RV.copies.filter(c=>!c.reviewed).sort((a,b)=>(b.pauses||0)-(a.pauses||0)),rev=RV.copies.filter(c=>c.reviewed);
    if(!RV.copies.length)h+=`<div class="empty">No copies yet — the next dictation is the first.</div>`;
    h+=`<div class="sec">Unreviewed · ${unrev.length}</div>`+unrev.map(copyRow).join('')+(rev.length?`<div class="sec">Reviewed · ${rev.length}</div>`+rev.map(copyRow).join(''):'');
    if(RV.open)h+=openCopyView();}
  h+=`</div>`;
  /* The poll re-renders every 3 s; an identical render is skipped, and a
     changed one carries the playing recording across (review 2026-09-07). */
  if(el.dataset.rvhtml===h)return;
  const old=document.getElementById('rvaudio');const was=old?{copy:old.dataset.copy,t:old.currentTime,playing:!old.paused&&!old.ended}:null;
  el.innerHTML=h;el.dataset.rvhtml=h;
  const a=document.getElementById('rvaudio');if(a&&was&&a.dataset.copy===was.copy){a.currentTime=was.t;if(was.playing)a.play().catch(()=>{})}
  const ta=document.getElementById('ref');if(ta&&RV.copy&&!ta.dataset.filled){ta.value=(RV.copy.record.reference&&RV.copy.record.reference.text)||RV.copy.record.finalText||'';ta.dataset.filled='1'}}
function copyRow(c){if(c.unreadable)return`<div class="row never"><span class="dot fail"></span><span class="n">${esc(c.id)}</span><span class="m">unreadable</span></div>`;
  return `<div class="row ${RV.open===c.id?'sel':''}" tabindex="0" onclick="openCopy('${esc(c.id)}')"><span class="dot ${c.reviewed?'ok':'queued'}"></span><span class="n">${esc((c.startedAt||'').replace('T',' ').replace('Z',''))} · ${esc(c.preview)}</span><span class="m">${c.segments} seg${c.pauses?` · ${c.pauses} pause`:''} · ${c.chunks} ch${c.reviewed?' · reviewed':''}</span></div>`}
function openCopyView(){const c=RV.copy;if(!c)return`<div class="sec">Copy</div><div class="meta">loading…</div>`;const r=c.record;
  const heard=c.heard.map(s=>`${s.joinedBy?`<span class="seam" title="seam: ${esc(s.joinedBy)}">‖${esc(s.joinedBy)}‖</span> `:''}${esc(s.corrected||s.raw)}<small class="bd"> [${esc(s.boundary)}${s.cleanupPath?' · '+esc(s.cleanupPath):''}]</small>`).join(' ');
  const meta=`${esc((r.startedAt||'').replace('T',' ').replace('Z',''))} · ${esc(r.mode)} · ${esc(r.engine)} · ${c.heard.length} segments · ${(r.chunks||[]).length} chunks · ${r.timings?r.timings.totalSeconds.toFixed(1)+'s':''}${r.targetBundleID?' · '+esc(r.targetBundleID):''}`;
  return `<div class="sec">Review · ${esc(c.id)}</div><div class="meta">${meta}</div>
<div class="rv"><div class="rvcol"><div class="cap">heard</div><div class="rvtext">${heard}</div><div class="cap" style="margin-top:8px">chunks</div><pre class="rvpre">${esc(c.chunkLines.join(NL))}</pre></div>
<div class="rvcol">${RV.copies.find(x=>x.id===c.id)&&RV.copies.find(x=>x.id===c.id).audio?`<div class="cap">recording</div><audio id="rvaudio" data-copy="${esc(c.id)}" controls preload="none" src="/review/audio?id=${encodeURIComponent(c.id)}" style="width:100%;margin-bottom:8px"></audio>`:''}<div class="cap">typed — edit into what you wanted</div><textarea id="ref" rows="8"></textarea>
<div class="rvbtns"><button onclick="skipCopy('${esc(c.id)}')">Skip</button><button onclick="acceptTyped('${esc(c.id)}')">Accept as typed</button><button class="run" onclick="saveReference('${esc(c.id)}',true)">Save reference</button></div>
${r.reference?`<div class="meta">reference set ${esc(r.reference.setAt)} · ${r.reference.edited?'edited':'accepted as typed'}</div>`:''}</div></div>`}
function renderTree(){
  document.getElementById('tree').innerHTML=reviewRow()+groups.map(g=>{const rows=B.filter(b=>b.group===g);const w=worst(rows.map(b=>b.id));
    return `<div class="grp">${esc(g)}<span class="st ${w||'queued'}" style="${w?'':'visibility:hidden'}">${w||''}</span><button onclick="runGroup('${esc(g)}')" title="Run every row in ${esc(g)}">run</button></div>`+
      rows.map(b=>{const r=(S.results||{})[b.id],st=stOf(b.id);const hl=st==='running'?'running…':st==='queued'?'queued':r?headline(r):'~'+b.minutes+' min';
        return `<div class="row ${st||'never'} ${selTest===b.id?'sel':''}" tabindex="0" onclick="pickTest('${b.id}')" title="${esc(b.title)}"><span class="dot ${st||'never'}"></span><span class="n">${esc(b.title.replace(/^Unit · /,''))}</span><span class="m">${esc(hl)}</span></div>`}).join('')}).join('')}
/* ---- detail ---- */
function tile(m){const st=m.status||'ok';const share=m.share==null?null:Math.max(0,Math.min(1,m.share));
  return `<div class="tile"><div class="l" title="${esc(m.label)}">${esc(m.label)}</div><div class="v ${st==='ok'?'':st}">${esc(m.value)}${m.unit?`<small>${esc(m.unit)}</small>`:''}</div>`+
    (share==null?'':`<div class="bar"><i class="${st}" style="width:${(share*100).toFixed(1)}%"></i>${m.ceiling!=null?'<em></em>':''}</div>`)+
    (m.note?`<div class="c ${st==='bad'?'bad':''}" title="${esc(m.note)}">${esc(m.note)}</div>`:'')+`</div>`}
function renderDetail(){const el=document.getElementById('detail');
  /* The review panel's render cache is for the review panel only: any other
     panel replaces the DOM, so the cache must go with it (review 2026-09-07). */
  if(selTest!=='review')delete el.dataset.rvhtml;
  if(!selTest){el.innerHTML='<div class="empty">Select a row</div>';return}
  if(selTest==='review'){renderReview();return}
  const b=B.find(x=>x.id===selTest),r=(S.results||{})[b.id],st=stOf(b.id),d=cache[dkey()],latest=cache[selTest],busy=st==='running'||st==='queued';
  const hist=(latest&&latest.history)||(d&&d.history)||[];
  const viewed=histRun?(hist.find(e=>e.file===histRun)||{}):null;
  let h=`<div class="dwrap"><div class="d-head"><h2>${esc(b.title)}</h2>${chip(histRun?viewed.status:st)}<button class="run" ${busy?'disabled':''} onclick="run('${b.id}')">${st==='running'?'Running…':st==='queued'?'Queued':'Run'}</button></div>`;
  const inputs=d&&d.inputs?` · <b>${esc(d.inputs)}</b>`:'';
  if(histRun)h+=`<div class="meta">run of <b>${esc(viewed.when||'?')}</b> · took ${took(viewed.seconds)}${inputs}</div>`;
  else if(r)h+=`<div class="meta">${busy?'previous run · ':''}<b>${esc(ago(r.when))}</b> · ${esc(r.when)} · took ${took(r.seconds)}${inputs}${busy?' · the tiles update when this run finishes':''}</div>`;
  else h+=`<div class="meta">never run · ~${b.minutes} min${inputs}</div>`;
  if(histRun)h+=`<div class="banner">Viewing an older run. The sidebar and the tiles below describe that run, not the latest.<button onclick="viewRun(null)">Back to latest</button></div>`;
  const metrics=histRun?(d&&d.metrics)||[]:(r&&r.metrics)||[];
  /* A failed verdict always explains itself here — a crash or an XCTest failure leaves every tile green (review 2026-09-02). */
  const verdict=histRun?viewed:r;
  if(verdict&&verdict.status==='fail'&&verdict.summary)h+=`<div class="fails"><b>Failed</b><div>${esc(verdict.summary)}</div></div>`;
  if(metrics.length)h+=`<div class="tiles">`+metrics.map(tile).join('')+`</div>`;
  else if(r&&r.summary&&!(r.status==='fail'))h+=`<p class="d-desc">${esc(r.summary)}</p>`;
  const nclips=(latest&&latest.clips&&latest.clips.length)||(d&&d.clips&&d.clips.length)||0;
  h+=`<div class="tabs">`+[['results','Results'],['history','History'+(hist.length?' · '+hist.length:'')],['about','About'],['audio','Audio'+(nclips?' · '+nclips:'')]].filter(t=>t[0]!=='audio'||nclips).map(t=>`<span class="${tab===t[0]?'on':''}" onclick="setTab('${t[0]}')">${t[1]}</span>`).join('')+`</div>`;
  if(!d){h+=`<div class="d-inputs">loading…</div>`}
  else if(tab==='results'&&live&&!histRun){
    /* Live run: the previous run's structure with every mark cleared, filled back in as suites and cases finish. */
    const isUnit=b.id.startsWith('unit')||b.id==='long_probe';
    if(live.queued)h+=`<div class="livehead"><span>Queued — the marks come back one by one once it starts.</span></div>`;
    if(isUnit){
      const ls=Object.fromEntries((live.suites||[]).map(s=>[s.name,s]));
      const names=[...new Set([...(live.inventory||[]),...Object.keys(ls)])].sort();  // what will run, not what last ran
      const done=names.filter(n=>ls[n]&&ls[n].done).length;
      if(!live.queued)h+=`<div class="livehead"><span>Running · ${done} of ${names.length} suites finished</span><div class="prog"><i style="width:${names.length?(100*done/names.length).toFixed(0):0}%"></i></div></div>`;
      h+=`<div class="suites">`+names.map(n=>{const s=ls[n],open=openSuites.has(n);
        const st=!s?'pend':s.done?(s.failures?'bad':'ok'):'run';
        const mark={pend:'○',run:'◐',ok:'✓',bad:'✗'}[st],cls={pend:'pendc',run:'runc',ok:'okc',bad:'badc'}[st];
        const count=s&&s.done?`${s.tests} tests${s.failures?' · '+s.failures+' FAILED':''}${s.skipped?' · '+s.skipped+' skipped':''}`:st==='run'?'running…':'';
        let row=`<div class="srow ${st==='bad'?'failed':''}" onclick="toggleSuite('${n}')"><span class="smark ${cls}">${mark}</span><span class="sname">${esc(n)}</span><span class="mono scount">${count}</span><span class="schev">${open?'▾':'▸'}</span></div>`;
        if(open){const lc=Object.fromEntries(((live.cases||{})[n]||[]).map(c=>[c.name,c.status])),sc=suiteCache[skey(n)];
          const cnames=[...new Set([...((sc&&sc.inventory)||[]),...Object.keys(lc)])].sort();  // the source's cases, not the last log's
          row+=`<div class="sbody">`+(cnames.length?cnames.map(c=>{const cs=lc[c];const cm=cs==='failed'?'✗':cs==='passed'?'✓':cs==='skipped'?'–':'○',cc=cs==='failed'?'badc':cs==='passed'?'okc':cs==='skipped'?'skc':'pendc';
            return `<div class="scase" title="${esc(c)}"><span class="smark ${cc}">${cm}</span><span>${esc(human(c))}</span></div>`}).join(''):'<div class="scase">waiting for the first case…</div>')+`</div>`}
        return row}).join('')+`</div>`;
    }else{
      if(!live.queued)h+=`<div class="livehead"><span>Running — result lines appear as the bench emits them</span></div>`;
      h+=live.lines&&live.lines.length?`<pre class="d-lines">${live.lines.map(esc).join(NL)}</pre>`:(live.queued?'':`<div class="d-inputs">Waiting for the first result line…</div>`);
    }
  }
  else if(tab==='results'){
    if(d.gone)h+=`<div class="d-inputs">This run's log is no longer archived (pruned after 30 runs).</div>`;
    else if(d.suites&&d.suites.length){
      const failing=d.suites.filter(s=>s.failures);
      if(failing.length)h+=`<div class="fails"><b>${failing.reduce((a,s)=>a+s.failures,0)} failing case(s)</b>`+(d.lines||[]).filter(l=>l.includes('FAILED:')).map(l=>`<div>${esc(l.trim())}</div>`).join('')+`</div>`;
      const ordered=[...failing,...d.suites.filter(s=>!s.failures)];
      h+=`<div class="suites">`+ordered.map(su=>{const open=openSuites.has(su.name),sc=suiteCache[skey(su.name)];
        let row=`<div class="srow ${su.failures?'failed':''}" onclick="toggleSuite('${su.name}')"><span class="smark ${su.failures?'badc':'okc'}">${su.failures?'✗':'✓'}</span><span class="sname">${esc(su.name)}</span><span class="mono scount">${su.tests} tests${su.failures?' · '+su.failures+' FAILED':''}${su.skipped?' · '+su.skipped+' skipped':''}</span><span class="schev">${open?'▾':'▸'}</span></div>`;
        if(open)row+=`<div class="sbody">`+(sc&&sc.error?`<div class="d-inputs">${esc(sc.error)}</div>`:sc?((sc.doc?`<p class="sdoc">${esc(sc.doc)}</p>`:'')+(sc.cases.length?sc.cases.map(c=>
          `<div class="scase" title="${esc(c.name)}"><span class="smark ${c.status==='failed'?'badc':c.status==='skipped'?'skc':'okc'}">${c.status==='failed'?'✗':c.status==='skipped'?'–':'✓'}</span><span>${esc(human(c.name))}</span><span class="mono sms">${c.secs?c.secs+' s':''}</span></div>`).join(''):'<div class="scase">no cases in this run</div>')):'loading…')+`</div>`;
        return row}).join('')+`</div>`}
    else h+=d.lines&&d.lines.length?`<pre class="d-lines">${d.lines.map(esc).join(NL)}</pre>`:`<div class="d-inputs">No per-case detail yet — run it once.</div>`;
  }else if(tab==='history'){
    h+=hist.length?`<div class="hist">`+hist.map((e,i)=>{const sel=histRun?histRun===e.file:i===0;const openable=i===0||!!e.file;
      return `<div class="hrow ${sel?'sel':''} ${openable?'':'dead'}" ${openable?`onclick="viewRun(${i===0?'null':"'"+e.file+"'"})"`:''}><span class="mono hwhen">${esc(e.when)}</span>${chip(e.status)}<span class="hsum">${esc(e.summary)}${e.file||i===0?'':' · log not archived'}</span><span class="mono htook">${took(e.seconds)}</span></div>`}).join('')+`</div><div class="d-inputs" style="margin-top:8px">Every run is kept with its date. Click one to see its results.</div>`
      :`<div class="d-inputs">No runs recorded yet.</div>`;
  }else if(tab==='about'){
    h+=`<div class="sec">What this tests</div><p class="d-desc">${esc(d.description)}</p><p class="d-inputs">${esc(d.inputs)}</p><div class="sec">Command</div><div class="cmd">${esc(d.command)}</div><div class="sec">Row id</div><div class="d-inputs mono">${esc(b.id)} · ~${b.minutes} min</div>`;
  }else if(tab==='audio'){
    h+=`<div class="clips">`+(d.clips||[]).map(c=>`<div class="clip" data-url="${esc(c.url)}" data-secs="${c.secs||0}"><button class="play" onclick="playClip('${esc(c.url)}')">▶</button><span class="cname">${esc(c.name)}</span><div class="pbar"><i></i></div><span class="ct">0:00 / ${fmt(c.secs)}</span></div>`).join('')+`</div>`;
  }
  if(S.running||(S.queue||[]).length)h+=`<div class="sec">Runner log · ${esc(S.running||'')}</div><pre id="log">${esc(S.log||'')}</pre>`;
  h+=`</div>`;el.innerHTML=h;syncPlayer();
}
function renderAll(){renderTree();renderDetail()}
async function pickTest(id){stopAudio();selTest=id;histRun=null;openSuites.clear();if(tab==='audio')tab='results';history.replaceState(null,'','?t='+id+'&tab='+tab);renderAll();if(id==='review'){await fetchReview();renderAll();return}fetchDetail();
  const el=document.querySelector('.row.sel');if(el)el.scrollIntoView({block:'nearest'})}
async function poll(){try{S=await (await fetch('/status')).json()}catch(e){return}
  if(selTest&&cache[selTest]&&cache[selTest].command){const r=(S.results||{})[selTest];
    if(r&&cache[selTest]._when!==r.when){delete cache[selTest];Object.keys(suiteCache).forEach(k=>{if(k.split('|')[0]===selTest&&k.split('|').length===2)delete suiteCache[k]});await fetchKey(selTest)}}
  await fetchLive();if(selTest==='review'&&!(document.activeElement&&document.activeElement.id==='ref'))await fetchReview();renderAll()}
async function run(id){await fetch('/run?id='+id,{method:'POST',headers:{'X-Reed-QA':'1'}});poll()}
async function runGroup(g){for(const b of B)if(b.group===g)await fetch('/run?id='+b.id,{method:'POST',headers:{'X-Reed-QA':'1'}});poll()}
async function runAll(){for(const b of B)await fetch('/run?id='+b.id,{method:'POST',headers:{'X-Reed-QA':'1'}});poll()}
document.addEventListener('keydown',e=>{if(e.target.tagName==='INPUT'||e.metaKey||e.ctrlKey||e.altKey)return;
  const i=B.findIndex(b=>b.id===selTest);
  if(e.key==='ArrowDown'&&i<B.length-1){pickTest(B[i+1].id);e.preventDefault()}
  else if(e.key==='ArrowUp'&&i>0){pickTest(B[i-1].id);e.preventDefault()}
  else if(e.key==='r'||e.key==='R'){if(selTest&&!['running','queued'].includes(stOf(selTest)))run(selTest)}
  else if(e.key>='1'&&e.key<='4'){const t=['results','history','about','audio'][+e.key-1];
    const c=cache[selTest];if(t==='audio'&&!(c&&c.clips&&c.clips.length))return;  // no Audio tab on rows without clips (review 2026-09-02)
    if(t)setTab(t)}});
renderAll();pickTest(selTest).then(()=>{const c=q.get('copy');if(selTest==='review'&&c)openCopy(c)});poll();setInterval(poll,3000);
</script></body></html>"""

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # WebKit aborts HTTP/1.0 media streams mid-play
    def log_message(self, *a): pass
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        try:
            self._get()
        except Exception as ex:
            try: self._send(500, f"internal error: {ex}", "text/plain")
            except Exception: pass

    def _get(self):
        u = urlparse(self.path)
        if "\x00" in u.path or "\x00" in (u.query or ""):
            self._send(400, "bad request", "text/plain"); return
        if u.path == "/":
            meta = [{"id": b[0], "title": b[1], "group": b[2], "minutes": b[5]} for b in BENCHES]
            self._send(200, PAGE.replace("__BENCHES__", json.dumps(meta)).replace("__TOTAL_MIN__", str(sum(b[5] for b in BENCHES))))
        elif u.path == "/status":
            with lock: self._send(200, json.dumps(state), "application/json")
        elif u.path == "/review":
            # The Local review panel (P16): the developer's opt-in state, the
            # copies on disk, and the list — read straight from the app's directory.
            try: self._send(200, json.dumps({"state": local_review.state(), "copies": local_review.listing()}), "application/json")
            except OSError as ex: self._send(500, str(ex), "text/plain")
        elif u.path == "/review/audio":
            # A copy's recording for the review pane's player (2026-09-06):
            # the same id validation as /review/copy, bytes only, never listed.
            cid = parse_qs(u.query).get("id", [""])[0]
            try:
                path = local_review.audio_path(cid)
                if path is None: self._send(404, "no recording for this copy", "text/plain"); return
                self._send_wav(str(path))   # ranges, like the bench clips: a player seeks
            except ValueError as ex: self._send(400, str(ex), "text/plain")
        elif u.path == "/review/copy":
            cid = parse_qs(u.query).get("id", [""])[0]
            try:
                rec = local_review.load(cid)
                self._send(200, json.dumps({"id": cid, "record": rec, "heard": local_review.heard(rec),
                                            "chunkLines": local_review.chunk_lines(rec)}), "application/json")
            except ValueError as ex: self._send(400, str(ex), "text/plain")
            except FileNotFoundError: self._send(404, "no such copy", "text/plain")
        elif u.path == "/detail":
            bid = parse_qs(u.query).get("id", [""])[0]
            if bid not in BY_ID: self._send(400, "unknown bench", "text/plain"); return
            _, title, _, spec, _, _ = BY_ID[bid]
            desc, inputs = DESCRIPTIONS.get(bid, ("", ""))
            cmd = " ".join(f"{k}={v}" for k, v in spec["env"].items()) + " " + " ".join(spec["cmd"])
            run = parse_qs(u.query).get("run", [""])[0]
            src = os.path.join(OUT, f"{bid}.txt")
            if run:
                if "/" in run or not run.startswith(bid + "-") or not run.endswith(".txt"):
                    self._send(400, "bad run", "text/plain"); return
                src = os.path.join(HIST_DIR, run)
            with lock: hist = list(state["history"].get(bid, []))
            gone = bool(run) and not os.path.isfile(src)
            suites = unit_suite_rows(src) if bid.startswith("unit") else []
            if bid.startswith("unit") and not suites and os.path.isfile(src):
                tail = open(src, errors="replace").read().splitlines()
                det = ["(no test suites ran — raw log tail:)"] + tail[-25:]
            else:
                det = [] if bid.startswith("unit") else detail_lines(bid, src)
            with lock: stored = state["results"].get(bid, {}).get("metrics")
            metrics = (metrics_for(bid, src) if os.path.isfile(src) else []) if run else (stored if stored is not None else metrics_for(bid, src))
            self._send(200, json.dumps({"description": desc, "inputs": inputs, "command": cmd.strip(),
                                        "clips": clip_list(bid), "history": hist, "viewing": run, "gone": gone,
                                        "suites": suites, "lines": det, "metrics": metrics}), "application/json")
        elif u.path == "/progress":
            bid = parse_qs(u.query).get("id", [""])[0]
            if bid not in BY_ID: self._send(400, "unknown bench", "text/plain"); return
            self._send(200, json.dumps(progress_for(bid)), "application/json")
        elif u.path == "/suite":
            q = parse_qs(u.query)
            bid = q.get("id", [""])[0]; name = q.get("name", [""])[0]; run = q.get("run", [""])[0]
            if bid not in BY_ID or not re.fullmatch(r"\w+", name or ""):
                self._send(400, "bad request", "text/plain"); return
            src = os.path.join(OUT, f"{bid}.txt")
            if run:
                if "/" in run or not run.startswith(bid + "-") or not run.endswith(".txt"):
                    self._send(400, "bad run", "text/plain"); return
                src = os.path.join(HIST_DIR, run)
            self._send(200, json.dumps({"name": name, "doc": suite_doc(name), "cases": suite_cases(src, name),
                                        "inventory": case_inventory(bid, name)}), "application/json")
        elif u.path == "/audio":
            rel = parse_qs(u.query).get("f", [""])[0]
            fp = os.path.realpath(os.path.join(ROOT, rel))
            if not fp.startswith(os.path.realpath(os.path.join(ROOT, "voice-tests")) + os.sep) or not fp.endswith(".wav") or not os.path.isfile(fp):
                self._send(404, "not found", "text/plain"); return
            self._send_wav(fp)
        else: self._send(404, "not found", "text/plain")
    def _send_wav(self, fp):
        """One WAV sender for the bench clips and the review recordings:
        honours a single byte range (206), answers 416 for an empty one, and
        falls back to the whole file (200) for a malformed or multi-range
        request, per RFC 9110. Players seek with ranges."""
        size = os.path.getsize(fp)
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        if rng:
            try:
                if not rng.startswith("bytes=") or "," in rng: raise ValueError(rng)
                a, _, b = rng[6:].partition("-")
                start = int(a) if a else max(0, size - int(b))
                if a and b: end = min(int(b), size - 1)
            except ValueError:
                rng = None; start, end = 0, size - 1
            if rng and (start > end or start >= size):
                self.send_response(416); self.send_header("Content-Range", f"bytes */{size}"); self.send_header("Content-Length", "0"); self.end_headers(); return
        with open(fp, "rb") as f:
            f.seek(start); data = f.read(end - start + 1)
        self.send_response(206 if rng else 200)
        self.send_header("Content-Type", "audio/wav"); self.send_header("Accept-Ranges", "bytes")
        if rng: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except BrokenPipeError: pass
    def do_POST(self):
        if self.headers.get("X-Reed-QA") != "1":
            self._send(403, "missing X-Reed-QA header", "text/plain"); return
        u = urlparse(self.path)
        if u.path == "/run":
            bid = parse_qs(u.query).get("id", [""])[0]
            if bid in BY_ID:
                with lock:
                    if bid != state["running"] and bid not in state["queue"]: state["queue"].append(bid)
                self._send(200, "queued", "text/plain")
            else: self._send(400, "unknown bench", "text/plain")
        elif u.path == "/review/reference":
            # A human's reference for one copy (P16): written into the copy in
            # place; the typed text is never overwritten and the app's expiry
            # clock (creation time) is untouched.
            cid = parse_qs(u.query).get("id", [""])[0]
            try:
                body = json.loads(self._body() or b"{}")
                text = body.get("text")
                if not isinstance(text, str) or not text.strip(): self._send(400, "reference text required", "text/plain"); return
                ref = local_review.save_reference(cid, text.strip(), bool(body.get("edited")))
                self._send(200, json.dumps(ref), "application/json")
            except ValueError as ex: self._send(400, str(ex), "text/plain")
            except FileNotFoundError: self._send(404, "no such copy", "text/plain")
        elif u.path == "/review/delete":
            self._send(200, json.dumps(local_review.delete_all()), "application/json")
        else: self._send(404, "not found", "text/plain")

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    os.makedirs(OUT, exist_ok=True); load_state(); sweep_interrupted(); reconcile_results()
    threading.Thread(target=worker, daemon=True).start()
    print(f"Reed QA at http://localhost:{PORT}  (results in {OUT})")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
