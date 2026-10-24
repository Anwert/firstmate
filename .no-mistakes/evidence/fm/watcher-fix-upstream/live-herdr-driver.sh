#!/usr/bin/env bash
# Live driver: real herdr lab session + real fm-watch-arm.sh/fm-watch.sh in a lab FM_HOME.
# usage: live.sh <repo-root> <label> <evidence-log>
set -u
ROOT=$1 LABEL=$2 LOG=$3
exec > >(tee -a "$LOG") 2>&1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }
dt() { python3 -c "print(f'{$2-$1:.2f}')"; }
. "$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name "nm-$LABEL")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
WTMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-wtmp.XXXXXX")
cleanup() {
  [ -n "${ARM_PIDS:-}" ] && kill -TERM $ARM_PIDS 2>/dev/null
  local w; w=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null); [ -n "$w" ] && kill -TERM "$w" 2>/dev/null
  sleep 1
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" >/dev/null 2>&1 || echo "WARN teardown failed for $SESSION"
  rm -rf "$LAB" "$WTMP"
}
trap cleanup EXIT
echo "=== [$LABEL] fm-watch.sh blob $(git -C "$ROOT" hash-object bin/fm-watch.sh) bash=$BASH_VERSION herdr=$(herdr --version | head -1)"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home create failed"; exit 1; }
"$ROOT/bin/fm-herdr-lab.sh" prepare "$SESSION" >/dev/null || { echo "herdr lab prepare failed"; exit 1; }
export HERDR_SESSION="$SESSION"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
fm_backend_herdr_events_capable "$SESSION" || { echo "herdr events not capable"; exit 1; }
CRAW=$(fm_backend_herdr_container_ensure /tmp) || { echo container_ensure failed; exit 1; }
IDS=$(fm_backend_herdr_create_task "${CRAW%%$'\t'*}" fm-nmlive /tmp "${CRAW#*$'\t'}") || { echo create_task failed; exit 1; }
read -r _TAB PANE <<<"$IDS"
SOCK=$(fm_backend_herdr_socket_path "$SESSION"); echo "lab session=$SESSION pane=$PANE sock=$SOCK"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane report-agent "$PANE" --source fm-nm-live --agent claude --state working >/dev/null
printf 'window=%s:%s\nbackend=herdr\nkind=ship\n' "$SESSION" "$PANE" > "$LAB/state/nmlive.meta"
STATE="$LAB/state"
ARM_ENV=(env FM_HOME="$LAB" TMPDIR="$WTMP" FM_POLL=15 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999)
reader_count() { local n=0 p; for p in $(pgrep -f herdr-eventwait); do ps -o command= -p "$p" 2>/dev/null | grep -qF "$SOCK" && n=$((n+1)); done; echo $n; }
fifo_dirs() { { ls -d "$WTMP"/fm-herdr-eventwait.* "$STATE"/.fm-event-wait.*/fm-herdr-eventwait.* 2>/dev/null; } | wc -l | tr -d ' '; }
wait_in_event_wait() {  # watcher pid
  local i=0; while [ $i -lt 200 ]; do [ "$(reader_count)" -gt 0 ] && return 0; sleep 0.05; i=$((i+1)); done; return 1; }
start_arm() {  # outfile [args]
  local out=$1; shift
  "${ARM_ENV[@]}" "$ROOT/bin/fm-watch-arm.sh" "$@" > "$out" 2>&1 &
  LAST_ARM=$!; ARM_PIDS="${ARM_PIDS:-} $LAST_ARM"
  local i=0; while [ $i -lt 400 ] && ! grep -q '^watcher: \(started\|attached\|FAILED\)' "$out"; do sleep 0.05; i=$((i+1)); done
}

main_ack() {  # main's handling turn: drain the queue and acknowledge it with the printed command
  local err="$LAB/drain.err" seq gen
  "${ARM_ENV[@]}" "$ROOT/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && "${ARM_ENV[@]}" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  echo "main handled+acked queue (seq=${seq:-none}); .watcher-down=$(cut -c1-40 "$STATE/.watcher-down" 2>/dev/null)"
}

echo "--- S0: direct TERM to a watcher held in the real Herdr push-event wait (FM_POLL=15)"
for n in 1 2 3; do
  start_arm "$LAB/arm-0.out"; A0=$LAST_ARM
  W0=$(cat "$STATE/.watch.lock/pid")
  wait_in_event_wait "$W0" || echo "WARN: W0 not in event wait"; sleep 1
  T0=$(now); kill -TERM "$W0"
  while kill -0 "$W0" 2>/dev/null && [ "$(dt $T0 $(now) | cut -d. -f1)" -lt 30 ]; do sleep 0.02; done; T1=$(now)
  sleep 0.3
  echo "run $n: watcher $W0 TERM->exit $(dt $T0 $T1)s; live lab readers after: $(reader_count); reader FIFO dirs: $(fifo_dirs); .fm-event-wait dirs: $(ls -d "$STATE"/.fm-event-wait.* 2>/dev/null | wc -l | tr -d ' ')"
  wait "$A0" 2>/dev/null
  main_ack >/dev/null
done
main_ack

echo "--- S1: take-over while the owner's watcher is in the real Herdr push-event wait"
start_arm "$LAB/arm-a.out"; ARM_A=$LAST_ARM
echo "arm A: $(head -1 "$LAB/arm-a.out")"
W1=$(cat "$STATE/.watch.lock/pid")
wait_in_event_wait "$W1" || echo "WARN: watcher never entered event wait"
main_ack
sleep 1
echo "watcher W1=$W1 in event wait; live readers=$(reader_count); event-wait dirs: $(ls -d "$STATE"/.fm-event-wait.* 2>/dev/null | wc -l | tr -d ' ')"
T0=$(now)
start_arm "$LAB/arm-b.out" --take-over "$ARM_A"; ARM_B=$LAST_ARM
T1=$(now)
while kill -0 "$W1" 2>/dev/null; do sleep 0.05; done; T2=$(now)
echo "take-over arm B printed: $(head -1 "$LAB/arm-b.out")  (after $(dt $T0 $T1)s)"
echo "W1 gone after $(dt $T0 $T2)s from take-over start"
echo "ledger: $(cut -f1-12 "$STATE/.watch-cycle-exits.log" | grep -o 'reason=[a-z-]*' | tr '\n' ' ')"
echo ".watcher-down: $(cut -c1-40 "$STATE/.watcher-down" 2>/dev/null)"
W2=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
sleep 1
echo "new lock holder W2=$W2; live readers now (expect only W2's, <=1)=$(reader_count); reader FIFO dirs now=$(fifo_dirs)"

echo "--- S2: a real idle->blocked transition during the new watcher's event wait still wakes"
wait_in_event_wait "$W2" || echo "WARN: W2 not in event wait"
sleep 1
T0=$(now)
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane report-agent "$PANE" --source fm-nm-live --agent claude --state blocked >/dev/null
while kill -0 "$W2" 2>/dev/null && [ "$(dt $T0 $(now) | cut -d. -f1)" -lt 30 ]; do sleep 0.05; done; T1=$(now)
echo "W2 exited $(dt $T0 $T1)s after the blocked report"
sleep 1
echo "arm B output: $(tr '\n' '|' < "$LAB/arm-b.out")"
echo "wake queue: $(cut -f3-5 "$STATE/.wake-queue" 2>/dev/null | tr '\n' '|')"
echo "event-wait dirs left: $(ls -d "$STATE"/.fm-event-wait.* 2>/dev/null | wc -l | tr -d ' '); leftover reader FIFO dirs: $(fifo_dirs)"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane report-agent "$PANE" --source fm-nm-live --agent claude --state working >/dev/null
main_ack

echo "--- S3: --stop while the watcher is in the event wait"
start_arm "$LAB/arm-c.out"; ARM_C=$LAST_ARM
echo "arm C: $(head -1 "$LAB/arm-c.out")"
W3=$(cat "$STATE/.watch.lock/pid")
wait_in_event_wait "$W3" || echo "WARN: W3 not in event wait"; sleep 1
T0=$(now)
"${ARM_ENV[@]}" "$ROOT/bin/fm-watch-arm.sh" --stop > "$LAB/stop.out" 2>&1; RC=$?
T1=$(now)
echo "--stop rc=$RC in $(dt $T0 $T1)s: $(tr '\n' '|' < "$LAB/stop.out")"
sleep 0.5
echo "W3 alive after stop: $(kill -0 "$W3" 2>/dev/null && echo yes || echo no); live readers: $(reader_count); event-wait dirs left: $(ls -d "$STATE"/.fm-event-wait.* 2>/dev/null | wc -l | tr -d ' '); reader FIFO dirs left: $(fifo_dirs)"
echo "=== [$LABEL] done"
