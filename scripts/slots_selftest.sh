#!/bin/bash
# Self-test of scripts/slots.sh in a private lock dir (~2 min): FIFO order, idle reclaim, no false reclaim of a busy
# holder, a hung holder with a polling child IS reclaimed, the hang watchdog frees the slot. Exit 1 on any FAIL.
R="$(cd "$(dirname "$0")/.." && pwd)"
export MONTAGE_LOCK_DIR="$(mktemp -d)/locks"
export MONTAGE_SLOTS=1
LOG="$(dirname "$MONTAGE_LOCK_DIR")/order.log"
fail=0
holder() { # name seconds
  bash -c "source $R/scripts/slots.sh; slots_acquire; echo \"$1 got \$(date +%s)\" >> $LOG; sleep $2" 2>/dev/null
}
echo "== FIFO"
holder A 6 & sleep 1
holder B 1 & sleep 1
holder C 1 & sleep 0.5
holder D 1 &
wait
cat "$LOG"
order="$(awk '{print $1}' "$LOG" | paste -sd' ' -)"
[[ "$order" == "A B C D" ]] && echo "PASS fifo" || { echo "FAIL fifo: $order"; fail=1; }
ls "$MONTAGE_LOCK_DIR/queue" | wc -l | awk '{ if ($1 == 0) print "PASS queue empty"; else print "FAIL queue not empty" }'

echo "== idle reclaim (6 s)"
export MONTAGE_SLOT_IDLE_SECS=6
bash -c "source $R/scripts/slots.sh; slots_acquire; sleep 60" 2>/dev/null & HP=$!
sleep 1
T0=$(date +%s)
bash -c "source $R/scripts/slots.sh; slots_acquire; echo got" 2>&1 | grep -E "reclaimed|got" | tail -2
dt=$(( $(date +%s) - T0 ))
kill -0 $HP 2>/dev/null && { echo "FAIL idle holder still alive"; fail=1; } || echo "PASS idle holder reclaimed+killed after ${dt}s"

echo "== busy holder (long-lived work, one 11 s process after another) is not reclaimed (idle 15 s, 36 s observed)"
export MONTAGE_SLOT_IDLE_SECS=15
bash -c "source $R/scripts/slots.sh; slots_acquire; for i in 1 2 3; do /bin/sh -c 'sleep 11; true'; done; echo busy-done" 2>/dev/null & HP=$!
sleep 1
( for i in $(seq 1 17); do bash -c "source $R/scripts/slots.sh; slots_sweep" 2>&1; sleep 2; done ) | grep reclaimed && { echo "FAIL busy holder reclaimed"; fail=1; } || echo "PASS busy holder kept"
wait $HP
echo "== hung holder with a polling child (a 2 s probe process after another) IS reclaimed (idle 15 s)"
bash -c "source $R/scripts/slots.sh; slots_acquire; while :; do /bin/sh -c 'ps -o pid= -p 1 >/dev/null; sleep 2; true'; done" 2>/dev/null & HP=$!
sleep 1
T0=$(date +%s)
out="$( for i in $(seq 1 20); do bash -c "source $R/scripts/slots.sh; slots_sweep" 2>&1; kill -0 $HP 2>/dev/null || break; sleep 2; done )"
echo "$out" | grep reclaimed
kill -0 $HP 2>/dev/null && { echo "FAIL hung polling holder not reclaimed"; kill $HP; fail=1; } || echo "PASS hung polling holder reclaimed after $(( $(date +%s) - T0 )) s"
unset MONTAGE_SLOT_IDLE_SECS

echo "== hang watchdog frees the slot (MONTAGE_HANG_MINUTES=1)"
MONTAGE_HANG_MINUTES=1 MONTAGE_WATCHDOG_POLL=5 bash -c "source $R/scripts/slots.sh; slots_acquire; run_watched "$(dirname "$MONTAGE_LOCK_DIR")/hang.log" sleep 600; echo rc=\$?" 2>&1 | tail -2
ls -d "$MONTAGE_LOCK_DIR"/slot.* 2>/dev/null && { echo "FAIL slot still held"; fail=1; } || echo "PASS slot released after watchdog kill"
rm -rf "$(dirname "$MONTAGE_LOCK_DIR")" "$(dirname "$MONTAGE_LOCK_DIR")/hang.log"*
exit $fail
