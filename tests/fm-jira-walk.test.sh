#!/usr/bin/env bash
# tests/fm-jira-walk.test.sh - walking a Jira issue one offered transition at a time.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jira-walk)
WALK_BIN="$ROOT/bin/fm-jira-walk.sh"

# A fake Jira whose workflow is a line of statuses plus Resolved off TestDone. The
# status lives in <home>/status; <home>/readback overrides what a read returns.
make_home() {  # <name> <start-status> [mr-state]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/bin"
  printf '%s\n' "$2" > "$home/status"
  printf '%s\n' "${3:-opened}" > "$home/mr-state"
  cat > "$home/bin/rest" <<SH
#!/usr/bin/env bash
home='$home'
status=\$(cat "\$home/status")
case "\$1 \$2" in
  "GET /rest/api/3/issue/BACK-1/transitions")
    case "\$status" in
      "Code review") offered='[{"id":"361","to":{"name":"Ready for test"}}]' ;;
      "Ready for test") offered='[{"id":"371","to":{"name":"In Testing"}}]' ;;
      "In Testing") offered='[{"id":"301","to":{"name":"TestDone"}}]' ;;
      TestDone) offered='[{"id":"451","to":{"name":"Resolved"}}]' ;;
      *) offered='[]' ;;
    esac
    printf '{"transitions":%s}\nHTTP 200\n' "\$offered" ;;
  "POST /rest/api/3/issue/BACK-1/transitions")
    id=\$(jq -r .transition.id "\$3")
    case "\$id" in 361) s='Ready for test' ;; 371) s='In Testing' ;; 301) s=TestDone ;; 451) s=Resolved ;; esac
    printf '%s\n' "\$s" > "\$home/status"
    printf '\nHTTP 204\n' ;;
  GET\ /rest/api/3/issue/BACK-1*)
    [ ! -f "\$home/readback" ] || status=\$(cat "\$home/readback")
    jq -nc --arg s "\$status" '{fields: {status: {name: \$s, statusCategory: {name: "Done"}}, customfield_1: "https://gitlab.example/mr/1"}}'
    printf 'HTTP 200\n' ;;
  *) printf 'HTTP 404\n' ;;
esac
SH
  cat > "$home/bin/glab" <<SH
#!/usr/bin/env bash
jq -nc --arg s "\$(cat '$home/mr-state')" '{state: \$s}'
SH
  chmod +x "$home/bin/rest" "$home/bin/glab"
  jq -n --arg r "$home/bin/rest" '{rest: $r, path: ["To Do","In Progress","Code review","Ready for test","In Testing","TestDone"], merged_required: ["Resolved"], mr_field: "customfield_1"}' \
    > "$home/config/jira-walk.json"
  printf '%s\n' "$home"
}

run_walk() {
  local home=$1
  shift
  PATH="$home/bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$WALK_BIN" "$@"
}

test_walks_each_adjacent_state_and_reads_it_back() {
  local home out
  home=$(make_home walk 'Code review')
  out=$(run_walk "$home" BACK-1 TestDone) || fail "the walk to TestDone failed: $out"
  [ "$out" = "BACK-1: Code review -> Ready for test
BACK-1: Ready for test -> In Testing
BACK-1: In Testing -> TestDone" ] || fail "the walk took the wrong moves: $out"
  [ "$(cat "$home/status")" = TestDone ] || fail "the issue did not end at TestDone"
  pass "an issue is walked through every adjacent state to its target"
}

test_resolved_waits_for_the_merge() {
  local home out rc=0
  home=$(make_home unmerged TestDone opened)
  out=$(run_walk "$home" BACK-1 Resolved 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "Resolved over an unmerged MR exited $rc: $out"
  printf '%s' "$out" | grep -F 'not merged' >/dev/null || fail "the refusal did not say the MR is unmerged: $out"
  [ "$(cat "$home/status")" = TestDone ] || fail "a refused walk still moved the issue"
  printf 'merged\n' > "$home/mr-state"
  out=$(run_walk "$home" BACK-1 Resolved) || fail "Resolved over a merged MR failed: $out"
  pass "Resolved is refused until the linked merge request is merged"
}

test_unreachable_target_and_wrong_readback_refuse() {
  local home out rc=0
  home=$(make_home stuck Backlog)
  out=$(run_walk "$home" BACK-1 TestDone 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a target with no offered step exited $rc: $out"
  printf '%s' "$out" | grep -F 'no transition from Backlog toward TestDone' >/dev/null || fail "unclear refusal: $out"

  home=$(make_home readback 'In Testing')
  printf 'Done\n' > "$home/readback"
  rc=0; out=$(run_walk "$home" BACK-1 TestDone 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a move that read back as another status exited $rc: $out"
  printf '%s' "$out" | grep -F 'reads back as Done' >/dev/null || fail "the readback mismatch was not named: $out"
  pass "a target with no offered step, or a move that reads back wrong, is refused by name"
}

test_walks_each_adjacent_state_and_reads_it_back
test_resolved_waits_for_the_merge
test_unreachable_target_and_wrong_readback_refuse
