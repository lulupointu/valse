# Shared helpers for the test / gate scripts (sourced, never run). bash 3.2 compatible (macOS /bin/bash).
#   on_exit <cmd>            chain an EXIT hook (runs in reverse order, also on Ctrl-C / TERM / HUP)
#   require_free_disk [GB]   fail fast when the data volume has less than GB free (default MONTAGE_MIN_FREE_GB or 5)
#   use_private_tmpdir <tag> point TMPDIR at a fresh $TMPDIR/montage-run-<tag>.XXXX removed on exit, so test leftovers
#                            (sandboxes, exports, mock downloads…) never pile up; persistent caches stay in the real TMPDIR
#   run_watched <log> <cmd…> run cmd (stdout+stderr → log) under the hang watchdog; returns its exit code, 124 = HUNG
#   tree_pids <pid> / tree_cpu <pid> / kill_tree <pid>   process-tree helpers
[[ -n "${_MONTAGE_LIB_SH:-}" ]] && return 0
_MONTAGE_LIB_SH=1

_MONTAGE_EXIT_HOOKS=()
_montage_run_exit_hooks() {
  local i
  for ((i = ${#_MONTAGE_EXIT_HOOKS[@]} - 1; i >= 0; i--)); do eval "${_MONTAGE_EXIT_HOOKS[$i]}" || true; done
  _MONTAGE_EXIT_HOOKS=()
}
on_exit() {
  _MONTAGE_EXIT_HOOKS+=("$1")
  trap _montage_run_exit_hooks EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
}

require_free_disk() {
  local need="${1:-${MONTAGE_MIN_FREE_GB:-5}}" path="${2:-.}" avail mount
  avail="$(df -Pk "$path" | awk 'NR == 2 { printf "%d", $4 / 1048576 }')"
  mount="$(df -P "$path" | awk 'NR == 2 { print $6 }')"
  if (( avail < need )); then
    echo "✘ DISK FULL: only ${avail} GB free on ${mount} (the gate needs ≥ ${need} GB: build ≈ 1 GB per worktree, UI/export temp files)." >&2
    echo "  Free space: scripts/cleanup.sh --dry-run, then scripts/cleanup.sh (merged worktrees' .build, \$TMPDIR/montage-* > 3 h)." >&2
    return 1
  fi
}

# Real (machine) temp dir, remembered across nested scripts so caches never land in a private run dir.
export MONTAGE_REAL_TMPDIR="${MONTAGE_REAL_TMPDIR:-${TMPDIR:-/tmp}}"
MONTAGE_REAL_TMPDIR="${MONTAGE_REAL_TMPDIR%/}"
# Synthetic test media is content-addressed and reused across runs (MontageTestSupport.TestMedia).
export MONTAGE_TEST_MEDIA_DIR="${MONTAGE_TEST_MEDIA_DIR:-$MONTAGE_REAL_TMPDIR/montage-test-media-v1}"

use_private_tmpdir() {
  [[ "${MONTAGE_KEEP_TMP:-0}" == 1 ]] && return 0
  local d
  d="$(mktemp -d "$MONTAGE_REAL_TMPDIR/montage-run-$1.XXXXXX")"
  export TMPDIR="$d/"
  on_exit "rm -rf '$d'"
}

tree_pids() { # root pid → it and every descendant, one per line
  ps -A -o pid=,ppid= | awk -v r="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END { q[0] = r; n = 1; for (i = 0; i < n; i++) { print q[i]; c = split(kids[q[i]], a, " "); for (j = 1; j <= c; j++) q[n++] = a[j] } }'
}

tree_cpu() { # root pid → CPU seconds used by the live tree (integer)
  local pids; pids="$(tree_pids "$1" | paste -sd, -)"
  [[ -z "$pids" ]] && { echo 0; return; }
  ps -o time= -p "$pids" 2>/dev/null | awk '
    { n = split($1, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; t += s }
    END { printf "%d", t }'
}

kill_tree() { # root pid: TERM the whole tree, KILL what is left after 3 s
  local pids; pids="$(tree_pids "$1")"
  [[ -z "$pids" ]] && return 0
  kill -TERM $pids 2>/dev/null || true
  local i; for i in 1 2 3; do sleep 1; kill -0 $pids 2>/dev/null || return 0; done
  kill -KILL $pids 2>/dev/null || true
}

# Hang watchdog. A run counts as HUNG when, for MONTAGE_HANG_MINUTES (default 10), its log did not grow AND its
# process tree used < 1 % of one core. It then appends `sample` stacks of the tree's processes to the log, kills the
# tree and leaves "<log>.hung". A legitimately slow test keeps using CPU, so it is never killed.
watchdog_start() { # log root-pid
  local log="$1" root="$2"
  (
    trap - EXIT INT TERM HUP
    limit=$(( ${MONTAGE_HANG_MINUTES:-10} * 60 )); poll="${MONTAGE_WATCHDOG_POLL:-15}"
    size=-1; since=$(date +%s); base_cpu=0
    while kill -0 "$root" 2>/dev/null; do
      sleep "$poll"
      kill -0 "$root" 2>/dev/null || break
      now=$(date +%s); s=$(stat -f %z "$log" 2>/dev/null || echo 0); c=$(tree_cpu "$root")
      if [[ "$s" != "$size" ]] || (( c - base_cpu > (now - since) / 100 + 1 )); then
        size="$s"; since="$now"; base_cpu="$c"; continue
      fi
      if (( now - since >= limit )); then
        {
          echo ""
          echo "HUNG: no new output and ~0 % CPU for $(( (now - since) / 60 )) min — process tree of PID $root:"
          ps -o pid=,ppid=,%cpu=,time=,command= -p "$(tree_pids "$root" | paste -sd, -)" 2>/dev/null
        } >> "$log"
        n=0
        for p in $(tree_pids "$root"); do
          case "$(ps -o comm= -p "$p" 2>/dev/null)" in *bash|*sh|*tee|*tail|*grep|"") continue;; esac
          (( n++ >= 4 )) && break
          echo "---- sample $p ($(ps -o comm= -p "$p" 2>/dev/null)) ----" >> "$log"
          sample "$p" 3 -file "$log.sample.$p" >/dev/null 2>&1 && cat "$log.sample.$p" >> "$log" && rm -f "$log.sample.$p"
        done
        echo "HUNG: killed after $(( (now - since) / 60 )) min without progress" >> "$log"
        touch "$log.hung"
        kill_tree "$root"
        break
      fi
    done
  ) &
  WATCHDOG_PID=$!
}

run_watched() { # log cmd… → exit code of cmd; 124 + "HUNG" message when the watchdog killed it
  local log="$1"; shift
  rm -f "$log.hung"
  "$@" > "$log" 2>&1 < /dev/null &
  local pid=$! code errexit=0
  [[ $- == *e* ]] && errexit=1
  watchdog_start "$log" "$pid"
  local wd=$WATCHDOG_PID
  set +e; wait "$pid"; code=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  (( errexit )) && set -e
  if [[ -f "$log.hung" ]]; then
    echo "✘ HUNG: '$*' made no progress (no output, ~0 % CPU) for ${MONTAGE_HANG_MINUTES:-10} min — killed; stacks in $log" >&2
    return 124
  fi
  return $code
}
