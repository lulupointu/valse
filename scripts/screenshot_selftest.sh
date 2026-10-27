#!/bin/bash
# Self-test of scripts/screenshot.sh --offscreen (TOOL-SCREENSHOT-HANG): runs it on the demo project with the debug
# `swift build` app (fast, incremental) and checks it exits 0 within its deadline, writes a non-empty PNG and leaves no
# Valse process behind. Never shows a window (offscreen snapshot). Exit 0 = OK.
# Usage: scripts/screenshot_selftest.sh [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,5p' "$0"; exit 0; fi
if [[ "${1:-}" != --no-build ]]; then swift build --product Valse >/dev/null; fi
BIN="$(swift build --show-bin-path)/Valse"
use_private_tmpdir screenshot-selftest
OUT="$PWD/build/screenshots/selftest-$$.png"
on_exit "rm -f '$OUT'"
T0=$(date +%s)
code=0; VALSE_SCREENSHOT_BIN="$BIN" scripts/screenshot.sh --demo --offscreen -o "$OUT" || code=$?
DT=$(( $(date +%s) - T0 ))
fail() { echo "✘ screenshot selftest: $*"; exit 1; }
[[ $code == 0 ]] || fail "screenshot.sh exited $code after ${DT}s"
[[ -s "$OUT" ]] || fail "no PNG at $OUT"
[[ "$(head -c 8 "$OUT" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]] || fail "$OUT is not a PNG"
if ps -A -o command= | grep -F -- "$OUT" | grep -v grep >/dev/null; then fail "a Valse process is still running"; fi
echo "✔ screenshot selftest OK (${DT}s)"
