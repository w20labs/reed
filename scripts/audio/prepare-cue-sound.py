#!/usr/bin/env python3
"""Prepare the dictation cue sound that ships in the app.

Turns legal/asset-sources/cue-source.wav into Resources/Sounds/pop.wav:

  1. trim the trailing silence, keeping 30 ms of tail;
  2. fade the last 10 ms to exact zero, so the file cannot click on playback;
  3. scale to 15% more amplitude than the previous -2.4 dBFS peak
     (about -1.19 dBFS), keeping headroom below clipping;
  4. mono -> stereo, matching the previous file's channel count.

Deterministic: same input, same output bytes. Standard library only.

    python3 scripts/audio/prepare-cue-sound.py          # writes Resources/Sounds/pop.wav
    python3 scripts/audio/prepare-cue-sound.py --check  # verify the tracked file matches

The source keeps its C2PA Content Credentials; this script drops them, because
the WAV it writes carries audio only. Provenance lives in the source file and
in legal/asset-sources/README.md.
"""
from __future__ import annotations

import math
import struct
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "legal/asset-sources/cue-source.wav"
DEST = ROOT / "Resources/Sounds/pop.wav"

TAIL_MS = 30.0
FADE_MS = 10.0
PEAK_DBFS = -2.4 + 20 * math.log10(1.15)


def build(source: Path) -> bytes:
    with wave.open(str(source)) as w:
        channels, rate, frames = w.getnchannels(), w.getframerate(), w.getnframes()
        raw = struct.unpack(f"<{frames * channels}h", w.readframes(frames))
    mono = [sum(raw[i * channels:(i + 1) * channels]) / channels / 32768 for i in range(frames)]

    peak = max(abs(x) for x in mono)
    threshold = peak * 0.005
    last = len(mono) - next(i for i, x in enumerate(reversed(mono)) if abs(x) > threshold)
    mono = mono[:min(len(mono), last + int(TAIL_MS / 1000 * rate))]

    fade = int(FADE_MS / 1000 * rate)
    for i in range(len(mono) - fade, len(mono)):
        mono[i] *= 0.5 * (1 + math.cos(math.pi * (i - (len(mono) - fade)) / fade))

    gain = 10 ** (PEAK_DBFS / 20) / max(abs(x) for x in mono)
    samples = [int(round(max(-1.0, min(1.0, x * gain)) * 32767)) for x in mono]

    import io
    buf = io.BytesIO()
    with wave.open(buf, "wb") as o:
        o.setnchannels(2)
        o.setsampwidth(2)
        o.setframerate(rate)
        o.writeframes(b"".join(struct.pack("<hh", v, v) for v in samples))
    return buf.getvalue()


def main() -> int:
    data = build(SOURCE)
    if "--check" in sys.argv:
        current = DEST.read_bytes()
        if current != data:
            print(f"ERROR: {DEST.relative_to(ROOT)} does not match what this script produces "
                  f"({len(current)} bytes on disk, {len(data)} bytes generated).", file=sys.stderr)
            return 1
        print(f"{DEST.relative_to(ROOT)} matches its source ({len(data)} bytes)")
        return 0
    DEST.write_bytes(data)
    print(f"wrote {DEST.relative_to(ROOT)} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
