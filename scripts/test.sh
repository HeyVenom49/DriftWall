#!/bin/bash
# Runs the automated checks:
#   1. Swift Testing unit + integration tests for DriftwallCore (swift test)
#   2. The end-to-end smoke test inside the packaged app (real AVFoundation playback on real displays),
#      using a throwaway data folder so the user's library is never touched.
#
#   scripts/test.sh            # both
#   scripts/test.sh --unit     # unit/integration tests only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/sdk_env.sh"

echo "▸ swift test"
swift test ${SWIFT_TEST_FLAGS[@]+"${SWIFT_TEST_FLAGS[@]}"}

if [ "${1:-}" == "--unit" ]; then exit 0; fi

"$ROOT/scripts/build_app.sh" release

echo "▸ Smoke test in packaged app"
SCRATCH="$(mktemp -d -t driftwall-smoke)"
trap 'rm -rf "$SCRATCH"' EXIT
DRIFTWALL_DATA_DIR="$SCRATCH" "$ROOT/build/Driftwall.app/Contents/MacOS/Driftwall" --smoke-test
