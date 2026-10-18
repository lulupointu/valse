#!/bin/bash
# Runs the localization completeness check + all tests.
# Usage: scripts/test.sh [--perf] [extra swift test args, e.g. --filter RenderTests]
#   --perf   also run the 4K perf smoke tests (needs bench/media, see bench/make_media.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--perf" ]]; then export MONTAGE_PERF=1; else ARGS+=("$a"); fi
done
mkdir -p build  # gitignored: absent in a fresh checkout
# machine-wide: at most 2 heavy runs at once across all checkouts (scripts/slots.sh)
source scripts/slots.sh; slots_acquire
python3 scripts/l10n_check.py
swift build --build-tests >&2
swift test ${ARGS[@]+"${ARGS[@]}"} 2>&1 | tee build/test.log | grep -E "✘|✔ Test run|✘ Test run|error:|metric" || true
if grep -qE "✘|error:" build/test.log; then
  echo "TESTS FAILED (see build/test.log)"; exit 1
fi
grep -qE "Test run with [0-9]+ tests? .*passed" build/test.log || { echo "no test summary found (see build/test.log)"; exit 1; }
echo "ALL GREEN"
