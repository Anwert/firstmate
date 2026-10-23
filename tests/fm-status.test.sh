#!/usr/bin/env bash
# tests/fm-status.test.sh - the coded status helper a refused worker reports through.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status)
STATUS_BIN="$ROOT/bin/fm-status.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'window=test:fm-x\nkind=ship\n' > "$home/state/task-x.meta"
  printf '%s\n' "$home"
}

run_status() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$STATUS_BIN" "$@"
}

test_coded_blocker_opens_a_keyed_decision() {
  local home open
  home=$(make_home coded)
  run_status "$home" task-x blocked auto-mode-refusal || fail "a valid coded status was refused"
  grep -Eqx 'blocked \[key=auto-mode-refusal\] \[at=[0-9]+\]: auto-mode-refusal' "$home/state/task-x.status" \
    || fail "coded status line has the wrong shape: $(cat "$home/state/task-x.status")"
  open=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/task-x.status")
  printf '%s\n' "$open" | grep -q '^auto-mode-refusal	blocked	' \
    || fail "the coded blocker did not open a keyed record: $open"
  run_status "$home" task-x resolved auto-mode-refusal || fail "a coded resolution was refused"
  open=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/task-x.status")
  [ -z "$open" ] || fail "the coded resolution left the blocker open: $open"
  pass "a coded blocker opens a keyed record that the coded resolution closes"
}

test_narrative_and_unknown_tasks_are_refused() {
  local home rc
  home=$(make_home refused)
  for args in 'task-x blocked classifier refused my token read' 'task-x blocked Auto-Mode' \
    'task-x stuck auto-mode-refusal' 'task-y blocked auto-mode-refusal'; do
    rc=0
    # shellcheck disable=SC2086
    run_status "$home" $args 2>/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "fm-status accepted '$args'"
  done
  [ ! -e "$home/state/task-x.status" ] || fail "a refused call still wrote a status line"
  pass "narrative codes, unknown states, and tasks without a record are refused without writing"
}

test_coded_blocker_opens_a_keyed_decision
test_narrative_and_unknown_tasks_are_refused
