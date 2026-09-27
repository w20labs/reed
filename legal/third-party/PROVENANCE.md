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
