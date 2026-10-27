#!/bin/bash
# Machine-wide semaphore for heavy runs (swift build/test, UI scripts, perf), shared by every checkout / worktree.
# Source it, then call `slots_acquire` (one of the slots) or `slots_acquire_all` (exclusive: every slot —
# scripts/perf.sh, so timings are not disturbed by other teams). Released on exit (`slots_release`; the EXIT hook is
# chained through scripts/lib.sh `on_exit`, so callers may add their own hooks). Nested scripts (check_clean → test.sh)
# reuse the parent's slot (VALSE_SLOT_HELD).
#
# Locks are mkdir directories under /tmp/valse-locks (VALSE_LOCK_DIR) holding the owner's PID, its start time,
# command and directory. A lock is RECLAIMED (and the reclaim printed) when its holder
#   - is dead (or its PID was reused by another process), or
#   - has been idle for VALSE_SLOT_IDLE_MIN minutes (default 20): its whole process tree used < 2 CPU-seconds and
#     started no new process that lived >= 10 s (`sleep`s aside) in that time, as seen by checks ≤ 2 min apart (a hung run). The idle
#     holder's process tree is killed so it cannot resume later. (A hung build / test under scripts/lib.sh
#     `run_watched` is killed sooner by its hang watchdog; the script then exits and its EXIT hook frees the slot.)
# Slot count: VALSE_SLOTS, default min(max(2, cores / 5), max(1, RAM GB / 6)) — a gate (build + parallel tests or a
# UI app) needs ~5 cores and up to ~5 GB. Slot 0 is always offered; the others only while the 1-min load average is
# below VALSE_SLOT_MAX_LOAD (default 3 × cores), so an overloaded machine runs fewer gates at once.
# Waiters queue FIFO (ticket files in <lock dir>/queue; dead waiters' tickets are dropped): only the oldest waiting run
# may take a free slot, so a run never starves behind newer ones. The tests themselves are load-robust: this cap is for
# throughput, not for correctness. VALSE_NO_SLOTS=1 skips locking entirely.
#
# Run directly:  scripts/slots.sh status    holders, age, CPU, idle time
#                scripts/slots.sh reclaim   reclaim dead / idle slots now
SLOTS_DIR="${VALSE_LOCK_DIR:-/tmp/valse-locks}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
_SLOTS_CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
_SLOTS_MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) / 1073741824 ))
_SLOTS_BY_CPU=$(( _SLOTS_CORES / 5 > 2 ? _SLOTS_CORES / 5 : 2 ))
_SLOTS_BY_MEM=$(( _SLOTS_MEM_GB / 6 > 1 ? _SLOTS_MEM_GB / 6 : 1 ))
SLOTS_N="${VALSE_SLOTS:-$(( _SLOTS_BY_CPU < _SLOTS_BY_MEM ? _SLOTS_BY_CPU : _SLOTS_BY_MEM ))}"
SLOTS_TICKET=""
SLOTS_IDLE_SECS=$(( ${VALSE_SLOT_IDLE_MIN:-20} * 60 ))
[[ -n "${VALSE_SLOT_IDLE_SECS:-}" ]] && SLOTS_IDLE_SECS="$VALSE_SLOT_IDLE_SECS"   # tests of the reclaim itself
SLOTS_MAX_LOAD="${VALSE_SLOT_MAX_LOAD:-$(( _SLOTS_CORES * 3 ))}"
SLOTS_HELD=()
_SLOTS_CMD="$0${*:+ $*}"   # the sourcing script and its arguments (positional parameters are inherited by `source`)

_slot_lstart() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

_slot_write() { # dir: fill in the owner record (we just created the dir)
  local d="$1"
  echo "$$" > "$d/pid.tmp"
  _slot_lstart $$ > "$d/start"
  echo "$_SLOTS_CMD" > "$d/cmd"
  pwd > "$d/cwd"
  echo "$(date +%s) $(tree_cpu $$) - $(date +%s)" > "$d/activity"   # since, CPU, tree signature, last check
  mv "$d/pid.tmp" "$d/pid"
}

# _slot_check <dir> → 0 if the lock was reclaimed (removed); prints why. Also refreshes its activity record.
_slot_check() {
  local d="$1" pid now
  [[ -d "$d" ]] || return 0
  pid="$(cat "$d/pid" 2>/dev/null || true)"
  now=$(date +%s)
  if [[ -z "$pid" ]]; then
    # being created right now, or the creator died before writing its PID: reclaim if older than 30 s
    local m; m="$(stat -f %m "$d" 2>/dev/null || echo "$now")"
    if (( now - m > 30 )); then rm -rf "$d"; echo "slots: reclaimed $(basename "$d") (no owner PID for $(( now - m )) s)" >&2; return 0; fi
    return 1
  fi
  local what; what="$(cat "$d/cmd" 2>/dev/null || echo '?') in $(cat "$d/cwd" 2>/dev/null || echo '?')"
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$d"; echo "slots: reclaimed $(basename "$d") from dead PID $pid ($what)" >&2; return 0
  fi
  if [[ -f "$d/start" && "$(cat "$d/start")" != "$(_slot_lstart "$pid")" ]]; then
    rm -rf "$d"; echo "slots: reclaimed $(basename "$d") from PID $pid (PID reused by another process; was $what)" >&2; return 0
  fi
  # a holder that is itself waiting for more slots (slots_acquire_all) touches its heartbeat: not idle
  if [[ -f "$d/heartbeat" ]] && (( now - $(stat -f %m "$d/heartbeat" 2>/dev/null || echo 0) < 60 )); then return 1; fi
  # Activity = the live tree's CPU total moved by > 2 s, or its set of PIDs changed (a UI suite runs one short app
  # per script: their CPU totals rise and reset, so a CPU snapshot alone can look unchanged across a busy run).
  # Idleness is only judged from continuous observation (checks ≤ 120 s apart: waiters sweep every 2 s); after a gap
  # the record restarts, so one late check can never compare against a stale snapshot and kill a healthy run.
  local cpu sig since base bsig seen
  cpu="$(tree_cpu "$pid")"
  # (`sleep`s of polling loops / watchdogs don't count: a hung run under a watchdog still spawns those)
  # only processes alive >= 10 s count: short-lived children (a watchdog's sleep / ps / awk, a polling loop's probes)
  # churn constantly even in a hung run; a busy run keeps starting long-lived work (apps, compilers, test processes)
  sig="$(ps -o pid=,etime=,comm= -p "$(tree_pids "$pid" | paste -sd, -)" 2>/dev/null | awk '
    { e = $2; if (index(e, "-")) s = 99999; else { n = split(e, a, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i] }
      if (s >= 10 && $3 !~ /sleep$/) print $1 }' | sort -n | paste -sd, - | cksum | awk '{print $1}')"
  { read -r since base bsig seen < "$d/activity"; } 2>/dev/null || true
  if [[ -z "${since:-}" || -z "${seen:-}" ]] || (( now - seen > 120 )) || [[ "$sig" != "$bsig" ]] || (( cpu - base > 2 || base - cpu > 2 )); then
    echo "$now $cpu $sig $now" > "$d/activity" 2>/dev/null || true; return 1
  fi
  echo "$since $base $bsig $now" > "$d/activity" 2>/dev/null || true
  if (( now - since >= SLOTS_IDLE_SECS )); then
    local mins=$(( (now - since) / 60 ))
    kill_tree "$pid" >/dev/null 2>&1 || true
    rm -rf "$d"
    echo "slots: reclaimed $(basename "$d") from PID $pid — idle (~0 % CPU incl. children) for ${mins} min, process tree killed ($what)" >&2
    return 0
  fi
  return 1
}

_slot_try() { # dir → 0 if acquired
  local d="$1"
  if mkdir "$d" 2>/dev/null; then _slot_write "$d"; SLOTS_HELD+=("$d"); return 0; fi
  if _slot_check "$d" && mkdir "$d" 2>/dev/null; then _slot_write "$d"; SLOTS_HELD+=("$d"); return 0; fi
  return 1
}

slots_sweep() { # check every lock (refreshes idle tracking; reclaims dead / idle holders)
  local d
  for d in "$SLOTS_DIR"/slot.* "$SLOTS_DIR"/exclusive; do
    if [[ -d "$d" ]]; then _slot_check "$d" || true; fi   # (a bare `&&` here would trip callers' set -e)
  done
  return 0
}

_slots_wait_msg() {
  local holders ahead=0 t
  holders="$(cat "$SLOTS_DIR"/*/pid 2>/dev/null | tr '\n' ' ')"
  for t in $(ls "$SLOTS_DIR/queue" 2>/dev/null | sort); do
    [[ "$SLOTS_DIR/queue/$t" == "$SLOTS_TICKET" ]] && break
    ahead=$((ahead + 1))
  done
  echo "waiting for test slot… (held by PIDs: ${holders:-?}; ${ahead} run(s) queued ahead; scripts/slots.sh status for details)" >&2
}

_slots_load_ok() { # 0 when the 1-min load average is below SLOTS_MAX_LOAD
  local l; l="$(sysctl -n vm.loadavg 2>/dev/null | awk '{ printf "%d", $2 }')"
  (( ${l:-0} < SLOTS_MAX_LOAD ))
}

# FIFO queue: one ticket per waiting run, <lock dir>/queue/<enqueue time ns>.<pid> holding the waiter's start time.
_slots_ticket_take() {
  mkdir -p "$SLOTS_DIR/queue"
  SLOTS_TICKET="$SLOTS_DIR/queue/$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null || echo "$(date +%s)000000000").$$"
  _slot_lstart $$ > "$SLOTS_TICKET"
}
_slots_ticket_drop() {
  if [[ -n "$SLOTS_TICKET" ]]; then rm -f "$SLOTS_TICKET"; fi
  SLOTS_TICKET=""
}
_slots_first_in_line() { # 0 when our ticket is the oldest live one (drops dead waiters' tickets on the way)
  local t pid
  for t in $(ls "$SLOTS_DIR/queue" 2>/dev/null | sort); do
    pid="${t##*.}"
    if ! kill -0 "$pid" 2>/dev/null || [[ "$(cat "$SLOTS_DIR/queue/$t" 2>/dev/null)" != "$(_slot_lstart "$pid")" ]]; then
      rm -f "$SLOTS_DIR/queue/$t"; continue   # dead waiter (or its PID reused)
    fi
    [[ "$SLOTS_DIR/queue/$t" == "$SLOTS_TICKET" ]]; return
  done
  return 0
}

slots_acquire() {
  [[ "${VALSE_NO_SLOTS:-0}" == 1 || -n "${VALSE_SLOT_HELD:-}" ]] && return 0
  mkdir -p "$SLOTS_DIR"
  local waited=0 i
  on_exit slots_release
  _slots_ticket_take
  while true; do
    slots_sweep
    # an exclusive run (perf) is waiting or running: don't take new slots; newer waiters queue behind older ones
    if [[ ! -d "$SLOTS_DIR/exclusive" ]] && _slots_first_in_line; then
      for ((i = 0; i < SLOTS_N; i++)); do
        (( i > 0 )) && ! _slots_load_ok && break
        if _slot_try "$SLOTS_DIR/slot.$i"; then _slots_ticket_drop; export VALSE_SLOT_HELD=1; return 0; fi
      done
    fi
    (( waited % 30 == 0 )) && _slots_wait_msg
    sleep 2; waited=$((waited + 2))
  done
}

slots_acquire_all() {
  [[ "${VALSE_NO_SLOTS:-0}" == 1 || -n "${VALSE_SLOT_HELD:-}" ]] && return 0
  mkdir -p "$SLOTS_DIR"
  local waited=0 i
  on_exit slots_release
  until _slot_try "$SLOTS_DIR/exclusive"; do
    (( waited % 30 == 0 )) && _slots_wait_msg
    sleep 2; waited=$((waited + 2))
  done
  for ((i = 0; i < SLOTS_N; i++)); do
    until _slot_try "$SLOTS_DIR/slot.$i"; do
      touch "$SLOTS_DIR/exclusive/heartbeat" 2>/dev/null || true
      (( waited % 30 == 0 )) && _slots_wait_msg
      sleep 2; waited=$((waited + 2))
    done
  done
  rm -f "$SLOTS_DIR/exclusive/heartbeat"
  export VALSE_SLOT_HELD=1
}

slots_release() {
  _slots_ticket_drop
  local d
  for d in ${SLOTS_HELD[@]+"${SLOTS_HELD[@]}"}; do
    [[ "$(cat "$d/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$d"
  done
  SLOTS_HELD=()
}

slots_status() {
  local d pid now; now=$(date +%s)
  echo "slots: $SLOTS_N (cores $_SLOTS_CORES, RAM ${_SLOTS_MEM_GB} GB, extra slots only while load < $SLOTS_MAX_LOAD; load now $(sysctl -n vm.loadavg | awk '{print $2}')), idle reclaim after $(( SLOTS_IDLE_SECS / 60 )) min — $SLOTS_DIR"
  for d in "$SLOTS_DIR"/slot.* "$SLOTS_DIR"/exclusive; do
    [[ -d "$d" ]] || continue
    pid="$(cat "$d/pid" 2>/dev/null || echo '?')"
    local since base _rest; { read -r since base _rest < "$d/activity"; } 2>/dev/null || { since=$now; base=0; }
    kill -0 "$pid" 2>/dev/null || pid="$pid(dead)"
    printf "  %-10s PID %-6s held %4d min, idle %3d min, cpu %5ss  %s  (%s)\n" "$(basename "$d")" "$pid" \
      $(( (now - $(stat -f %m "$d/pid" 2>/dev/null || stat -f %m "$d")) / 60 )) $(( (now - since) / 60 )) "$(tree_cpu "$pid" 2>/dev/null)" \
      "$(cat "$d/cmd" 2>/dev/null)" "$(cat "$d/cwd" 2>/dev/null)"
  done
  local t pid
  for t in $(ls "$SLOTS_DIR/queue" 2>/dev/null | sort); do
    pid="${t##*.}"
    printf "  queued     PID %-6s %s\n" "$pid" "$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-100)"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  mkdir -p "$SLOTS_DIR"
  case "${1:-status}" in
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    status) slots_status;;
    reclaim) slots_sweep; slots_status;;
    *) sed -n '2,20p' "$0"; exit 2;;
  esac
fi
