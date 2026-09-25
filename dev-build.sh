#!/usr/bin/env bash
# Fast local iteration build: debug config, native arch, no dSYM. Skips the
# release-build costs in build-app.sh (optimizer, dsymutil). "Native" on an
# Apple Silicon host is arm64; under Rosetta it would be x86_64, and
# build-app.sh refuses to package that (scripts/build/assert-arm64.sh).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=debug ARCH=native ./build-app.sh "$@"
