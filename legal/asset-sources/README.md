# Asset sources

Originals for assets Reed ships, kept so the shipped file can be reproduced and
its origin checked. Nothing in this directory is copied into the app bundle.

## `cue-source.wav` — the dictation cue sound

- SHA-256 `6931bdd71f2a0bfacee2fd1155a912739ad086b0ed5f34cef1084fa669e2b108`, 41,090 bytes, mono 44.1 kHz, 0.400 s.
- Supplied by the repository owner on 2026-09-21 as `pop_C_triple_0.40s.wav`.
- `Resources/Sounds/pop.wav` is generated from this file by
  `scripts/audio/prepare-cue-sound.py`; run it with `--check` to verify the
  tracked file still matches.

### Provenance

The file carries a C2PA Content Credentials manifest, signed by the "Anthropic
Content Credentials Root CA", claim generator "Anthropic Files 1.0.0". Read
from the file itself, it records:

- action `com.anthropic.claude.provided`, software agent **Claude**, described
  as "Claude provided this file at the request of a user and may have created
  or modified the file contents";
- `com.anthropic.origin-confidence`: **unknown**;
- an ingredient assertion of type `audio/wav` with relationship **`parentOf`** —
  the file was derived from a parent WAV, which the manifest does not name.

**What is established:** the file is not the previous cue sound. The two differ
in bytes, length (0.400 s against 0.510 s), channel count and rhythm, and their
strongest partials sit at roughly 1,230 Hz and 1,150 Hz.

**What is not established:** which file the `parentOf` ingredient refers to. An
audio analysis cannot show who or what made a sound, so this note does not
claim the file is free of third-party material.

**Owner decision (2026-09-21):** the repository owner reviewed the above and
chose to adopt this sound, taking the view that a sound produced this way is
acceptable to ship. That decision is the owner's, not a determination by the
implementer or by any licence review. If the parent asset is later identified
and carries terms, this decision should be revisited.

The credentials are preserved in this source file. The generated
`Resources/Sounds/pop.wav` carries audio only, since the preparation step
rewrites the file.
