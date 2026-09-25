"""The notice packager must fail loudly rather than ship an incomplete set.

    python3 -m unittest discover -s scripts/build/tests -p 'test_*.py'

Every case drives the production `package()` from scripts/build/package-notices.py
against a fixture tree built in a temp directory — the module's ROOT/MAPPING/
RESOLVED/CHECKOUTS are repointed per test, so a real SDK checkout is never read
or modified. The old glob loop is reproduced verbatim in `old_loop()` so each
regression case can show what it used to do with the same inputs.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / "scripts/build/package-notices.py"


def load_packager():
    spec = importlib.util.spec_from_file_location("package_notices", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def old_loop(checkouts: Path, out: Path) -> int:
    """build-app.sh's replaced notice block, verbatim in Python.

    Kept so a regression case can demonstrate the behaviour it guards against
    instead of asserting it from memory. Returns its exit status, which was
    always 0.
    """
    out.mkdir(parents=True, exist_ok=True)
    for pkg in sorted(p for p in checkouts.iterdir() if p.is_dir()):
        for lic in ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING"):
            if (pkg / lic).is_file():
                shutil.copy(pkg / lic, out / f"{pkg.name}.txt")
                break
        for notice in ("NOTICE", "NOTICE.txt", "NOTICE.md"):
            if (pkg / notice).is_file():
                shutil.copy(pkg / notice, out / f"{pkg.name}-NOTICE.txt")
                break
    return 0


PIN_A = "1111111111111111111111111111111111111111"
PIN_B = "2222222222222222222222222222222222222222"

MANIFEST_ONE_PRODUCT = """
// swift-tools-version: 5.10
let package = Package(
    targets: [
        .executableTarget(name: "Reed", dependencies: [
            .product(name: "Alpha", package: "libalpha"),
        ])
    ]
)
"""
MANIFEST_SWAPPED = MANIFEST_ONE_PRODUCT.replace(
    '.product(name: "Alpha", package: "libalpha")',
    '.product(name: "AlphaExtensions", package: "libalpha")',
)
# The declaration a regex over `.product(name:package:)` did not match: a second
# product added alongside the first, carrying a condition: argument and wrapped
# across lines (review round 3).
MANIFEST_CONDITIONAL_EXTRA = MANIFEST_ONE_PRODUCT.replace(
    '.product(name: "Alpha", package: "libalpha"),',
    '.product(name: "Alpha", package: "libalpha"),\n'
    '            .product(name: "AlphaExtensions",\n'
    '                     package: "libalpha",\n'
    '                     condition: .when(platforms: [.macOS])),',
)


class NoticePackagerTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.pn = load_packager()

        self.checkouts = self.dir / "checkouts"
        (self.checkouts / "libalpha").mkdir(parents=True)
        # A *complete* licence: heading, copyright, grant and conditions. The
        # gutting probes below delete the operative parts while keeping the
        # heading and copyright, so the baseline must have parts to delete.
        self.full_licence = (
            "MIT License\n\nCopyright (c) Alpha\n\n"
            "Permission is hereby granted, free of charge, to any person obtaining a copy\n"
            "of this software and associated documentation files (the \"Software\"), to deal\n"
            "in the Software without restriction, including without limitation the rights\n"
            "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n"
            "copies of the Software, subject to the following conditions:\n\n"
            "The above copyright notice and this permission notice shall be included in all\n"
            "copies or substantial portions of the Software.\n"
        )
        (self.checkouts / "libalpha/LICENSE").write_text(self.full_licence)
        (self.checkouts / "libalpha/ThirdPartyLicenses").mkdir()
        self.vendored_text = "Copyright (c) Vendored Author\nRedistribution and use in binary form\n"
        (self.checkouts / "libalpha/ThirdPartyLicenses/vendored.md").write_text(self.vendored_text)

        self.repo_texts = self.dir / "legal"
        self.repo_texts.mkdir()
        (self.repo_texts / "artifact-notices.txt").write_text(
            "THIRD PARTY SOFTWARE NOTICES\nlots of vendored components\n"
        )

        self.resolved = self.dir / "Package.resolved"
        self.write_resolved(PIN_A)
        self.manifest = self.dir / "Package.swift"
        self.manifest.write_text(MANIFEST_ONE_PRODUCT)

        self.mapping_path = self.dir / "mapping.json"
        self.mapping = {
            "pin_digest": "",
            "components": [
                {
                    "id": "libalpha",
                    "pin": PIN_A,
                    "selected": "product Alpha",
                    "notices": [
                        {
                            "source": "checkout:libalpha/LICENSE",
                            "dest": "Alpha-LICENSE.txt",
                            "kind": "elected",
                            "must_contain": ["MIT License", "Copyright (c) Alpha"],
                        },
                        {
                            "source": "checkout:libalpha/ThirdPartyLicenses/vendored.md",
                            "dest": "Alpha-vendored-LICENSE.txt",
                            "kind": "cumulative",
                            "must_contain": ["Copyright (c) Vendored Author"],
                        },
                        {
                            "source": "repo:legal/artifact-notices.txt",
                            "dest": "Alpha-artifact-ThirdPartyNotices.txt",
                            "kind": "cumulative",
                            "must_contain": ["THIRD PARTY SOFTWARE NOTICES"],
                        },
                    ],
                }
            ],
            "excluded": [{"id": "unused-artifact", "why": "fetched but not linked"}],
        }
        self.repoint()
        self.sync_digest()
        self.sync_hashes()

        self.resources = self.dir / "Resources"
        self.resources.mkdir()

    # helpers -----------------------------------------------------------

    def write_resolved(self, revision: str):
        self.resolved.write_text(
            json.dumps({"pins": [{"identity": "libalpha", "state": {"revision": revision}}], "version": 3})
        )

    def repoint(self):
        """Point the production module at this fixture, never the real repo."""
        self.pn.ROOT = self.dir
        self.pn.MAPPING = self.mapping_path
        self.pn.RESOLVED = self.resolved
        self.pn.MANIFEST = self.manifest
        self.pn.CHECKOUTS = self.checkouts

    def save_mapping(self):
        self.mapping_path.write_text(json.dumps(self.mapping))

    def sync_digest(self):
        self.mapping["pin_digest"] = self.pn.pin_digest(self.resolved)
        self.mapping["manifest_digest"] = self.pn.manifest_digest(self.manifest)
        self.save_mapping()

    def sync_hashes(self):
        """Record each source's real bytes, as a reviewer would after checking them."""
        for component in self.mapping["components"]:
            for notice in component["notices"]:
                src = self.pn.resolve_source(notice["source"])
                notice["sha256"] = hashlib.sha256(src.read_bytes()).hexdigest()
        self.save_mapping()

    def out(self) -> Path:
        return self.resources / self.pn.DIRNAME

    def package(self):
        return self.pn.package(self.resources)

    # the happy path ----------------------------------------------------

    def test_packages_every_mapped_notice(self):
        names = self.package()
        self.assertEqual(
            sorted(names),
            ["Alpha-LICENSE.txt", "Alpha-artifact-ThirdPartyNotices.txt", "Alpha-vendored-LICENSE.txt"],
        )
        self.assertEqual({p.name for p in self.out().iterdir()}, set(names))

    # AC-04 failure behaviour -------------------------------------------

    def test_missing_source_fails_with_component_and_path(self):
        (self.checkouts / "libalpha/LICENSE").unlink()
        with self.assertRaises(self.pn.NoticeError) as ctx:
            self.package()
        self.assertIn("libalpha", str(ctx.exception))
        self.assertIn("LICENSE", str(ctx.exception))
        self.assertIn("missing", str(ctx.exception))
        self.assertFalse(self.out().exists(), "nothing may be written when an input is missing")

    def test_empty_source_fails(self):
        (self.checkouts / "libalpha/LICENSE").write_text("   \n\n")
        with self.assertRaisesRegex(self.pn.NoticeError, "empty"):
            self.package()

    def test_nonempty_but_corrupt_text_fails(self):
        """The old loop's only test was 'a file exists'. Content must decide.

        The hash is re-synced first, so this exercises the *phrase* check: even
        a file whose bytes are what the mapping expects must still read like the
        licence it claims to be.
        """
        (self.checkouts / "libalpha/LICENSE").write_text("this file is not a licence at all\n")
        self.sync_hashes()
        with self.assertRaisesRegex(self.pn.NoticeError, "missing required text"):
            self.package()
        # The old path would have shipped it, which is the regression guarded here.
        legacy = self.dir / "legacy-out"
        old_loop(self.checkouts, legacy)
        self.assertTrue((legacy / "libalpha.txt").is_file())
        self.assertIn("not a licence", (legacy / "libalpha.txt").read_text())

    def test_right_filename_wrong_content_fails(self):
        """Another package's licence under our filename. Hash re-synced, so the
        phrase check is what must catch the wrong copyright holder."""
        (self.checkouts / "libalpha/LICENSE").write_text(
            self.full_licence.replace("Copyright (c) Alpha", "Copyright (c) Somebody Else")
        )
        self.sync_hashes()
        with self.assertRaisesRegex(self.pn.NoticeError, "Copyright \\(c\\) Alpha"):
            self.package()

    def test_cumulative_notice_is_required_not_optional(self):
        """The dropped-second-text defect: the old loop took only the first match."""
        (self.checkouts / "libalpha/ThirdPartyLicenses/vendored.md").unlink()
        with self.assertRaises(self.pn.NoticeError):
            self.package()
        legacy = self.dir / "legacy-out"
        old_loop(self.checkouts, legacy)
        self.assertEqual([p.name for p in legacy.iterdir()], ["libalpha.txt"],
                         "the old loop reported success with the cumulative text absent")

    def test_stale_checkout_is_not_packaged(self):
        """A directory no longer in Package.resolved must not add output."""
        retired = self.checkouts / "retired-dependency"
        retired.mkdir()
        (retired / "LICENSE").write_text("licence of a dependency that was removed\n")
        names = self.package()
        self.assertNotIn("retired-dependency.txt", names)
        for name in names:
            self.assertNotIn("was removed", (self.out() / name).read_text())
        # The old loop copied it, which is the behaviour this replaces.
        legacy = self.dir / "legacy-out"
        old_loop(self.checkouts, legacy)
        self.assertTrue((legacy / "retired-dependency.txt").is_file())

    def test_stale_output_from_a_failed_run_cannot_survive(self):
        self.package()
        leftover = self.out() / "Removed-Dependency-LICENSE.txt"
        leftover.write_text("left behind by an earlier mapping\n")
        self.package()
        self.assertFalse(leftover.exists(), "regeneration must not leave a stale entry")

    def test_broken_first_run_then_success_does_not_inherit_output(self):
        self.package()
        self.assertTrue((self.out() / "Alpha-LICENSE.txt").is_file())
        (self.checkouts / "libalpha/ThirdPartyLicenses/vendored.md").unlink()
        with self.assertRaises(self.pn.NoticeError):
            self.package()
        # The failure happens before any write, so the previous good set is still
        # there; what must never happen is a *successful* report over stale files.
        (self.checkouts / "libalpha/ThirdPartyLicenses/vendored.md").write_text(self.vendored_text)
        names = self.package()
        self.assertEqual({p.name for p in self.out().iterdir()}, set(names))

    def test_unreviewed_pin_drift_blocks_packaging(self):
        self.write_resolved(PIN_B)
        with self.assertRaisesRegex(self.pn.NoticeError, "does not match the reviewed notice mapping"):
            self.package()

    def test_pin_digest_ignores_formatting_but_not_revisions(self):
        before = self.pn.pin_digest(self.resolved)
        self.resolved.write_text(
            json.dumps(
                {"version": 3, "pins": [{"identity": "libalpha", "state": {"revision": PIN_A}}]},
                indent=4,
            )
        )
        self.assertEqual(self.pn.pin_digest(self.resolved), before, "reformatting must not invalidate")
        self.write_resolved(PIN_B)
        self.assertNotEqual(self.pn.pin_digest(self.resolved), before, "a revision change must invalidate")

    def test_excluded_artifact_is_absent_from_the_packaged_set(self):
        names = self.package()
        self.assertFalse([n for n in names if "unused-artifact" in n])

    def test_duplicate_destination_is_rejected(self):
        self.mapping["components"][0]["notices"].append(
            {"source": "checkout:libalpha/LICENSE", "dest": "Alpha-LICENSE.txt", "kind": "elected"}
        )
        self.save_mapping()
        self.sync_hashes()  # so the duplicate check, not the hash check, is under test
        with self.assertRaisesRegex(self.pn.NoticeError, "duplicate destination"):
            self.package()

    def test_check_only_writes_nothing(self):
        names = self.pn.package(self.resources, check_only=True)
        self.assertTrue(names)
        self.assertFalse(self.out().exists())

    # corruption that survives phrase matching (review 2026-09-16) -------

    def test_heading_and_copyright_only_is_rejected(self):
        """The reviewer's probe: a file carrying just the required phrases.

        Phrase matching passed this, because the words it asserts are all
        present — while every granted permission and every condition is gone.
        """
        gutted = "MIT License\n\nCopyright (c) Alpha\n"
        self.assertNotEqual(gutted, self.full_licence, "the baseline must have parts to delete")
        (self.checkouts / "libalpha/LICENSE").write_text(gutted)
        # Every needle the mapping asserts still matches this text.
        for needle in self.mapping["components"][0]["notices"][0]["must_contain"]:
            self.assertIn(self.pn.flatten(needle), self.pn.flatten(gutted))
        with self.assertRaisesRegex(self.pn.NoticeError, "does not match its authority"):
            self.package()

    def test_title_plus_padding_at_the_same_length_is_rejected(self):
        """The ORT probe: right title, right size, no notices."""
        original = (self.repo_texts / "artifact-notices.txt").read_bytes()
        padded = "THIRD PARTY SOFTWARE NOTICES\n" + "x" * (len(original) - 29)
        (self.repo_texts / "artifact-notices.txt").write_text(padded)
        self.assertEqual(len(padded), len(original), "same byte length, so a size check cannot see it")
        with self.assertRaisesRegex(self.pn.NoticeError, "does not match its authority"):
            self.package()

    def test_wrong_revision_content_is_rejected(self):
        """A real licence text, but not the one this pin was reviewed against."""
        (self.checkouts / "libalpha/LICENSE").write_text(
            "MIT License\nCopyright (c) Alpha\n\nPermission is hereby granted, "
            "free of charge, to any person obtaining a copy...\n"
        )
        with self.assertRaisesRegex(self.pn.NoticeError, "does not match its authority"):
            self.package()

    def test_notice_without_a_sha256_is_rejected(self):
        """Absence of the check must not be a way around the check."""
        del self.mapping["components"][0]["notices"][0]["sha256"]
        self.save_mapping()
        with self.assertRaisesRegex(self.pn.NoticeError, "no sha256"):
            self.package()

    # selection drift (review 2026-09-16) -------------------------------

    def test_product_swap_with_unchanged_pins_blocks_packaging(self):
        """Pins identical, a different product linked."""
        self.assertEqual(self.pn.pin_digest(self.resolved), self.mapping["pin_digest"],
                         "pins are deliberately unchanged in this scenario")
        self.manifest.write_text(MANIFEST_SWAPPED)
        with self.assertRaisesRegex(self.pn.NoticeError, "Package.swift has changed"):
            self.package()

    def test_conditional_product_added_alongside_is_rejected(self):
        """The round-3 reproduction: a regex over `.product(name:package:)`
        missed this because of the trailing condition: argument."""
        self.manifest.write_text(MANIFEST_CONDITIONAL_EXTRA)
        self.assertIn("AlphaExtensions", self.manifest.read_text())
        self.assertEqual(self.pn.pin_digest(self.resolved), self.mapping["pin_digest"],
                         "pins are unchanged; only the manifest gained a product")
        with self.assertRaisesRegex(self.pn.NoticeError, "Package.swift has changed"):
            self.package()

    def test_any_manifest_edit_invalidates_the_mapping(self):
        """No parsing means no declaration form can slip past — at the cost of
        a comment edit also requiring a re-review, which is the right trade."""
        self.manifest.write_text(MANIFEST_ONE_PRODUCT + "\n// a trailing comment\n")
        with self.assertRaisesRegex(self.pn.NoticeError, "Package.swift has changed"):
            self.package()

    def test_missing_manifest_digest_in_mapping_is_rejected(self):
        del self.mapping["manifest_digest"]
        self.save_mapping()
        with self.assertRaisesRegex(self.pn.NoticeError, "Package.swift has changed"):
            self.package()

    # the guards themselves must be load-bearing ------------------------

    def test_content_check_disabled_would_let_corruption_through(self):
        """Proves the hash guard is what catches corruption.

        With sha256 and must_contain both removed, the gutted text ships — which
        is what the packager did before this review.
        """
        (self.checkouts / "libalpha/LICENSE").write_text("MIT License\n\nCopyright (c) Alpha\n")
        for notice in self.mapping["components"][0]["notices"]:
            notice.pop("must_contain", None)
            notice["sha256"] = hashlib.sha256(
                self.pn.resolve_source(notice["source"]).read_bytes()
            ).hexdigest()
        self.save_mapping()
        names = self.package()  # passes only because the guards were relaxed
        self.assertIn("Alpha-LICENSE.txt", names)
        self.assertNotIn("Permission is hereby granted", (self.out() / "Alpha-LICENSE.txt").read_text())

    def test_manifest_check_disabled_would_let_a_product_swap_through(self):
        """Re-reviewing the manifest lets the change through, as it should."""
        self.manifest.write_text(MANIFEST_CONDITIONAL_EXTRA)
        self.mapping["manifest_digest"] = self.pn.manifest_digest(self.manifest)
        self.save_mapping()
        self.assertTrue(self.package(), "passes only because the manifest was re-reviewed")


class FlattenTests(unittest.TestCase):
    def setUp(self):
        self.pn = load_packager()

    def test_matches_across_wrapping_and_comment_prefixes(self):
        source = (
            " * 2. Redistributions in binary form must reproduce the above copyright\n"
            " *    notice, this list of conditions and the following disclaimer in the\n"
            " *    documentation and/or other materials provided with the distribution.\n"
        )
        needle = "Redistributions in binary form must reproduce the above copyright notice"
        self.assertNotIn(needle, source, "the raw substring genuinely does not appear")
        self.assertIn(self.pn.flatten(needle), self.pn.flatten(source))

    def test_does_not_match_different_words(self):
        self.assertNotIn(
            self.pn.flatten("must reproduce the above copyright notice"),
            self.pn.flatten("may omit the above copyright notice"),
        )


if __name__ == "__main__":
    unittest.main()
