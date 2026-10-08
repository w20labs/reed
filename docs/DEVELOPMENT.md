# Developing Reed

How to build Reed from source, how the code is laid out, and how to run the
tests. To use Reed, download it from [reed.w20.ai](https://reed.w20.ai)
instead; see the [README](../README.md).

## Build from source

Requirements:

- macOS 14+ on Apple Silicon.
- **Xcode 15.4+ installed in `/Applications/Xcode.app`.** `KeyboardShortcuts`
  uses `#Preview` macros that need the full Xcode toolchain; the Command Line
  Tools alone are not enough. The build script routes through Xcode when it is
  present.
- An Apple Developer / Apple Development code-signing identity in your login
  keychain, so microphone and accessibility grants persist across rebuilds.
  Without one the build script falls back to ad-hoc signing.

No API keys: transcription and cleanup run entirely on-device.

```sh
./build-app.sh
cp -R Reed.app /Applications/
open /Applications/Reed.app
```

The `.app` wrapper is required for macOS to associate the microphone and
accessibility permissions with the right binary identity.

## Pipeline

Fully on-device: hotkey → AVAudioEngine capture → on-device denoise
(FastEnhancer) → Parakeet v3 speech recognition (FluidAudio, Neural Engine) →
deterministic vocabulary/spoken-forms pass → Apple Foundation Models cleanup
(per sentence, alignment-gated) → text injection (Accessibility API with a
clipboard+⌘V fallback).

## Project layout

```
reed/
├── Package.swift                    SPM manifest
├── Info.plist                       bundle metadata + permission usage strings
├── build-app.sh                     swift build → arm64 .app bundle + codesign
├── design/hud-design-system.html    the canonical UI "Figma" — source of truth for all UI work
├── scripts/design/render-block.sh   renders one block of it to PNG (a design change is a grep AND a render)
├── scripts/qa/                      the local QA page (qa.sh), the local-review opt-in (review.sh on|off|status) and its bench (review_bench.py)
├── docs/bench/baselines.json        committed performance ceilings the benches read
├── legal/                           third-party notice texts and their provenance
├── Tools/vocabulary/                vocabulary.yaml → generate.py → VocabularyData.generated.swift
├── Sources/Reed/
│   ├── ReedApp.swift                @main, MenuBarExtra
│   ├── Coordinator*.swift           pipeline orchestration (@MainActor)
│   ├── Recorder/                    AVAudioEngine capture, keep-warm, hotkey field
│   ├── LocalASR/                    Parakeet client (the speech model), model store/downloads, AI cleanup
│   ├── Transcribe/                  sentence chunker, cleanup gate, built-in vocabulary
│   ├── Inject/                      AX + clipboard text injection
│   ├── Onboarding/                  first-run flow
│   ├── Settings/                    settings panes
│   └── Pipeline/                    network gate (GateURLProtocol, blocked-request tally), debug menu, overlap session
└── Tests/ReedTests/
```

## Tests

Run the standard suite with the Xcode toolchain:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --toolchain XcodeDefault swift test
env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/qa -p 'test_*.py'
```

Some benches read an audio corpus of recordings and transcripts. That corpus is
deliberately **not** in this repository: it is personal dictation, and nothing
from it may be committed to make a test pass. Those benches skip, by name, when
it is absent. To run them, point `REED_VOICE_ROOT` at your own corpus, or place
one in `voice-tests/` at the repository root:

```sh
env REED_VOICE_ROOT=/path/to/voice-tests DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun --toolchain XcodeDefault swift test
```

Everything else runs without it. Tests that check a property rather than a
recording carry their own fixtures, so they run everywhere.

The permanent cleanup review cases (from the review that preceded the
open-source release) live in `CleanupReviewCases.swift` and
`CleanupReviewRegressionTests.swift`. They cover restarts, negations, emphasis,
chains, sentence/paragraph boundaries, delimiters, quotation boundaries, casing,
and pause assembly. They run automatically in the standard suite and CI, and in
the QA page's **Unit · Text pipeline** row. To run just these regressions:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --toolchain XcodeDefault swift test --filter CleanupReviewRegressionTests
```

Restart an already-running QA server after pulling new tests so it rebuilds its inventory.

These tests never record audio or inject text. The accepted-model post-pass test
uses a stub, but the production routing still requires macOS 26 with Apple
Intelligence available; that one test reports a skip elsewhere. The rules and
assembly checks run on every supported test host. This is a deterministic
regression suite, not a substitute for the real-model quality/audio benches.
