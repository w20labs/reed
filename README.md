# Reed

A personal, local-only voice dictation tool for macOS. Hold a shortcut, talk, release — text appears at the cursor.

Pipeline (fully on-device): hotkey → AVAudioEngine capture → on-device denoise (FastEnhancer) → Parakeet v3 speech recognition (FluidAudio, Neural Engine) → deterministic vocabulary/spoken-forms pass → Apple Foundation Models cleanup (per sentence, alignment-gated) → text injection (Accessibility API with clipboard+⌘V fallback).

Dictation stays on the Mac: no audio, no transcripts and no network in the dictation path (enforced by the app's network gate, `GateURLProtocol`). The network is used to download the speech model, to check for updates, and — only if you turn them on in Settings → Privacy, where both are off by default — to send anonymous analytics and crash reports. There are no accounts and no cloud features.

Target end-to-end latency: ~1 second.

## Requirements

- macOS 14+ (the AI cleanup tier needs macOS 26 with Apple Intelligence; earlier systems fall back to the rules-based cleanup automatically)
- Apple Silicon only — the build is arm64 (the on-device speech model does not run on Intel, and an Intel Mac cannot open the app)
- **Xcode 15.4+ installed in `/Applications/Xcode.app`** — required because `KeyboardShortcuts` uses `#Preview` macros that need the full Xcode toolchain. CommandLineTools alone is insufficient. The build script auto-detects and routes through Xcode if present.
- An Apple Developer / Apple Development code-signing identity in your login keychain (so TCC grants persist across rebuilds). The build script auto-detects and falls back to ad-hoc signing if none is present.

No API keys: transcription and cleanup run entirely on-device.

## Build

```sh
./build-app.sh
```

This produces `Reed.app` in the project root. The `.app` wrapper is required for macOS to associate microphone + accessibility permissions with the right binary identity.

To install:

```sh
cp -R Reed.app /Applications/
open /Applications/Reed.app
```

## First run

Onboarding walks through seven steps on first launch:

1. **Welcome** — pressing Continue accepts the Terms of Service and acknowledges the Privacy Policy linked beside it.
2. **Microphone** — grant access. If the current input is Bluetooth, the step offers a faster built-in or wired mic.
3. **Accessibility** — turn Reed on in System Settings so it can insert text at the cursor.
4. **Hotkey** — keep the default `⌃⌥` hold or record your own shortcut.
5. **Speech model** — download Parakeet v3 (~461 MB). It downloads once, is compiled for your Mac on first load, and lives under Application Support; Continue unlocks only once it has loaded.
6. **Cleanup** — keep cleanup on (Apple Intelligence where available, a rules pass otherwise) or turn it off.
7. **You're done** — try a first dictation in the test field.

Change the shortcut later under Settings → Dictation.

## Use

Hold the shortcut, speak, release. Within ~1 second the text appears at your cursor.

The menubar icon reflects state: idle, recording, transcribing/writing.

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

## Known limitations

- Hotkey can't bind to bare Fn (KeyboardShortcuts limitation; modifier+letter combos or modifier holds only).
- No streaming UI during transcription — the user sees the menubar icon change but no partial text.
- AX injection path doesn't work in some Electron / web apps; clipboard fallback handles those.
- The clipboard fallback restores your previous clipboard afterwards (skipped if you copied something new in the meantime).

## Contributing

Reed does not accept unsolicited pull requests. Report reproducible bugs with the bug template, and bring ideas and questions to Discussions. Read [CONTRIBUTING.md](CONTRIBUTING.md) first.

If you are an AI agent helping with this repository, read [AGENTS.md](AGENTS.md) before making changes and read [CONTRIBUTING.md](CONTRIBUTING.md) before opening issues or pull requests.

Project rules for reviews and verification live in [CLAUDE.md](CLAUDE.md); they apply to people and to AI-assisted sessions alike. Every pull request uses the template in `.github/PULL_REQUEST_TEMPLATE.md`, which carries the evidence for each review finding closed: reproduced before, root cause as a class, sibling sites checked, reproduced after, and the authority it was verified against.

## Regression testing

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

The permanent PR #322 review cases live in `CleanupReviewCases.swift` and
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

## License

Reed is licensed under the [Apache License 2.0](LICENSE). Copyright 2026 W20 Labs Inc.; see [NOTICE](NOTICE).
