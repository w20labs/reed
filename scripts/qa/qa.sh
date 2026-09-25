#!/usr/bin/env bash
# Start the local Reed QA page and open it. Local only; never part of the app.
set -euo pipefail
cd "$(dirname "$0")/../.."
PORT="${REED_QA_PORT:-8797}"
# Local review (P16, DECIDED 2026-09-04) is a separate, explicit opt-in:
# scripts/qa/review.sh on|off|status. This launcher never writes that key.
if ! curl -fsS "http://localhost:$PORT/status" >/dev/null 2>&1; then
    echo "==> building tests once (Xcode toolchain)"
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --toolchain XcodeDefault swift build --build-tests 2>&1 | grep -E "error:|Build complete" || true
    nohup python3 scripts/qa/qa_server.py > docs/bench/qa/server.log 2>&1 &
    sleep 1
fi
open "http://localhost:$PORT"
echo "Reed QA: http://localhost:$PORT   (stop: pkill -f qa_server.py)"
