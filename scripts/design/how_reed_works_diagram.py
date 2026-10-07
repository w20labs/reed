"""Generate docs/media/how-reed-works.svg, the README's animated, CSS-only pipeline diagram.

Usage: python3 scripts/design/how_reed_works_diagram.py docs/media/how-reed-works.svg

One 10 s loop; every animation shares it and is timed by keyframe percentages,
so a global negative animation-delay previews any moment.
"""
import random
import sys

DUR = 10
random.seed(7)
out = []
css = []


def pct(t):
    return f"{t * 100:.2f}%"


def keyframes(name, frames):
    """frames: list of (t in 0..1, css body)."""
    body = " ".join(f"{pct(t)}{{{b}}}" for t, b in frames)
    css.append(f"@keyframes {name}{{{body}}}")


def anim(cls, name, extra=""):
    css.append(f".{cls}{{animation:{name} {DUR}s linear infinite;{extra}}}")


def opacity_windows(name, windows, fade=0.01):
    frames = [(0, "opacity:0")]
    for a, b in windows:
        frames += [(max(a - fade, 0), "opacity:0"), (a, "opacity:1"), (b, "opacity:1"), (min(b + fade, 1), "opacity:0")]
    frames.append((1, "opacity:0"))
    keyframes(name, sorted(frames, key=lambda f: f[0]))


# ---- timeline (fractions of the loop) ----
PRESS, RELEASE = 0.05, 0.55
SPEECH = [(0.05, 0.20), (0.30, 0.52)]
SEAL1 = 0.27  # pause after segment 1 → sealed while still holding
TYPE_A, TYPE_B = 0.86, 0.95

# ---- geometry ----
W, H = 960, 500
ROW1, ROW1H = 96, 92
ROW2, ROW2H = 238, 110
LANE = ROW2 + ROW2H - 15
FIELD_Y, FIELD_H = 380, 64
C1 = (48, 200)
C2 = (272, 270)
C3 = (566, 346)


def cx(c):
    return c[0] + c[1] / 2


START = (C3[0] + C3[1] - 34, ROW1 + 78)
PATH = [START, (START[0], 214), (cx(C1), 214), (cx(C1), LANE), (cx(C2), LANE), (cx(C3), LANE), (cx(C3), FIELD_Y - 6)]
STOPS = {"denoise": 3, "recognize": 4, "cleanup": 5, "field": 6}


def seg_len(a, b):
    return abs(a[0] - b[0]) + abs(a[1] - b[1])


def chip_frames(schedule):
    """schedule: [(t, path index)] — the chip is at that vertex at time t, moving
    linearly (by length) between consecutive vertices."""
    frames = []
    for (t0, i0), (t1, i1) in zip(schedule, schedule[1:]):
        if i0 == i1:
            frames.append((t0, PATH[i0]))
            continue
        total = sum(seg_len(PATH[k], PATH[k + 1]) for k in range(i0, i1))
        acc = 0
        frames.append((t0, PATH[i0]))
        for k in range(i0, i1):
            acc += seg_len(PATH[k], PATH[k + 1])
            frames.append((t0 + (t1 - t0) * acc / total, PATH[k + 1]))
    frames.append((schedule[-1][0], PATH[schedule[-1][1]]))
    frames = [(0, PATH[0])] + frames + [(1, PATH[-1])]
    seen, uniq = set(), []
    for t, p in frames:
        if round(t, 4) not in seen:
            seen.add(round(t, 4))
            uniq.append((t, p))
    return uniq


CHIPS = {
    "1": [(SEAL1, 0), (0.40, 3), (0.45, 3), (0.50, 4), (0.56, 4), (0.62, 5), (0.82, 5), (0.86, 6)],
    "2": [(RELEASE, 0), (0.62, 3), (0.65, 3), (0.68, 4), (0.71, 4), (0.74, 5), (0.82, 5), (0.86, 6)],
}
ACTIVE = {
    "denoise": [(0.40, 0.45), (0.62, 0.65)],
    "recognize": [(0.50, 0.56), (0.68, 0.71)],
    "cleanup": [(0.62, 0.67), (0.74, 0.79)],
    "hold": [(PRESS, RELEASE)],
    "record": [(PRESS, RELEASE)],
    "split": [(SEAL1 - 0.01, SEAL1 + 0.04), (RELEASE - 0.01, RELEASE + 0.04)],
    "field": [(0.85, 0.96)],
}

# ---- style ----
css.append("""
svg{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
--bg:#faf9f7;--card:#fff;--line:#e2dfda;--ink:#26262a;--dim:#5c5c63;--accent:#2b7a53;--soft:#e2f1e8;--on:#fff}
@media (prefers-color-scheme:dark){svg{--bg:#18181b;--card:#232327;--line:#3a3a41;--ink:#f1f1f3;--dim:#b2b2b9;--accent:#5dc795;--soft:#1d382b;--on:#0f2419}}
.bg{fill:var(--bg)} .card{fill:var(--card);stroke:var(--line);stroke-width:1}
.mac{fill:none;stroke:var(--line);stroke-width:1.5;stroke-dasharray:6 6}
.t{fill:var(--ink);font-size:15px;font-weight:650} .s{fill:var(--dim);font-size:12.5px}
.n{fill:var(--accent);font-size:11px;font-weight:700;letter-spacing:.08em}
.h{fill:var(--ink);font-size:21px;font-weight:700;letter-spacing:-.01em}
.wire{fill:none;stroke:var(--line);stroke-width:2;stroke-linejoin:round}
.hi{fill:none;stroke:var(--accent);stroke-width:2;opacity:0}
.key{fill:var(--card);stroke:var(--line)} .keydown{fill:var(--accent);opacity:0}
.kt{fill:var(--ink);font-size:17px;text-anchor:middle} .kt2{fill:var(--on);font-size:17px;text-anchor:middle;opacity:0}
.bar{fill:var(--accent);transform-box:fill-box;transform-origin:center;transform:scaleY(.12)}
.chip rect{fill:var(--accent)} .chip text{fill:var(--on);font-size:10.5px;font-weight:700;text-anchor:middle}
.chip{opacity:0}
.cap{fill:var(--dim);font-size:12.5px;font-style:italic;opacity:0}
.track{fill:var(--soft)} .fill{fill:var(--accent);transform-box:fill-box;transform-origin:left;transform:scaleX(1);opacity:.55}
.cut{stroke:var(--ink);stroke-width:2;opacity:1}
.typed{fill:var(--ink);font-size:17px;font-weight:500}
.cover{fill:var(--card);transform:translateX(440px)} .caret{fill:var(--accent);transform:translateX(440px);opacity:0}
.st-hold{opacity:0} .st-rel{opacity:1}
""")

# ---- body ----
def card(key, x, y, w, h):
    out.append(f'<rect class="card" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
    out.append(f'<rect class="hi hi-{key}" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')


out.append(f'<rect class="bg" width="{W}" height="{H}" rx="16"/>')
out.append('<text class="h" x="40" y="44">How Reed turns your voice into text</text>')
out.append(f'<text class="s" x="{W - 40}" y="44" text-anchor="end">Hold, speak, release. Everything runs on your Mac.</text>')
out.append(f'<rect class="mac" x="24" y="64" width="{W - 48}" height="{H - 84}" rx="14"/>')

# wire behind cards
d = "M" + " L".join(f"{x:.0f},{y:.0f}" for x, y in PATH)
out.append(f'<path class="wire" d="{d}"/>')

# row 1
card("hold", C1[0], ROW1, C1[1], ROW1H)
out.append(f'<text class="n" x="{C1[0] + 16}" y="{ROW1 + 22}">1 · HOLD</text>')
out.append(f'<text class="t" x="{C1[0] + 16}" y="{ROW1 + 42}">Your shortcut</text>')
for i, glyph in enumerate(["⌃", "⌥"]):
    kx = C1[0] + 16 + i * 42
    out.append(f'<rect class="key" x="{kx}" y="{ROW1 + 52}" width="34" height="30" rx="7"/>')
    out.append(f'<rect class="keydown" x="{kx}" y="{ROW1 + 52}" width="34" height="30" rx="7"/>')
    out.append(f'<text class="kt" x="{kx + 17}" y="{ROW1 + 73}">{glyph}</text>')
    out.append(f'<text class="kt2" x="{kx + 17}" y="{ROW1 + 73}">{glyph}</text>')
out.append(f'<text class="s st-hold" x="{C1[0] + 110}" y="{ROW1 + 72}">holding</text>')
out.append(f'<text class="s st-rel" x="{C1[0] + 110}" y="{ROW1 + 72}">released</text>')

card("record", C2[0], ROW1, C2[1], ROW1H)
out.append(f'<text class="n" x="{C2[0] + 16}" y="{ROW1 + 22}">2 · RECORD</text>')
out.append(f'<text class="t" x="{C2[0] + 16}" y="{ROW1 + 42}">Microphone</text>')
NB = 29
for i in range(NB):
    bx = C2[0] + 16 + i * 8.4
    out.append(f'<rect class="bar b{i}" x="{bx:.1f}" y="{ROW1 + 50}" width="4" height="22" rx="2"/>')
    frames = [(0, "transform:scaleY(.12)")]
    for a, b in SPEECH:
        frames.append((a, "transform:scaleY(.12)"))
        t = a + 0.012
        while t < b - 0.01:
            frames.append((t, f"transform:scaleY({random.uniform(0.2, 1):.2f})"))
            t += 0.018
        frames.append((b, "transform:scaleY(.12)"))
    frames.append((1, "transform:scaleY(.12)"))
    keyframes(f"bar{i}", frames)
    anim(f"b{i}", f"bar{i}")
out.append(f'<text class="cap cap1" x="{C2[0] + 16}" y="{ROW1 + 84}">“um so let\'s meet on Thursday”</text>')
out.append(f'<text class="cap cap2" x="{C2[0] + 16}" y="{ROW1 + 84}">“uh after lunch”</text>')

card("split", C3[0], ROW1, C3[1], ROW1H)
out.append(f'<text class="n" x="{C3[0] + 16}" y="{ROW1 + 22}">3 · SPLIT AT PAUSES</text>')
out.append(f'<text class="t" x="{C3[0] + 16}" y="{ROW1 + 42}">Work starts while you talk</text>')
out.append(f'<text class="s" x="{C3[0] + 16}" y="{ROW1 + 60}">Each pause seals a segment and sends it on.</text>')
TX, TW = C3[0] + 16, C3[1] - 72
out.append(f'<rect class="track" x="{TX}" y="{ROW1 + 74}" width="{TW}" height="8" rx="4"/>')
out.append(f'<rect class="fill" x="{TX}" y="{ROW1 + 74}" width="{TW}" height="8" rx="4"/>')
CUTX = TX + TW * (SEAL1 - PRESS) / (RELEASE - PRESS)
out.append(f'<line class="cut cut1" x1="{CUTX:.1f}" x2="{CUTX:.1f}" y1="{ROW1 + 70}" y2="{ROW1 + 86}"/>')
out.append(f'<line class="cut cut2" x1="{TX + TW}" x2="{TX + TW}" y1="{ROW1 + 70}" y2="{ROW1 + 86}"/>')

# row 2
C4, C5, C6 = C1, C2, C3
card("denoise", C4[0], ROW2, C4[1], ROW2H)
out.append(f'<text class="n" x="{C4[0] + 16}" y="{ROW2 + 22}">4 · DENOISE</text>')
out.append(f'<text class="t" x="{C4[0] + 16}" y="{ROW2 + 42}">Cut background noise</text>')
out.append(f'<text class="s" x="{C4[0] + 16}" y="{ROW2 + 60}">FastEnhancer, on device</text>')
card("recognize", C5[0], ROW2, C5[1], ROW2H)
out.append(f'<text class="n" x="{C5[0] + 16}" y="{ROW2 + 22}">5 · RECOGNIZE</text>')
out.append(f'<text class="t" x="{C5[0] + 16}" y="{ROW2 + 42}">Speech to words</text>')
out.append(f'<text class="s" x="{C5[0] + 16}" y="{ROW2 + 60}">Parakeet v3 on the Neural Engine</text>')
card("cleanup", C6[0], ROW2, C6[1], ROW2H)
out.append(f'<text class="n" x="{C6[0] + 16}" y="{ROW2 + 22}">6 · CLEAN UP</text>')
out.append(f'<text class="t" x="{C6[0] + 16}" y="{ROW2 + 42}">Drop the ums, fix the punctuation</text>')
out.append(f'<text class="s" x="{C6[0] + 16}" y="{ROW2 + 60}">Rules first, then Apple Intelligence if needed.</text>')
out.append(f'<text class="s" x="{C6[0] + 16}" y="{ROW2 + 76}">AI edits are checked word by word.</text>')

# row 3: the destination field
FX, FW = 48, W - 96
card("field", FX, FIELD_Y, FW, FIELD_H)
out.append(f'<text class="n" x="{FX + 16}" y="{FIELD_Y + 22}">7 · TYPE AT YOUR CURSOR</text>')
out.append(f'<text class="s" x="{FX + FW - 16}" y="{FIELD_Y + 22}" text-anchor="end">In any app: Mail, Slack, Notes, your editor…</text>')
out.append(f'<clipPath id="fieldclip"><rect x="{FX + 8}" y="{FIELD_Y + 28}" width="{FW - 16}" height="30"/></clipPath>')
out.append('<g clip-path="url(#fieldclip)">')
out.append(f'<text class="typed" x="{FX + 16}" y="{FIELD_Y + 50}">So let\'s meet on Thursday after lunch.</text>')
out.append(f'<rect class="cover" x="{FX + 14}" y="{FIELD_Y + 30}" width="{FW - 30}" height="28"/>')
out.append(f'<rect class="caret" x="{FX + 14}" y="{FIELD_Y + 34}" width="2" height="21" rx="1"/>')
out.append("</g>")

out.append(f'<text class="s" x="40" y="{H - 28}">No audio, transcript or network request leaves your Mac during dictation.</text>')

# chips on top
for label in CHIPS:
    out.append(f'<g class="chip chip{label}"><g class="mv mv{label}"><rect x="-13" y="-9" width="26" height="18" rx="9"/><text y="4">{label}</text></g></g>')

# ---- animations ----
for key, wins in ACTIVE.items():
    opacity_windows(f"hi-{key}", wins)
    anim(f"hi-{key}", f"hi-{key}")

opacity_windows("down", [(PRESS, RELEASE)], fade=0.004)
for cls in ("keydown", "kt2", "st-hold"):
    anim(cls, "down")
keyframes("rel", [(0, "opacity:1"), (PRESS - 0.004, "opacity:1"), (PRESS, "opacity:0"), (RELEASE, "opacity:0"), (RELEASE + 0.004, "opacity:1"), (1, "opacity:1")])
anim("st-rel", "rel")

opacity_windows("cap1", [(SPEECH[0][0], SEAL1)])
anim("cap1", "cap1")
opacity_windows("cap2", [(SPEECH[1][0], RELEASE + 0.02)])
anim("cap2", "cap2")

keyframes("fill", [(0, "transform:scaleX(0)"), (PRESS, "transform:scaleX(0)"), (RELEASE, "transform:scaleX(1)"), (0.97, "transform:scaleX(1)"), (1, "transform:scaleX(0)")])
anim("fill", "fill")
keyframes("cut1", [(0, "opacity:0"), (SEAL1 - 0.002, "opacity:0"), (SEAL1, "opacity:1"), (0.97, "opacity:1"), (1, "opacity:0")])
anim("cut1", "cut1")
keyframes("cut2", [(0, "opacity:0"), (RELEASE - 0.002, "opacity:0"), (RELEASE, "opacity:1"), (0.97, "opacity:1"), (1, "opacity:0")])
anim("cut2", "cut2")

for label, sched in CHIPS.items():
    frames = chip_frames(sched)
    keyframes(f"mv{label}", [(t, f"transform:translate({x:.0f}px,{y:.0f}px)") for t, (x, y) in frames])
    anim(f"mv{label}", f"mv{label}")
    start = sched[0][0]
    opacity_windows(f"chip{label}", [(start, sched[-1][0])], fade=0.006)
    anim(f"chip{label}", f"chip{label}")
# offset the second chip so the two sit side by side while they wait in order
css.append(".chip2{transform:translateX(30px)}")

shift = "transform:translateX({}px)"
keyframes("type", [(0, shift.format(0)), (TYPE_A, shift.format(0)), (TYPE_B, shift.format(304)), (1, shift.format(304))])
anim("cover", "type")
keyframes("caret", [(0, "opacity:0;" + shift.format(0)), (TYPE_A - 0.01, "opacity:0;" + shift.format(0)),
                    (TYPE_A, "opacity:1;" + shift.format(0)), (TYPE_B, "opacity:1;" + shift.format(297)),
                    (0.985, "opacity:1;" + shift.format(297)), (1, "opacity:0;" + shift.format(297))])
anim("caret", "caret")

css.append("@media (prefers-reduced-motion:reduce){*{animation:none!important}}")

svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
    f'aria-labelledby="title desc">\n'
    '<title id="title">How Reed works</title>\n'
    '<desc id="desc">Hold the shortcut and speak. Reed records, splits the recording at pauses, and sends each '
    'segment through on-device denoising, Parakeet v3 speech recognition and cleanup while you keep talking. '
    'On release the segments are joined in order and typed at your cursor. Nothing leaves the Mac.</desc>\n'
    f"<style>{''.join(css)}</style>\n" + "\n".join(out) + "\n</svg>\n"
)
open(sys.argv[1], "w").write(svg)
print(len(svg), "bytes")
