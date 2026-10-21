#!/bin/bash
# Compares two PNGs with tolerance (same algorithm as UI test baselines, docs/TESTING.md §2).
# Usage: scripts/imgdiff.sh a.png b.png [--threshold 16] [--tolerance 0.005] [--diff out.png]
# Prints a JSON result; exit 0 = match, 1 = differ, 2 = bad input.
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,4p' "$0"; exit 0; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(cd "$ROOT" && swift build --show-bin-path)/Montage"
[[ -x "$BIN" ]] || (cd "$ROOT" && swift build --product Montage >&2)
exec "$BIN" --imgdiff "$@"
