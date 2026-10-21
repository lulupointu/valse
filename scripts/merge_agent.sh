#!/bin/bash
# Orchestrator: merge a finished agent branch.
#   1. checks the branch passed the full gate: <its worktree>/build/check_clean.ok names the branch head, mode "ui"
#      (written by scripts/check_clean.sh --ui on success)
#   2. fast-forwards main (in the main checkout) to the branch — never a merge commit, never a reset
#   3. scripts/build_app.sh in the main checkout (build/Montage.app)
#   4. removes that worktree's .build (≈ 0.85 GB; the worktree and branch are kept)
# Usage: scripts/merge_agent.sh <branch> [--skip-gate-check] [--no-build-app] [--keep-build]
set -euo pipefail
BR=""; GATE=1; APP=1; KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-gate-check) GATE=0; shift;;
    --no-build-app) APP=0; shift;;
    --keep-build) KEEP=1; shift;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    -*) echo "unknown arg $1"; exit 2;;
    *) BR="$1"; shift;;
  esac
done
[[ -n "$BR" ]] || { sed -n '2,8p' "$0"; exit 2; }
cd "$(dirname "$0")/.."
MAIN="$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)"
HEAD_HASH="$(git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$BR")" || { echo "✘ no branch $BR"; exit 1; }
WT="$(git -C "$MAIN" worktree list --porcelain | awk -v b="refs/heads/$BR" '/^worktree /{w=substr($0,10)} $0 == "branch " b {print w}')"
echo "▶ $BR @ $(git -C "$MAIN" rev-parse --short "$HEAD_HASH")${WT:+ (worktree $WT)}"

if [[ $GATE == 1 ]]; then
  STAMP="${WT:+$WT/build/check_clean.ok}"
  if [[ -z "$STAMP" || ! -f "$STAMP" ]]; then
    echo "✘ no passing gate for $BR (no ${STAMP:-worktree build/check_clean.ok}): run scripts/check_clean.sh --ui in its worktree (or --skip-gate-check)"; exit 1
  fi
  read -r S_HASH S_DATE S_MODE S_EXTRA < "$STAMP"   # S_EXTRA: e.g. perf-unverified=N (check_clean)
  if [[ "$S_HASH" != "$HEAD_HASH" || "$S_MODE" != ui ]]; then
    echo "✘ the last passing gate ($S_MODE, $S_DATE) was for $(git -C "$MAIN" rev-parse --short "$S_HASH" 2>/dev/null || echo "$S_HASH"), not $BR @ $(git -C "$MAIN" rev-parse --short "$HEAD_HASH") with --ui"
    echo "  re-run scripts/check_clean.sh --ui in $WT (or pass --skip-gate-check)"; exit 1
  fi
  echo "✔ gate: check_clean --ui passed for this commit ($S_DATE)"
fi

[[ "$(git -C "$MAIN" symbolic-ref --short -q HEAD)" == main ]] || { echo "✘ the main checkout ($MAIN) is not on main"; exit 1; }
BEFORE="$(git -C "$MAIN" rev-parse --short main)"
if ! git -C "$MAIN" merge --ff-only "$BR"; then
  echo "✘ fast-forward failed: main moved (rebase $BR on main and re-run the gate) or local changes in $MAIN block it"; exit 1
fi
echo "✔ main $BEFORE → $(git -C "$MAIN" rev-parse --short main)"

if [[ $APP == 1 ]]; then
  LOG="$MAIN/build/merge_agent-build_app.log"; mkdir -p "$MAIN/build"
  if (cd "$MAIN" && scripts/build_app.sh) > "$LOG" 2>&1; then echo "✔ $(tail -1 "$LOG") built"
  else echo "✘ build_app.sh failed (see $LOG)"; tail -5 "$LOG"; exit 1; fi
fi

if [[ $KEEP == 0 && -n "$WT" && "$(cd "$WT" && pwd -P)" != "$MAIN" && -d "$WT/.build" ]]; then
  SZ="$(du -sh "$WT/.build" 2>/dev/null | awk '{print $1}')"
  rm -rf "$WT/.build"
  echo "✔ removed $WT/.build ($SZ)"
fi
echo "MERGED $BR"
