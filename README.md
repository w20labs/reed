# Reed Dictation

**Free, private voice dictation for Mac.** Hold a shortcut, talk, release: clean text appears at your cursor, in any app. Everything runs on your Mac.

<p>
  <a href="https://reed.w20.ai/download/Reed.dmg"><img src="https://img.shields.io/badge/Download-Reed%20for%20Mac-2f6feb?style=for-the-badge&logo=apple&logoColor=white" alt="Download Reed for Mac"></a>
</p>

[![Latest release](https://img.shields.io/github/v/release/w20labs/reed?label=release)](https://github.com/w20labs/reed/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-555)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%20or%20newer-555)
![On-device](https://img.shields.io/badge/audio-never%20leaves%20your%20Mac-2ea44f)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

## You say, Reed types

| You say | Reed types |
|---|---|
| "Um, so I think we should, uh, ship it on Friday." | So I think we should ship it on Friday. |
| "Let's meet at seven PM, sorry, five PM." | Let's meet at 5:00 PM. |
| "Call me on Tuesday, I mean Wednesday." | Call me on Wednesday. |
| "The invoice came in at three thousand one hundred and sixty two dollars, due on the fifteenth of March." | The invoice came in at $3,162, due on the 15th of March. |
| "I'm sorry, I can't make it today." | I'm sorry, I can't make it today. |

Real output of Reed 0.3.2 on a Mac with Apple Intelligence, from speech made with the Mac's built-in voice. Fillers go, self-corrections resolve, numbers, amounts and dates are written the way you would type them, and what you meant to say stays. Without Apple Intelligence, a rules-based cleanup does the same kind of tidying.

## Why Reed

- **Free, with no account.** No subscription, no sign-in, no trial.
- **Private by design.** Audio and text never leave your Mac. There is no cloud transcription, no analytics and no crash reporting.
- **Fast.** Text appears about a second after you let go.
- **Works everywhere you type.** Mail, Messages, Slack, Notes, browsers, editors: anywhere there is a text cursor.
- **Open source.** Every line that touches your voice is in this repository, under Apache 2.0.

Comparing options? See Reed next to [Wispr Flow](https://reed.w20.ai/wispr-flow-alternative), [Superwhisper](https://reed.w20.ai/superwhisper-alternative) and [Apple Dictation](https://reed.w20.ai/apple-dictation-alternative).

## Install

1. [Download Reed](https://reed.w20.ai/download/Reed.dmg) (or take the DMG from [GitHub Releases](https://github.com/w20labs/reed/releases/latest)) and drag it to Applications.
2. Open it. A short setup asks for the microphone, for Accessibility (so Reed can type at your cursor), and for your shortcut (the default is holding <kbd>⌃</kbd><kbd>⌥</kbd>).
3. Reed downloads its speech model once (about 461 MB), then you try a first dictation right in the setup window.

Requires macOS 14 or later on Apple Silicon (M1 or newer). AI cleanup needs macOS 26 with Apple Intelligence; other Macs use the rules-based cleanup automatically. Reed checks for updates itself.

## Privacy you can check

Dictation has no network path: no audio, no transcripts, no requests. The app's network gate (`GateURLProtocol`) enforces it, and you can confirm it with any network monitor, such as Little Snitch.

The network is used for two things only: downloading the speech model (from Hugging Face) and checking for updates (Sparkle, from Reed's release bucket). Like any web request, those carry your Mac's IP address, and the update check names the app and Sparkle versions in its user agent. Details: [what Reed collects](https://reed.w20.ai/legal/what-we-collect).

## How it works

<p align="center">
  <img src="docs/media/how-reed-works.svg" width="860" alt="How Reed works: hold the shortcut and speak; Reed records, splits the recording at pauses, and sends each segment through on-device denoising, Parakeet v3 recognition and cleanup while you keep talking; on release the segments are joined in order and typed at your cursor. Nothing leaves the Mac.">
</p>

While you talk, Reed splits the recording at pauses and processes each piece on the Mac: noise reduction, speech recognition with NVIDIA's Parakeet v3 on the Neural Engine, a deterministic pass for numbers and vocabulary, then cleanup with Apple's on-device Foundation Models. Every model edit is checked word by word against what you said, and refused if it rewrites your words instead of tidying them. On release, the pieces are joined and typed at your cursor.

## FAQ

**Which languages does it understand?** English, today. Other languages are not supported yet.

**Does it work offline?** Yes. After the one-time model download, dictation and cleanup need no connection.

**Can I use the Fn key?** Not alone. Use a modifier hold (like the default <kbd>⌃</kbd><kbd>⌥</kbd>) or a modifier plus a letter.

**Does it work in Electron and web apps?** Yes. Where an app does not accept typed text through Accessibility, Reed pastes instead and then restores your previous clipboard (unless you copied something new in the meantime).

**Do I see text while I talk?** Not yet. The menu bar icon shows recording and processing, and the text appears when you let go.

**Does it run on Intel Macs?** No. The speech model needs Apple Silicon.

## Contributing

Bug reports and ideas are welcome. Report reproducible bugs with the bug template, and bring ideas and questions to [Discussions](https://github.com/w20labs/reed/discussions). Reed's maintainers implement accepted changes themselves, so unsolicited pull requests are closed; [CONTRIBUTING.md](CONTRIBUTING.md) explains how to take part.

To build Reed, run the tests, or find your way around the code, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

If you are an AI agent helping with this repository, read [AGENTS.md](AGENTS.md) before making changes and [CONTRIBUTING.md](CONTRIBUTING.md) before opening issues or pull requests. Project rules for reviews and verification live in [CLAUDE.md](CLAUDE.md); they apply to people and to AI-assisted sessions alike, and every pull request uses `.github/PULL_REQUEST_TEMPLATE.md`.

## License

Reed is licensed under the [Apache License 2.0](LICENSE). Copyright 2026 W20 Labs Inc.; see [NOTICE](NOTICE).
