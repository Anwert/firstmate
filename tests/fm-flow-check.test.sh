#!/usr/bin/env bash
# tests/fm-flow-check.test.sh - the delivery-flow check over a worker's own transcripts.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-flow-check)
CHECK_BIN="$ROOT/bin/fm-flow-check.sh"

# A home with one Claude task in a worktree, its flow rules, and a transcript dir.
make_home() {  # <name> -> home
  local home="$TMP_ROOT/$1" wt slug
  wt="$home/wt.slot"
  mkdir -p "$home/state" "$home/config" "$wt"
  printf 'harness=claude\nworktree=%s\nspawn_gen=s1800000000.1.1\nflow=pstack\n' "$wt" > "$home/state/task-x.meta"
  printf '%s\n' '{"pstack":{"require_skills":["pstack:poteto-mode"],"allow_skills":["pstack:*","pr"],"allow_agents":["pstack:*"],"todo":".audit/{task}.todo.md"}}' \
    > "$home/config/flow-checks.json"
  slug=$(printf '%s' "$wt" | tr '/.' '--')
  mkdir -p "$home/projects/$slug"
  printf '%s\n' "$home"
}

transcript_dir() {  # <home>
  printf '%s/projects/%s' "$1" "$(printf '%s' "$1/wt.slot" | tr '/.' '--')"
}

# One session file starting at <iso> whose assistant called <tool>:<arg> pairs.
write_session() {  # <file> <iso> <tool:arg>...
  local file=$1 iso=$2 use tool arg
  shift 2
  printf '{"type":"user","timestamp":"%s","message":{"content":"brief"}}\n' "$iso" > "$file"
  for use in "$@"; do
    tool=${use%%:*}; arg=${use#*:}
    if [ "$tool" = Skill ]; then
      printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"%s"}}]}}\n' "$arg" >> "$file"
    else
      printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"%s"}}]}}\n' "$arg" >> "$file"
    fi
  done
}

run_check() {
  local home=$1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CLAUDE_PROJECTS_DIR="$home/projects" "$CHECK_BIN" task-x "${@:2}"
}

test_clean_flow_passes() {
  local home dir out
  home=$(make_home clean)
  dir=$(transcript_dir "$home")
  write_session "$dir/a.jsonl" 2027-01-15T08:00:00.000Z Skill:pstack:poteto-mode Agent:pstack:poteto-agent Skill:pr
  mkdir -p "$home/wt.slot/.audit"; : > "$home/wt.slot/.audit/task-x.todo.md"
  out=$(run_check "$home") || fail "a worker that followed its flow was flagged: $out"
  [ "$out" = 'FLOW task-x pstack: ok' ] || fail "unexpected clean verdict: $out"
  pass "a worker that ran its flow's skills, subagents and todo list passes"
}

test_drift_is_named_and_older_tasks_are_ignored() {
  local home dir out rc=0
  home=$(make_home drift)
  dir=$(transcript_dir "$home")
  write_session "$dir/old.jsonl" 2020-01-01T00:00:00Z Skill:pstack:poteto-mode
  write_session "$dir/now.jsonl" 2027-01-15T08:00:00Z Skill:deslop Agent:opus-high
  mkdir -p "$dir/now/subagents"
  write_session "$dir/now/subagents/s.jsonl" 2027-01-15T08:05:00Z Skill:finom:infra-test-stands
  out=$(run_check "$home") || rc=$?
  [ "$rc" -eq 1 ] || fail "a drifted worker exited $rc instead of 1: $out"
  for want in 'never invoked required skill pstack:poteto-mode' 'invoked skill outside the flow: deslop' \
    'invoked skill outside the flow: finom:infra-test-stands' 'spawned subagent outside the flow: opus-high' \
    'no todo list at .audit/task-x.todo.md'; do
    printf '%s\n' "$out" | grep -Fx "FLOW task-x pstack: $want" >/dev/null || fail "missing finding '$want' in: $out"
  done
  pass "a drifted worker is named finding by finding, and an earlier task's session in the same slot is not read"
}

# The own flow reaches /implement by path, so reading a skill's SKILL.md (by Read
# or by a shell command) counts as running it; a plugin skill matches its bare name.
test_reading_a_required_skill_counts_as_running_it() {
  local home dir out
  home=$(make_home read)
  printf '%s\n' '{"pstack":{"require_skills":["implement","review-pass","pstack:poteto-mode"]}}' > "$home/config/flow-checks.json"
  dir=$(transcript_dir "$home")
  write_session "$dir/a.jsonl" 2027-01-15T08:00:00Z Skill:review-pass
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/home/u/agent-kit/skills/implement/SKILL.md"}}]}}\n' >> "$dir/a.jsonl"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat /plugins/pstack/skills/poteto-mode/SKILL.md | head"}}]}}\n' >> "$dir/a.jsonl"
  out=$(run_check "$home") || fail "a worker that read its required skills by path was flagged: $out"
  [ "$out" = 'FLOW task-x pstack: ok' ] || fail "unexpected verdict for skills read by path: $out"
  rm "$dir/a.jsonl"
  write_session "$dir/b.jsonl" 2027-01-15T08:00:00Z Skill:review-pass
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/home/u/agent-kit/skills/implement/README.md"}}]}}\n' >> "$dir/b.jsonl"
  out=$(run_check "$home") && fail "a worker that never read implement's SKILL.md passed: $out"
  printf '%s\n' "$out" | grep -Fx 'FLOW task-x pstack: never invoked required skill implement' >/dev/null \
    || fail "the unread required skill was not named: $out"
  pass "a required skill read by its SKILL.md path counts as run, and another file in its folder does not"
}

# A finding firstmate already steered is not repeated for the same spawn, a new
# finding still is, and a relaunch (new spawn generation) reports it afresh.
test_steered_findings_are_not_repeated() {
  local home dir out rc=0
  home=$(make_home steered)
  dir=$(transcript_dir "$home")
  write_session "$dir/a.jsonl" 2027-01-15T08:00:00Z Skill:pr
  mkdir -p "$home/wt.slot/.audit"; : > "$home/wt.slot/.audit/task-x.todo.md"
  out=$(run_check "$home" --steered) || rc=$?
  [ "$rc" -eq 1 ] || fail "recording steered findings exited $rc instead of 1: $out"
  printf '%s\n' "$out" | grep -Fx 'FLOW task-x pstack: never invoked required skill pstack:poteto-mode' >/dev/null \
    || fail "--steered did not print the findings it records: $out"
  rc=0; out=$(run_check "$home") || rc=$?
  [ "$rc" -eq 0 ] || fail "a steered finding still failed the check ($rc): $out"
  [ "$out" = 'FLOW task-x pstack: ok - 1 steered finding(s) not repeated' ] || fail "unexpected steered verdict: $out"
  write_session "$dir/b.jsonl" 2027-01-15T08:10:00Z Skill:deslop
  rc=0; out=$(run_check "$home") || rc=$?
  [ "$rc" -eq 1 ] || fail "a new finding after a steer exited $rc instead of 1: $out"
  printf '%s\n' "$out" | grep -Fx 'FLOW task-x pstack: invoked skill outside the flow: deslop' >/dev/null \
    || fail "the new finding was not named: $out"
  printf '%s\n' "$out" | grep -F 'never invoked required skill' >/dev/null && fail "the steered finding was repeated: $out"
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=s1800000100.1.1/' "$home/state/task-x.meta"
  rc=0; out=$(run_check "$home") || rc=$?
  printf '%s\n' "$out" | grep -Fx 'FLOW task-x pstack: never invoked required skill pstack:poteto-mode' >/dev/null \
    || fail "a relaunched worker inherited the earlier spawn's steered findings: $out"
  pass "a steered finding is recorded per spawn and not repeated, while new findings and relaunches still report"
}

test_unknown_cases_cannot_tell() {
  local home out rc=0
  home=$(make_home unknown)
  out=$(run_check "$home") || rc=$?
  [ "$rc" -eq 2 ] || fail "a task with no transcript exited $rc instead of 2: $out"
  sed -i.bak 's/^flow=pstack$/flow=other/' "$home/state/task-x.meta"
  rc=0; out=$(run_check "$home") || rc=$?
  [ "$rc" -eq 2 ] || fail "a flow with no rules exited $rc instead of 2: $out"
  pass "no transcript or no rules for the flow is reported as cannot tell, never as ok"
}

# The wake drain runs the check once per new done or needs-decision event of a
# flow task, beside the result firstmate is about to relay, and not again on the
# next drain of the same event.
test_drain_presents_the_flow_check_once_per_result() {
  local home out
  home=$(make_home drain)
  printf 'working [at=1]: started\ndone [at=2]: ready in branch\n' > "$home/state/task-x.status"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CLAUDE_PROJECTS_DIR="$home/projects" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null) \
    || fail "the drain failed: $out"
  printf '%s\n' "$out" | grep -F 'FLOW CHECK (a flow task reported done or a decision; read before relaying it;' >/dev/null \
    || fail "the drain did not present a flow check for a done flow task: $out"
  printf '%s\n' "$out" | grep -F 'FLOW task-x pstack: cannot tell' >/dev/null \
    || fail "the drain dropped the check's verdict: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CLAUDE_PROJECTS_DIR="$home/projects" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null) \
    || fail "the second drain failed: $out"
  printf '%s\n' "$out" | grep -F 'FLOW CHECK' >/dev/null && fail "the same result was flow-checked twice: $out"
  pass "the wake drain flow-checks a flow task's result once, beside it"
}

test_clean_flow_passes
test_drift_is_named_and_older_tasks_are_ignored
test_drain_presents_the_flow_check_once_per_result
test_unknown_cases_cannot_tell
test_reading_a_required_skill_counts_as_running_it
test_steered_findings_are_not_repeated
