#!/usr/bin/env bash
# Synthesize two bench inputs (gitignored with the rest of the corpus):
#   voice-tests/long_runon.wav   ~43 s, one sentence, NO pauses — exercises
#                                the live segmenter's 20 s cap (mid-sentence cuts)
#   voice-tests/long_breaths.wav the same sentence with 900 ms breaths
#                                mid-sentence — exercises pause seals that are
#                                NOT sentence boundaries (field 2026-08-28:
#                                "I think. We should")
# macOS `say` + afconvert; the header is rewritten to the canonical 44 bytes
# (afconvert pads a 4 KB FLLR chunk).
set -euo pipefail
cd "$(dirname "$0")/.."
synth() {
say -v Samantha -r 175 -o /tmp/reed_runon.aiff "$2"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/reed_runon.aiff /tmp/reed_runon.wav
python3 - "$1" <<'PY'
import struct, sys
d = open("/tmp/reed_runon.wav", "rb").read()
i = d.find(b"data"); size = struct.unpack("<I", d[i + 4:i + 8])[0]; pcm = d[i + 8:i + 8 + size]
hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE" + b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", len(pcm))
open(sys.argv[1], "wb").write(hdr + pcm)
print(f"{sys.argv[1]}: {len(pcm) / 32000:.1f} s")
PY
rm -f /tmp/reed_runon.aiff /tmp/reed_runon.wav
}
TEXT="so I was thinking about the launch plan and honestly the more I look at it the more I think we should move the date because the onboarding flow still has that issue where the model download stalls on slow connections and the support team hasn't been trained on the new settings pane yet and marketing wants another week for the video and if we ship on Friday we're going to spend the whole weekend answering emails about the same three problems which nobody wants so my proposal is we push it to the following Wednesday give engineering the extra days to fix the download retry add the tooltip that Dana asked for and run one more round of testing on the older MacBooks that people keep reporting problems with and then we announce it properly with the blog post and the demo video ready to go instead of scrambling at the last minute like we did last time"
synth voice-tests/long_runon.wav "$TEXT"
synth voice-tests/long_breaths.wav "so I was thinking about the launch plan and honestly the more I look at it the more I think [[slnc 900]] we should move the date because the onboarding flow still has [[slnc 900]] that issue where the model download stalls on slow connections and the support team hasn't been trained on the new settings pane yet and marketing wants another week for the video and if we ship on Friday we're going to [[slnc 900]] spend the whole weekend answering emails about the same three problems which nobody wants so my proposal is we push it to the following Wednesday give engineering the extra days to fix the download retry add the [[slnc 900]] tooltip that Dana asked for and run one more round of testing on the older MacBooks that people keep reporting problems with and then we announce it properly with the [[slnc 900]] blog post and the demo video ready to go instead of scrambling at the last minute like we did last time"
