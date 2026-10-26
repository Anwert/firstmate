#!/usr/bin/env bash
# tests/fm-jira-walk.test.sh - walking a Jira issue one offered transition at a time.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jira-walk)
WALK_BIN="$ROOT/bin/fm-jira-walk.sh"

# A fake Jira whose workflow is a line of statuses plus Resolved off TestDone. The
# status lives in <home>/status; <home>/readback overrides what a read returns, and
# <home>/require-field makes Ready for test demand a field the walk never sets.
make_home() {  # <name> <start-status> [mr-state]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/bin"
  printf '%s\n' "$2" > "$home/status"
  printf '%s\n' "${3:-opened}" > "$home/mr-state"
  printf '%s\n' https://gitlab.example/mr/1 > "$home/mr-link"
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
    if [ "\$id" = 361 ] && [ -f "\$home/require-field" ]; then
      printf '{"errorMessages":[],"errors":{"customfield_2":"Story Points is required."}}\nHTTP 400\n'
      exit 0
    fi
    case "\$id" in 361) s='Ready for test' ;; 371) s='In Testing' ;; 301) s=TestDone ;; 451) s=Resolved ;; esac
    printf '%s\n' "\$s" > "\$home/status"
    printf '\nHTTP 204\n' ;;
  "PUT /rest/api/3/issue/BACK-1")
    [ ! -f "\$home/link-sticks-not" ] && jq -r .fields.customfield_1 "\$3" > "\$home/mr-link"
    printf 'put\n' >> "\$home/puts"
    printf '\nHTTP 204\n' ;;
  GET\ /rest/api/3/issue/BACK-1*)
    [ ! -f "\$home/readback" ] || status=\$(cat "\$home/readback")
    jq -nc --arg s "\$status" --arg m "\$(cat "\$home/mr-link")" '{fields: {status: {name: \$s, statusCategory: {name: "Done"}}, customfield_1: \$m}}'
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

# --mr writes the MR link into the issue's MR field once and reads it back; the
# same link already there is left alone, and a field that does not take it refuses.
test_mr_flag_sets_the_mr_field() {
  local home out rc=0
  home=$(make_home mrlink 'In Testing')
  out=$(run_walk "$home" BACK-1 TestDone --mr https://gitlab.example/mr/2) || fail "the walk with --mr failed: $out"
  [ "$(cat "$home/mr-link")" = https://gitlab.example/mr/2 ] || fail "--mr did not set the MR field"
  printf '%s\n' "$out" | grep -Fx 'BACK-1: customfield_1 = https://gitlab.example/mr/2' >/dev/null \
    || fail "setting the MR field was not reported: $out"
  printf '%s\n' "$out" | grep -Fx 'BACK-1: In Testing -> TestDone' >/dev/null || fail "the walk did not run after the field: $out"
  printf 'TestDone\n' > "$home/status"
  out=$(run_walk "$home" BACK-1 TestDone --mr https://gitlab.example/mr/2) || fail "a repeat --mr failed: $out"
  [ "$(wc -l < "$home/puts" | tr -d ' ')" = 1 ] || fail "a link already in the field was written again"
  : > "$home/link-sticks-not"
  out=$(run_walk "$home" BACK-1 TestDone --mr https://gitlab.example/mr/3 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "an MR field that did not take the link exited $rc: $out"
  printf '%s' "$out" | grep -F 'customfield_1 reads back as https://gitlab.example/mr/2, not https://gitlab.example/mr/3' >/dev/null \
    || fail "the field readback mismatch was not named: $out"
  pass "--mr sets the issue's MR field once, reads it back, and refuses when it does not stick"
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

test_target_matches_the_path_ignoring_case_and_spaces() {
  local home out
  home=$(make_home spelled 'In Testing')
  out=$(run_walk "$home" BACK-1 'test done' 2>&1) || fail "the walk to 'test done' failed: $out"
  [ "$out" = 'BACK-1: In Testing -> TestDone' ] || fail "the walk to 'test done' took the wrong moves: $out"
  out=$(run_walk "$home" BACK-1 'Test done' 2>&1) || fail "'Test done' at TestDone was refused: $out"
  [ -z "$out" ] || fail "'Test done' at TestDone still moved: $out"
  pass "a target matches a path status ignoring case and spaces"
}

test_required_field_refusal_names_jiras_error() {
  local home out rc=0
  home=$(make_home required 'Code review')
  : > "$home/require-field"
  out=$(run_walk "$home" BACK-1 TestDone 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a transition Jira rejected exited $rc: $out"
  printf '%s' "$out" | grep -F 'BACK-1: Jira refused transition 361 (Code review -> Ready for test), HTTP 400: customfield_2: Story Points is required.' >/dev/null \
    || fail "the refusal did not name the issue, the transition and Jira's error: $out"
  printf '%s' "$out" | grep -F 'Set or correct each named field on BACK-1, then rerun' >/dev/null || fail "the refusal did not say to set the field and rerun: $out"
  [ "$(cat "$home/status")" = 'Code review' ] || fail "a rejected transition still moved the issue"
  rm "$home/require-field"
  out=$(run_walk "$home" BACK-1 TestDone) || fail "the rerun after setting the field failed: $out"
  pass "a transition Jira rejects for a required field is refused with Jira's own error text"
}

test_walks_each_adjacent_state_and_reads_it_back
test_target_matches_the_path_ignoring_case_and_spaces
test_required_field_refusal_names_jiras_error
test_mr_flag_sets_the_mr_field
test_resolved_waits_for_the_merge
test_unreachable_target_and_wrong_readback_refuse
