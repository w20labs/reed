#!/usr/bin/env python3
"""The last check before an appcast is uploaded by the release tooling: the feed
carries the release being published, and that item tells Sparkle it is
arm64 only. Exit 1 with the reason otherwise. Tested by
scripts/qa/test_release_arch.py.

    check-appcast.py <appcast.xml> <version>
"""
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def check(path: str, version: str) -> str | None:
    try:
        rss = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as exc:
        return f"{path}: not a readable appcast ({exc})"
    items = [i for i in rss.iter("item") if i.findtext("title") == f"Reed {version}"]
    if len(items) != 1:
        return f"{path}: expected exactly one item for Reed {version}, found {len(items)}"
    if items[0].findtext(f"{{{SPARKLE}}}hardwareRequirements") != "arm64":
        return f"{path}: the Reed {version} item does not carry sparkle:hardwareRequirements=arm64"
    return None


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    problem = check(sys.argv[1], sys.argv[2])
    if problem:
        sys.exit("ERROR: " + problem)
    print(f"appcast ok: Reed {sys.argv[2]} is present and arm64-only")
