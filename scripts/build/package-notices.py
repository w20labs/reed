#!/usr/bin/env python3
"""Package third-party notices into a Reed.app bundle, deterministically.

    python3 scripts/build/package-notices.py <bundle-resources-dir> [--check-only]

Replaces the directory-glob loop this script's mapping supersedes. That loop
copied the first LICENSE-ish filename out of every `.build/checkouts/*/`, which
silently shipped nothing for a package whose licence sat elsewhere, dropped a
package's second required text, and copied directories that were no longer in
Package.resolved at all (all three reproduced on the production path — see
docs/steps/oss-05-verification.md).

Here every packaged file is named explicitly by scripts/build/third-party-notices.json
and validated before and after it is copied. Anything missing, empty, corrupt or
not matching its authority is a nonzero exit naming the component and path; the
managed directory is regenerated from scratch each run, so a file left behind by
an earlier failed run can never be mistaken for success.

The mapping is pinned to Package.resolved by a digest. A pin change means the
selected component set may have changed, so the mapping is stale until a human
re-reviews it: packaging fails rather than guessing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAPPING = ROOT / "scripts/build/third-party-notices.json"
RESOLVED = ROOT / "Package.resolved"
MANIFEST = ROOT / "Package.swift"
CHECKOUTS = ROOT / ".build/checkouts"
DIRNAME = "ThirdPartyLicenses"


class NoticeError(Exception):
    """A packaging failure that names its component and path."""


def pin_digest(resolved: Path) -> str:
    """SHA-256 over (identity, revision) for every pin, order-independent.

    Only the pins matter: a formatting change in Package.resolved must not
    invalidate a mapping that is still correct, and a changed revision must.
    """
    data = json.loads(resolved.read_text())
    pins = sorted(
        (p["identity"], (p.get("state") or {}).get("revision", ""))
        for p in data.get("pins", [])
    )
    return hashlib.sha256(json.dumps(pins).encode()).hexdigest()


def resolve_source(spec: str) -> Path:
    """`checkout:<path>` under .build/checkouts, `repo:<path>` under the repo."""
    kind, _, rel = spec.partition(":")
    if kind == "checkout":
        return CHECKOUTS / rel
    if kind == "repo":
        return ROOT / rel
    raise NoticeError(f"unknown source kind {kind!r} in {spec!r}")


def flatten(text: str) -> str:
    """Collapse a licence text to its words, ignoring layout.

    Upstream notices arrive wrapped to whatever width their author chose, and
    the ones extracted from source headers carry `//` or ` * ` prefixes, so a
    clause reads `...the above copyright\\n *    notice, this list...`. Matching
    raw substrings would force every assertion down to whatever fragment happens
    to fit on one line, which is how a content check quietly decays into a
    nonempty check. Comparing words instead keeps the assertions whole: the
    complete binary-reproduction sentence stays a required match.
    """
    unprefixed = " ".join(line.lstrip(" \t*#/").strip() for line in text.splitlines())
    return " ".join(unprefixed.split())


def validate(component: str, notice: dict, path: Path, stage: str) -> bytes:
    """Read and check one notice file. Raises NoticeError naming the path.

    The hash is what establishes identity. Phrase matching alone accepted any
    file carrying the right words — a two-line heading, or a title followed by
    padding — which is the same "it looks about right" failure the replaced glob
    had, one level up (review 2026-09-16). Every source here has byte-stable
    authority: a `repo:` text is committed, a `checkout:` file is fixed by its
    pin. So the bytes must match exactly, and `must_contain` stays only to say
    WHY a file is required, in terms a reader can check.
    """
    where = f"[{component}] {stage} {path}"
    if not path.is_file():
        raise NoticeError(f"{where}: missing")
    raw = path.read_bytes()
    if not raw.strip():
        raise NoticeError(f"{where}: empty")

    expected = notice.get("sha256")
    if not expected:
        # Absence must not be a way to skip the check.
        raise NoticeError(f"{where}: mapping entry has no sha256; every notice must pin its bytes")
    actual = hashlib.sha256(raw).hexdigest()
    if actual != expected:
        raise NoticeError(
            f"{where}: content does not match its authority "
            f"(expected {expected[:16]}…, got {actual[:16]}…, {len(raw)} bytes). "
            "If the upstream text legitimately changed, re-review it and update "
            "sha256 in scripts/build/third-party-notices.json."
        )

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise NoticeError(f"{where}: not valid UTF-8 ({exc})") from exc
    flat = flatten(text)
    for needle in notice.get("must_contain", []):
        if flatten(needle) not in flat:
            raise NoticeError(f"{where}: missing required text {needle!r}")
    return raw


def manifest_digest(manifest: Path) -> str:
    """SHA-256 of Package.swift.

    An earlier version parsed `.product(name:package:)` out of the manifest with
    a regex, and a reviewer added a product carrying a `condition:` argument that
    the pattern did not match — packaging accepted a dependency nobody had
    reviewed (review round 3). Every fix of that shape is a new special case
    waiting for the next declaration form: multi-line, `.byName`, a target
    dependency added elsewhere, a conditional.

    So this does not parse the manifest at all. Any edit to Package.swift makes
    the reviewed mapping stale, and packaging stops until a human looks at the
    change and updates the digest. That is stricter than necessary — a comment
    edit also trips it — and that is the correct trade for deciding what licence
    material ships.
    """
    return hashlib.sha256(manifest.read_bytes()).hexdigest()


def package(resources: Path, check_only: bool = False) -> list[str]:
    mapping = json.loads(MAPPING.read_text())

    expected = mapping.get("pin_digest") or ""
    actual = pin_digest(RESOLVED)
    if expected != actual:
        raise NoticeError(
            "Package.resolved does not match the reviewed notice mapping "
            f"(mapping {expected or '<unset>'}, resolved {actual}). A pin or "
            "dependency changed: re-review scripts/build/third-party-notices.json, "
            "update pin_digest, and re-run."
        )

    reviewed_manifest = mapping.get("manifest_digest") or ""
    current_manifest = manifest_digest(MANIFEST)
    if reviewed_manifest != current_manifest:
        raise NoticeError(
            "Package.swift has changed since the notice mapping was reviewed "
            f"(mapping {reviewed_manifest[:16] or '<unset>'}…, manifest "
            f"{current_manifest[:16]}…). What licence material ships depends on "
            "what the manifest declares, so re-review "
            "scripts/build/third-party-notices.json, update manifest_digest, and "
            "re-run. `selection` in that file records the products reviewed."
        )

    out = resources / DIRNAME
    planned: dict[str, bytes] = {}
    for component in mapping["components"]:
        cid = component["id"]
        for notice in component["notices"]:
            src = resolve_source(notice["source"])
            raw = validate(cid, notice, src, "source")
            dest = notice["dest"]
            if dest in planned:
                raise NoticeError(f"[{cid}] duplicate destination {dest}")
            planned[dest] = raw

    if check_only:
        return sorted(planned)

    # Regenerate: an entry from a previous (possibly failed) run must never
    # survive into a successful one.
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for dest, raw in planned.items():
        (out / dest).write_bytes(raw)

    # Validate the destination set and content after copying, not just before.
    for component in mapping["components"]:
        cid = component["id"]
        for notice in component["notices"]:
            written = validate(cid, notice, out / notice["dest"], "packaged")
            if written != planned[notice["dest"]]:
                raise NoticeError(f"[{cid}] {notice['dest']}: content changed while copying")
    actual_files = {p.name for p in out.iterdir()}
    if actual_files != set(planned):
        unexpected = sorted(actual_files - set(planned))
        missing = sorted(set(planned) - actual_files)
        raise NoticeError(f"packaged set wrong: unexpected={unexpected} missing={missing}")
    return sorted(planned)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("resources", type=Path, help="the bundle's Contents/Resources directory")
    ap.add_argument("--check-only", action="store_true", help="validate inputs, write nothing")
    args = ap.parse_args()
    try:
        names = package(args.resources, args.check_only)
    except NoticeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    verb = "validated" if args.check_only else "packaged"
    print(f"third-party notices: {verb} {len(names)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
