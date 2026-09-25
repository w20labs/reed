"""Local review copies (P16) as the QA page sees them.

Reads the app's review directory directly (one JSON per dictation, and the
dictation's recording as a WAV beside it, written by the app while
`reed.localReview` is set), reports the state, lists and loads copies,
serves a copy's recording to the review pane, writes a human reference INTO
a copy, and deletes them all. Nothing here leaves the Mac.

References are written in place. Expiry is measured from the dictation's
time in the file's name — the app does the same — never a filesystem date.
Ids are the file's basename and must match the app's pattern.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

KEY = "reed.localReview"
MAX_AGE_DAYS = 14
# Exactly the app's name: stamp, hyphen, a well-formed UUID, `.json` — a
# malformed id (36 hyphens, say) is not a copy and is never touched.
_HEX = "[0-9A-Fa-f]"
ID_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-"
                   + f"{_HEX}{{8}}-{_HEX}{{4}}-{_HEX}{{4}}-{_HEX}{{4}}-{_HEX}{{12}}" + r"\.json$")


AUDIO_RE = re.compile(ID_RE.pattern[:-len(r"\.json$")] + r"\.wav$")


def audio_name(copy_id: str) -> str:
    """The recording beside a copy: the same name, .wav."""
    return copy_id[:-len(".json")] + ".wav"


def is_copy_id(copy_id: str) -> bool:
    """A copy's name — the whole string, no trailing newline — with a stamp
    that is a real date (no month 13)."""
    if not ID_RE.fullmatch(copy_id):
        return False
    try:
        datetime.strptime(copy_id[:20], "%Y-%m-%dT%H-%M-%SZ")
    except ValueError:
        return False
    return True


def directory() -> Path:
    override = os.environ.get("REED_REVIEW_DIR")
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "Reed" / "Review"


def domain() -> str:
    return os.environ.get("REED_REVIEW_DOMAIN", "com.local.reed")


def key_is_on() -> bool:
    """The developer's opt-in, as the app will read it at the next dictation."""
    out = subprocess.run(["defaults", "read", domain(), KEY], capture_output=True, text=True)
    return out.returncode == 0 and out.stdout.strip() == "1"


def _copies(dir_: Path) -> list[Path]:
    """Regular files with a copy's name; a directory or link named like one is not a copy."""
    if not dir_.is_dir():
        return []
    return sorted(p for p in dir_.iterdir() if is_copy_id(p.name) and p.is_file() and not p.is_symlink())


def _recordings(dir_: Path) -> list[Path]:
    """Regular files with a recording's name (a copy's name, .wav)."""
    if not dir_.is_dir():
        return []
    return sorted(p for p in dir_.iterdir() if AUDIO_RE.fullmatch(p.name) and is_copy_id(p.name[:-4] + ".json")
                  and p.is_file() and not p.is_symlink())


def audio_path(copy_id: str, dir_: Path | None = None) -> Path | None:
    """The recording beside a copy, or None when there is none. A malformed id
    or a link is refused the same way `load` refuses them."""
    if not is_copy_id(copy_id):
        raise ValueError("not a review copy id")
    dir_ = dir_ or directory()
    candidate = dir_ / audio_name(copy_id)
    if candidate.is_symlink():
        raise ValueError("not a review copy")
    path = candidate.resolve()
    if path.parent != dir_.resolve():
        raise ValueError("outside the review directory")
    return path if path.is_file() else None


def _created(p: Path) -> float:
    """The dictation's time, from the file's name — never a filesystem date
    (an atomic rewrite resets creation time; the app expires on the same stamp)."""
    return datetime.strptime(p.name[:20], "%Y-%m-%dT%H-%M-%SZ").replace(tzinfo=timezone.utc).timestamp()


def load(copy_id: str, dir_: Path | None = None) -> dict:
    """One copy by id; a malformed id or a path outside the directory is refused."""
    if not is_copy_id(copy_id):
        raise ValueError("not a review copy id")
    dir_ = dir_ or directory()
    candidate = dir_ / copy_id
    # Judged BEFORE resolving: a symlink named like a copy is not a copy,
    # wherever it points (review 2026-09-05).
    if candidate.is_symlink():
        raise ValueError("not a review copy")
    path = candidate.resolve()
    if path.parent != dir_.resolve():
        raise ValueError("outside the review directory")
    if not path.exists():
        raise FileNotFoundError(copy_id)
    if not path.is_file():
        raise ValueError("not a review copy")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def summary(record: dict, copy_id: str, path: Path) -> dict:
    """The list row: content-free apart from a short preview of the typed text."""
    final = record.get("finalText", "")
    return {
        "id": copy_id,
        "startedAt": record.get("startedAt"),
        "reviewed": record.get("reference") is not None,
        "segments": len(record.get("segments", [])),
        # Pause seams (a segment sealed by a pause): the seam bench scores a
        # copy only once a reviewer set its reference, so these are the copies
        # to review first (seam experiment, 2026-09-10).
        "pauses": sum(1 for s in record.get("segments", []) if s.get("boundary") == "pause"),
        "chunks": len(record.get("chunks", [])),
        "engine": record.get("engine"),
        "mode": record.get("mode"),
        "preview": (final[:80] + "…") if len(final) > 80 else final,
        "expiresAt": expiry(_created(path)),
        "audio": bool(record.get("audioFile")) and (path.parent / audio_name(path.name)).is_file(),
    }


def expiry(created: float) -> str:
    return (datetime.fromtimestamp(created, timezone.utc) + timedelta(days=MAX_AGE_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")


def listing(dir_: Path | None = None) -> list[dict]:
    dir_ = dir_ or directory()
    rows = []
    for p in _copies(dir_):
        try:
            with open(p, encoding="utf-8") as fh:
                rows.append(summary(json.load(fh), p.name, p))
        except (OSError, ValueError):
            rows.append({"id": p.name, "unreadable": True})
    return rows


def state(dir_: Path | None = None) -> dict:
    """The panel: on/off, count, bytes, oldest copy's expiry, unreviewed."""
    dir_ = dir_ or directory()
    copies = _copies(dir_)
    rows = listing(dir_)
    oldest = min((_created(p) for p in copies), default=None)
    expires = None
    if oldest is not None:
        expires = (datetime.fromtimestamp(oldest, timezone.utc) + timedelta(days=MAX_AGE_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "collecting": key_is_on(),
        "count": len(copies),
        "bytes": sum(p.stat().st_size for p in copies + _recordings(dir_)),
        "withAudio": sum(1 for r in rows if r.get("audio")),
        # Recordings on disk, orphaned ones included: Delete must see them
        # even when no copy is left (review 2026-09-07).
        "recordings": len(_recordings(dir_)),
        "oldestExpires": expires,
        "unreviewed": sum(1 for r in rows if not r.get("reviewed") and not r.get("unreadable")),
        "directory": str(dir_),
    }


def save_reference(copy_id: str, text: str, edited: bool, dir_: Path | None = None, set_by: str = "human") -> dict:
    """Write the human's reference into the copy, in place. Returns the reference."""
    dir_ = dir_ or directory()
    record = load(copy_id, dir_)
    reference = {"text": text, "setBy": set_by, "setAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "edited": bool(edited)}
    record["reference"] = reference
    path = dir_ / copy_id
    with open(path, "w", encoding="utf-8") as fh:  # in place: creation date untouched
        json.dump(record, fh, indent=2, sort_keys=True, ensure_ascii=False)
    return reference


def delete_all(dir_: Path | None = None) -> dict:
    """Remove every copy and every recording. One that cannot be removed stays and is named."""
    dir_ = dir_ or directory()
    removed, failed = [], []
    for p in _copies(dir_) + _recordings(dir_):
        try:
            p.unlink()
            removed.append(p.name)
        except OSError as exc:
            failed.append(f"{p.name}: {exc.strerror}")
    return {"removed": len(removed), "failed": failed}


# ---- what the review pane shows ----

def heard(record: dict) -> list[dict]:
    """The recognizer's segments in order, each with its boundary and the
    seam decision assembly made before it."""
    return [{"index": s.get("index"), "boundary": s.get("boundary"), "raw": s.get("raw", ""),
             "corrected": s.get("corrected", ""), "joinedBy": s.get("joinedBy"),
             "cleanupPath": s.get("cleanupPath"), "cleanupReason": s.get("cleanupReason")}
            for s in sorted(record.get("segments", []), key=lambda s: s.get("index", 0))]


def chunk_lines(record: dict) -> list[str]:
    """One content-free line per chunk: outcome, attempts, gate reasons."""
    lines = []
    for c in record.get("chunks", []):
        attempts = ", ".join(f"{a.get('kind')}→{a.get('verdict', '?')} {a.get('seconds', 0):.1f}s" for a in c.get("attempts", []))
        span = c.get("segments") or ([c["segment"]] if "segment" in c else [])
        line = f"chunk (seg {'-'.join(str(i) for i in span)}) · {c.get('outcome')}"
        if attempts:
            line += f" · {attempts}"
        if c.get("reason"):
            line += f" · {c['reason']}"
        lines.append(line)
    return lines
