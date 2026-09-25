# Provenance of the committed third-party notice texts

Every file in this directory is either copied verbatim from an upstream source
at an immutable revision, or written by Reed to attribute material it does not
distribute. Nothing here is paraphrased upstream licence text.

These files exist because the material they cover is **not** obtainable from a
dependency checkout's top-level licence file: it lives inside a binary artifact,
in a nested directory, in a source-file header, or in a model repository that is
not a build dependency at all. `scripts/build/package-notices.py` packages them
alongside the checkout licences and validates each one's content.

## ONNX Runtime

| file | source | revision | sha256 |
|---|---|---|---|
| `onnxruntime-LICENSE.txt` | `https://raw.githubusercontent.com/microsoft/onnxruntime/v1.24.2/LICENSE` | tag `v1.24.2` = commit `058787ceead760166e3c50a0a4cba8a833a6f53f` | `2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c` |
| `onnxruntime-ThirdPartyNotices.txt` | `https://raw.githubusercontent.com/microsoft/onnxruntime/v1.24.2/ThirdPartyNotices.txt` | same | `0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2` |

Reed links the ONNX Runtime **binary** from the pod archive
`https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip`
(SwiftPM `binaryTarget` checksum `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`).
That archive ships a 21-line MIT `LICENSE` and **no** notices file. The archive's
`LICENSE` is byte-identical to the upstream tag's `LICENSE` recorded above
(verified with `cmp`), so the tag is a sound authority for it; the vendored
components' notices exist only upstream, which is why the 6,121-line
`ThirdPartyNotices.txt` is committed here.

The version is the one Reed actually links, taken from the wrapper's own
`Package.swift` at pin `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2` — not from a
similarly named artifact and not from upstream `main`.

## Sentry

Extracted from the pinned checkout `getsentry/sentry-cocoa` at
`dad229c665bfd043c5d80ac7aa77717cbd19a1c3` (the revision in `Package.resolved`).

| file | source path in that revision | sha256 |
|---|---|---|
| `sentry-fishhook-and-yandex-notices.txt` | `Sources/SentryCrash/Recording/Tools/SentryCrashCxaThrowSwapper.c`, leading comment | `416e4889eba32c3d4ce8c4ee3b70bc02803028becffb388229c3c9d8cef171aa` |
| `sentry-webkit-derived-notices.txt` | `Sources/Sentry/include/SentryCPU.h` + `Sources/Sentry/include/SentryCompiler.h`, leading comments | `16c82676e29c0fd9607406b8932c99b15839347a4c417030cb90f6f50d2303b9` |
| `sentry-apsl-header-reference.txt` | `Sources/SentryCrash/Recording/Tools/SentryCrashObjCApple.h`, leading comment | `334b830732dadc76fde845779e92e320df8f2587c361c6b5398b4bd4c23d8f77` |

Why these three and not every copyright header in the package:

- **fishhook (Facebook, 2013)** — BSD-3 whose clause requires that binary
  redistributions "reproduce the above copyright notice … in the documentation
  and/or other materials provided with the distribution". Its object,
  `SentryCrashCxaThrowSwapper.o`, is present in the selected static archive.
  The same file's *first* notice (YANDEX LLC, 2019) is a source-preservation
  clause; it is included here because it is part of the same header block, not
  because it imposes a binary-distribution duty.
- **WebKit-derived (Apple Inc. and others)** — the same style of binary
  reproduction clause. These are headers with no object of their own, so their
  inclusion in the linked binary is inherited from the translation units that
  include them and was not traced per object. They are packaged because the
  clause applies if the code is present, not because presence was proven.
- **APSL header reference** — `SentryCrashObjCApple.h` is under the Apple
  Public Source License 2.0, a different licence with its own obligations.
  **This file is a reference, not a determination.** Committing it does not
  resolve what APSL 2.0 requires of Reed; that question is recorded as open in
  `docs/steps/oss-05-verification.md`. Adding a link is not an answer.

Notices whose clause is source-preservation only ("shall remain in place in this
source code" — the KSCrash-derived files from Karl Stenerud, Bugsnag and Yandex
throughout `SentryCrash`) are **not** packaged as binary notices. Upstream
satisfies those clauses by keeping the headers in place, and listing them here
would misrepresent a source obligation as a distribution one.

## Speech model

`parakeet-model-attribution.txt` is written by Reed, not copied. Its factual
claims come from:

| claim | source | revision |
|---|---|---|
| converted model identity, "converted to Core ML", conversion-script link | `https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml` model card | `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe` |
| the card's conflicting licence statements (`cc-by-4.0` in metadata, "Apache 2.0" in prose) | same | same |
| base model identity and "GOVERNING TERMS: … CC-BY-4.0" | `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3` model card | `541d1f99c6b0c3cd0b11a95167540bb8edefd82b` |

The recorded CoreML revision is **evidence of what was observed**, not a pin:
Reed's downloader requests `main` and does not select a revision, so a later
install can receive different bytes. The attribution says so explicitly.
