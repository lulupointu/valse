#!/bin/bash
# Clean-checkout gate: run before reporting "ready to merge" (docs/AGENT_GUIDE.md).
# 1. Fails if any file under app/ or scripts/ is git-ignored. Such files build locally but are never committed
#    (e.g. a `models/` rule silently hid app/Sources/MontageAI/Models on case-insensitive macOS).
# 2. Builds and tests a fresh detached worktree of HEAD in a temp dir, so only committed files count.
#    Uncommitted changes are NOT part of the check: commit first.
#
# Usage: scripts/check_clean.sh [--build-only] [--ui] [--keep]
#   --build-only  build (incl. tests) but don't run scripts/test.sh
#   --ui          also run every UI test script (scripts/uitest.sh --all) in the clean tree
#   --keep        keep the temp worktree (its path is printed)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TEST=1; UI=0; KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) TEST=0; shift;;
    --ui) UI=1; shift;;
    --keep) KEEP=1; shift;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done

FAIL=0
IGNORED="$(git ls-files -o -i --exclude-standard -- app scripts)"
if [[ -n "$IGNORED" ]]; then
  echo "✘ git-ignored files under app/ or scripts/ (they will never be committed; fix .gitignore or move them):"
  echo "$IGNORED" | sed 's/^/    /'
  FAIL=1
fi
UNTRACKED="$(git ls-files -o --exclude-standard -- app scripts docs Package.swift)"
if [[ -n "$UNTRACKED" ]]; then
  echo "⚠︎ untracked files (not in HEAD, so not in the clean build — commit them if they matter):"
  echo "$UNTRACKED" | sed 's/^/    /'
fi
if ! git diff --quiet HEAD -- app scripts Package.swift; then
  echo "⚠︎ uncommitted changes under app/ scripts/ Package.swift are not part of this check"
fi

TMP="$(mktemp -d -t montage-clean)"
WT="$TMP/wt"
cleanup() {
  if [[ $KEEP == 1 ]]; then echo "kept clean worktree: $WT"; return; fi
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  git worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
git worktree add --detach --quiet "$WT" HEAD
echo "▶ clean worktree of $(git rev-parse --short HEAD) at $WT"
# Reuse the bench media (gitignored, large) if present; perf smoke tests stay opt-in anyway.
[[ -e "$ROOT/bench/media" ]] && ln -s "$(cd "$ROOT/bench/media" && pwd -P)" "$WT/bench/media" 2>/dev/null || true

cd "$WT"
if ! swift build --build-tests >"$TMP/build.log" 2>&1; then
  echo "✘ clean build failed:"; grep -E "error:" "$TMP/build.log" | sort -u | head -30
  cp "$TMP/build.log" "$ROOT/build/check_clean-build.log" 2>/dev/null || true
  exit 1
fi
echo "✔ clean build"
if [[ $TEST == 1 ]]; then
  if scripts/test.sh >"$TMP/test.log" 2>&1; then echo "✔ clean tests ($(grep -oE 'Test run with [0-9]+ tests' build/test.log | head -1))"
  else
    echo "✘ clean tests failed:"; grep -E "✘|error:" build/test.log | head -30
    mkdir -p "$ROOT/build"; cp build/test.log "$ROOT/build/check_clean-test.log" 2>/dev/null || true
    FAIL=1
  fi
fi
if [[ $UI == 1 ]]; then
  if scripts/uitest.sh --all --out "$TMP/uitest" >"$TMP/ui.log" 2>&1; then echo "✔ clean UI tests"
  else echo "✘ clean UI tests failed:"; grep -E "^✘|failed:" "$TMP/ui.log" | head -20; FAIL=1; fi
fi
[[ $FAIL == 0 ]] && echo "CLEAN CHECKOUT OK" || { echo "CLEAN CHECKOUT FAILED"; exit 1; }
