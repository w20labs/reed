#!/usr/bin/env bash
# Local review (P16, DECIDED 2026-09-04): the explicit opt-in for keeping a
# text-only review copy of each dictation on THIS Mac, for the QA page.
#
#   scripts/qa/review.sh on       write the key; the app keeps copies from the next dictation
#   scripts/qa/review.sh off      remove the key; copies already kept stay until expiry or Delete
#   scripts/qa/review.sh status   report the key and the copies on disk
#
# This is the only thing that writes reed.localReview; the QA launcher never
# does. Text plus the dictation's recording (for the corpus bench), never shared;
# 14-day expiry; ~/Library/Application Support/Reed/Review/.
set -euo pipefail

DOMAIN="${REED_REVIEW_DOMAIN:-com.local.reed}"
KEY="reed.localReview"
DIR="${REED_REVIEW_DIR_FOR_STATUS:-$HOME/Library/Application Support/Reed/Review}"

state() {
    if [ "$(defaults read "$DOMAIN" "$KEY" 2>/dev/null || echo 0)" = "1" ]; then echo on; else echo off; fi
}

# One definition of "a copy" (local_review._copies): the app's exact name on
# a regular file — a stray .json in the directory is not counted here either.
# Fails CLOSED: if the inventory cannot be taken (python, import, an
# unreadable directory) this prints nothing and returns 1 — never "0 copies".
copies() {
    local inventory n bytes
    if [ ! -d "$DIR" ]; then
        echo "0 copies · 0 bytes · $DIR"
        return 0
    fi
    inventory=$(REED_REVIEW_DIR="$DIR" PYTHONPATH="$(dirname "$0")" python3 -c '
import local_review
copies = local_review._copies(local_review.directory())
print(len(copies), sum(p.stat().st_size for p in copies))' 2>/dev/null) || return 1
    read -r n bytes <<< "$inventory"
    [ -n "$n" ] && [ -n "$bytes" ] || return 1
    echo "$n copies · $bytes bytes · $DIR"
}

# The inventory line, or a hard failure the caller cannot mistake for zero.
inventory_or_die() {
    local line
    line=$(copies) || { echo "local review: inventory unavailable — $DIR" >&2; exit 1; }
    echo "$line"
}

case "${1:-}" in
    on)
        defaults write "$DOMAIN" "$KEY" -bool YES
        echo "local review: ON — Reed keeps a review copy of each dictation on this Mac from the next dictation: the text and the recording (WAV), never shared, 14-day expiry."
        echo "turn off: scripts/qa/review.sh off"
        ;;
    off)
        defaults delete "$DOMAIN" "$KEY" >/dev/null 2>&1 || true
        inventory=$(inventory_or_die)
        echo "local review: OFF — no new copies. $inventory"
        echo "copies already kept expire after 14 days or go with Delete on the QA page."
        ;;
    status)
        inventory=$(inventory_or_die)
        echo "local review: $(state | tr a-z A-Z) · $inventory"
        ;;
    *)
        echo "usage: scripts/qa/review.sh on|off|status" >&2
        exit 2
        ;;
esac
