#!/bin/bash
# Stops Valse test / build runs started from ONE checkout (default: this one), and nothing else. The narrow, allow-listed
# replacement for `kill <pid>` / `pkill -f …` (agents may not kill arbitrary processes on the shared machine).
#   Matches only these processes: bash interpreting scripts/{test,uitest,check_fast,check_clean,test_x86,screenshot,perf}.sh
#   (argv = bash + that script; wrapper shells whose command line merely mentions it don't match), swift-build,
#   swift-test, swiftpm-testing-helper, xctest, the Valse binary (…/Valse --uitest|--screenshot…), sample.
#   A process belongs to the checkout when its cwd is inside it (agent worktrees under <checkout>/.claude/worktrees/ are
#   other checkouts and never match), or it runs in a check_clean temp worktree ($TMPDIR/valse-clean.*) and one of its
#   ancestors has its cwd inside the checkout. This script and its own ancestors are never touched. Whole process trees
#   are stopped (TERM, then KILL after 3 s); their test slots are released by their exit hooks or the next reclaim.
# Usage: scripts/kill_tests.sh [--dry-run] [--dir <checkout>]
set -euo pipefail
DIR=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY=1; shift;;
    --dir) DIR="$(cd "$2" && pwd -P)"; shift 2;;   # relative to the caller's cwd
    -h|--help) sed -n '2,11p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
cd "$(dirname "$0")/.."
[[ -n "$DIR" ]] || DIR="$(pwd -P)"
source scripts/lib.sh
CWD_FILE="$(mktemp -t valse-kill-cwd)"; PS_FILE="$(mktemp -t valse-kill-ps)"
trap 'rm -f "$CWD_FILE" "$PS_FILE"' EXIT
lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}' > "$CWD_FILE" || true
ps -A -o pid=,ppid=,command= > "$PS_FILE"

cwd_of() { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$CWD_FILE"; }
ppid_of() { awk -v p="$1" '$1 == p { print $2; exit }' "$PS_FILE"; }
# this script and every ancestor (the agent's shell, Claude Code's wrapper `zsh -c … scripts/kill_tests.sh …`)
SELF=" $$ "; a=$$
while [[ -n "$a" && "$a" != 0 && "$a" != 1 ]]; do a="$(ppid_of "$a")"; SELF+="$a "; done
NESTED=""   # DIR/.claude/worktrees: other checkouts, unless DIR is itself inside one
[[ "$DIR" == */.claude/worktrees/* ]] || NESTED="$DIR/.claude/worktrees"
inside() {
  [[ "$1" == "$DIR" || "$1" == "$DIR"/* ]] || return 1
  [[ -n "$NESTED" && ( "$1" == "$NESTED" || "$1" == "$NESTED"/* ) ]] && return 1
  return 0
}
is_test_proc() { # command line → 0 when it is one of the allowed kinds (argv[0] is checked, not a substring)
  local exe rest script
  read -r exe rest <<< "$1"
  case "$exe" in
    bash|*/bash)
      read -r script _ <<< "$rest"
      case "$script" in
        scripts/test.sh|scripts/uitest.sh|scripts/check_fast.sh|scripts/check_clean.sh|scripts/test_x86.sh|scripts/screenshot.sh|scripts/perf.sh) return 0;;
        */scripts/test.sh|*/scripts/uitest.sh|*/scripts/check_fast.sh|*/scripts/check_clean.sh|*/scripts/test_x86.sh|*/scripts/screenshot.sh|*/scripts/perf.sh) return 0;;
      esac; return 1;;
    */swift-build|*/swift-test|*/swiftpm-testing-helper|*/xctest|/usr/bin/sample|sample) return 0;;
    */Valse) [[ " $rest " == *" --uitest "* || " $rest " == *" --screenshot"* || " $rest " == *" --snapshot"* ]];;
    *) return 1;;
  esac
}
belongs() { # pid → 0 when it runs for $DIR
  local pid="$1" c a n=0
  c="$(cwd_of "$pid")"
  inside "$c" && return 0
  [[ "$c" == */valse-clean.* ]] || return 1
  a="$(ppid_of "$pid")"
  while [[ -n "$a" && "$a" != 0 && "$a" != 1 && $n -lt 30 ]]; do
    inside "$(cwd_of "$a")" && return 0
    a="$(ppid_of "$a")"; n=$((n + 1))
  done
  return 1
}

ROOTS=()
while read -r pid ppid cmd; do
  [[ "$SELF" == *" $pid "* ]] && continue
  is_test_proc "$cmd" || continue
  belongs "$pid" || continue
  # keep only the top of each matching tree: skip a process whose parent also matches
  pcmd="$(awk -v p="$ppid" '$1 == p { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }' "$PS_FILE")"
  if [[ -n "$pcmd" ]] && is_test_proc "$pcmd" && belongs "$ppid"; then continue; fi
  ROOTS+=("$pid")
  echo "$([[ $DRY == 1 ]] && echo "would stop" || echo "stopping") PID $pid: $(cut -c1-150 <<< "$cmd")"
done < "$PS_FILE"
[[ ${#ROOTS[@]} == 0 ]] && { echo "no Valse test processes running for $DIR"; exit 0; }
[[ $DRY == 1 ]] && exit 0
for p in "${ROOTS[@]}"; do kill_tree "$p"; done
echo "stopped ${#ROOTS[@]} process tree(s) for $DIR"
