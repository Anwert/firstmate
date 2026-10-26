#!/usr/bin/env bash
# tests/fm-mr-conflicts.test.sh - reporting task merge requests that go into conflict.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mr-conflicts)
CONFLICTS_BIN="$ROOT/bin/fm-mr-conflicts.sh"

# A home with one GitLab and one GitHub task; <home>/gl and <home>/gh hold the
# JSON the fake forges answer with, and a missing file makes the read fail.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/bin"
  printf 'pr=https://gitlab.example/grp/proj/-/merge_requests/7\n' > "$home/state/gl-task.meta"
  printf 'pr=https://github.com/o/r/pull/9\n' > "$home/state/gh-task.meta"
  printf 'kind=ship\n' > "$home/state/no-pr.meta"
  printf '#!/usr/bin/env bash\ncat "%s/gl" 2>/dev/null\n' "$home" > "$home/bin/glab"
  printf '#!/usr/bin/env bash\ncat "%s/gh" 2>/dev/null\n' "$home" > "$home/bin/gh"
  chmod +x "$home/bin/glab" "$home/bin/gh"
  printf '%s\n' "$home"
}

run_conflicts() {
  PATH="$1/bin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$CONFLICTS_BIN"
}

test_conflict_is_reported_once_and_again_after_clearing() {
  local home out
  home=$(make_home cycle)
  printf '{"state":"opened","has_conflicts":true}\n' > "$home/gl"
  printf '{"state":"OPEN","mergeable":"MERGEABLE"}\n' > "$home/gh"
  out=$(run_conflicts "$home")
  [ "$out" = 'conflict: gl-task https://gitlab.example/grp/proj/-/merge_requests/7' ] \
    || fail "a conflicting merge request was not reported alone: $out"
  out=$(run_conflicts "$home")
  [ -z "$out" ] || fail "an unchanged conflict was reported again: $out"
  printf '{"state":"opened","has_conflicts":false}\n' > "$home/gl"
  out=$(run_conflicts "$home")
  [ -z "$out" ] || fail "a resolved conflict printed: $out"
  printf '{"state":"opened","has_conflicts":true}\n' > "$home/gl"
  printf '{"state":"OPEN","mergeable":"CONFLICTING"}\n' > "$home/gh"
  out=$(run_conflicts "$home")
  printf '%s\n' "$out" | grep -Fx 'conflict: gl-task https://gitlab.example/grp/proj/-/merge_requests/7' >/dev/null \
    || fail "a returning GitLab conflict was not reported: $out"
  printf '%s\n' "$out" | grep -Fx 'conflict: gh-task https://github.com/o/r/pull/9' >/dev/null \
    || fail "a GitHub conflict was not reported: $out"
  pass "a conflict is reported once, and again only after it cleared and came back"
}

test_unreadable_request_is_reported_blind_and_merged_is_skipped() {
  local home out
  home=$(make_home blind)
  printf '{"state":"merged","has_conflicts":true}\n' > "$home/gl"
  out=$(run_conflicts "$home")
  [ "$out" = 'conflict-check-blind: gh-task https://github.com/o/r/pull/9' ] \
    || fail "expected only the unreadable GitHub request as blind: $out"
  pass "an unreadable request is reported blind, and a merged one is never a conflict"
}

test_uncomputed_github_mergeability_waits_for_the_next_poll() {
  local home out
  home=$(make_home pending)
  printf '{"state":"opened","has_conflicts":false}\n' > "$home/gl"
  printf '{"state":"OPEN","mergeable":"UNKNOWN"}\n' > "$home/gh"
  out=$(run_conflicts "$home")
  [ -z "$out" ] || fail "an uncomputed GitHub mergeability printed: $out"
  printf '{"state":"OPEN","mergeable":"CONFLICTING"}\n' > "$home/gh"
  out=$(run_conflicts "$home")
  [ "$out" = 'conflict: gh-task https://github.com/o/r/pull/9' ] \
    || fail "the conflict computed after an uncomputed read was not reported: $out"
  printf '{"state":"OPEN","mergeable":"UNKNOWN"}\n' > "$home/gh"
  out=$(run_conflicts "$home")
  [ -z "$out" ] || fail "an uncomputed read of a reported conflict printed: $out"
  printf '{"state":"OPEN","mergeable":"CONFLICTING"}\n' > "$home/gh"
  out=$(run_conflicts "$home")
  [ -z "$out" ] || fail "an unchanged conflict was reported again after an uncomputed read: $out"
  pass "an uncomputed GitHub mergeability prints nothing and keeps a reported conflict reported once"
}

test_conflict_is_reported_once_and_again_after_clearing
test_uncomputed_github_mergeability_waits_for_the_next_poll
test_unreadable_request_is_reported_blind_and_merged_is_skipped
