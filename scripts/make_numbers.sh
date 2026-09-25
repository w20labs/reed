#!/usr/bin/env bash
# Synthesize the ITN corpus (finding 3, 2026-08-29): spoken amounts, dates,
# times, phone numbers, versions, ordinals, percentages, as a dictating
# person says them. voice-tests/numbers/NN.wav + numbers_ref.json (gitignored
# with the corpus). macOS `say` + afconvert, canonical 44-byte header.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=voice-tests/numbers; mkdir -p "$OUT"
python3 - "$OUT" <<'PY'
import json, subprocess, struct, sys, os
out = sys.argv[1]
cases = [
 ("The invoice total is three thousand one hundred and sixty two dollars.", "The invoice total is $3,162."),
 ("It's due on the fifteenth of March at nine thirty in the morning.", "It's due on the 15th of March at 9:30 in the morning."),
 ("Let's meet at three o'clock, or half past four if the review runs long.", "Let's meet at 3 o'clock, or 4:30 if the review runs long."),
 ("The cost should be around fifteen pounds fifty, roughly twenty dollars.", "The cost should be around £15.50, roughly $20."),
 ("Call me back on five five five, zero one two, three four five six.", "Call me back on 555-012-3456."),
 ("We shipped version two point three point one on Tuesday.", "We shipped version 2.3.1 on Tuesday."),
 ("Ship the package to twenty two Baker Street, London.", "Ship the package to 22 Baker Street, London."),
 ("About three hundred over the estimate, so roughly seven percent.", "About 300 over the estimate, so roughly 7%."),
 ("The meeting moved from Friday the twelfth to Wednesday the seventeenth.", "The meeting moved from Friday the 12th to Wednesday the 17th."),
 ("There were two hundred and fifty participants and twelve speakers.", "There were 250 participants and 12 speakers."),
 ("My flight lands at eleven forty five p m on the third.", "My flight lands at 11:45 PM on the 3rd."),
 ("The budget is one point two million for the first half of twenty twenty six.", "The budget is 1.2 million for the first half of 2026."),
 ("Add two avocados, a dozen bananas and one bag of coffee beans.", "Add two avocados, a dozen bananas and one bag of coffee beans."),
 ("The deployment finished around eleven last night and phase two starts Monday.", "The deployment finished around 11 last night and phase 2 starts Monday."),
 ("I need five minutes, maybe ten, before the one on one.", "I need five minutes, maybe 10, before the one-on-one."),
 ("Room four oh two, second floor, extension one one nine.", "Room 402, second floor, extension 119."),
]
ref = []
for i, (spoken, clean) in enumerate(cases, 1):
    id_ = f"{i:02d}"
    subprocess.run(["say", "-v", "Samantha", "-r", "175", "-o", "/tmp/reed_num.aiff", spoken], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "/tmp/reed_num.aiff", "/tmp/reed_num.wav"], check=True)
    d = open("/tmp/reed_num.wav", "rb").read()
    j = d.find(b"data"); size = struct.unpack("<I", d[j+4:j+8])[0]; pcm = d[j+8:j+8+size]
    hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE" + b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", len(pcm))
    open(os.path.join(out, id_ + ".wav"), "wb").write(hdr + pcm)
    ref.append({"id": id_, "spoken": spoken, "clean": clean, "seconds": round(len(pcm) / 32000, 1)})
json.dump(ref, open(os.path.join(out, "numbers_ref.json"), "w"), indent=2)
print(f"{len(ref)} clips → {out}")
PY
rm -f /tmp/reed_num.aiff /tmp/reed_num.wav
