#!/usr/bin/env bash
# tests/fm-agent-text-pretool-check.test.sh - the PreToolUse check that firstmate
# loads its writing skill before it writes text an agent will read.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agent-text-pretool-check)
CHECK_BIN="$ROOT/bin/fm-agent-text-pretool-check.sh"

# A plain-checkout primary home with the check's rules.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin" "$home/state" "$home/config" "$home/data/playbooks"
  : > "$home/AGENTS.md"
  git -C "$home" init -q
  printf '%s\n' '{"skill":"writing-for-agents","paths":["*/AGENTS.md","*/skills/*/SKILL.md","data/playbooks/*","data/*/brief.md"]}' \
    > "$home/config/agent-text-check.json"
  : > "$home/transcript.jsonl"
  (cd "$home" && pwd -P)
}

# A PreToolUse payload for <tool> on <file>, run from <cwd>.
run_check() {  # <home> <cwd> <tool> <file>
  local home=$1
  jq -nc --arg c "$2" --arg t "$3" --arg f "$4" --arg p "$home/transcript.jsonl" \
    '{hook_event_name: "PreToolUse", cwd: $c, tool_name: $t, tool_input: {file_path: $f}, transcript_path: $p}' \
    | FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$CHECK_BIN"
}

add_tool_use() {  # <home> <tool> <input-json>
  jq -nc --arg n "$2" --argjson i "$3" '{type: "assistant", message: {content: [{type: "tool_use", name: $n, input: $i}]}}' \
    >> "$1/transcript.jsonl"
}

test_agent_text_waits_for_the_skill() {
  local home out rc=0
  home=$(make_home wait)
  out=$(run_check "$home" "$home" Edit "$home/data/playbooks/briefs.md" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a playbook edit before the skill loaded exited $rc: $out"
  printf '%s' "$out" | grep -F 'load the writing-for-agents skill with the Skill tool first' >/dev/null \
    || fail "the reminder did not name the skill: $out"
  rc=0; run_check "$home" "$home" Write "data/task-a/brief.md" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a relative brief path was not judged: exit $rc"
  rc=0; run_check "$home" "$home" Write "/elsewhere/skills/tool/SKILL.md" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a skill outside the home was not judged: exit $rc"

  add_tool_use "$home" Skill '{"skill":"writing-for-agents"}'
  out=$(run_check "$home" "$home" Edit "$home/data/playbooks/briefs.md" 2>&1) \
    || fail "an edit after the skill loaded was refused: $out"
  pass "agent-facing text waits for the writing skill, and goes through once it is loaded"
}

test_skill_read_by_path_counts() {
  local home out
  home=$(make_home read)
  add_tool_use "$home" Read '{"file_path":"/home/u/.claude/skills/writing-for-agents/SKILL.md"}'
  out=$(run_check "$home" "$home" Write "$home/AGENTS.md" 2>&1) || fail "a skill read by path did not count: $out"
  pass "reading the skill's SKILL.md counts as loading it"
}

test_other_files_sessions_and_tools_pass() {
  local home out rc=0
  home=$(make_home pass)
  out=$(run_check "$home" "$home" Edit "$home/bin/fm-x.sh" 2>&1) || fail "a script edit was refused: $out"
  out=$(run_check "$home" "$home" Read "$home/AGENTS.md" 2>&1) || fail "a read was refused: $out"
  out=$(run_check "$home" /tmp Edit "$home/AGENTS.md" 2>&1) || fail "a session outside the home was refused: $out"
  rm "$home/config/agent-text-check.json"
  out=$(run_check "$home" "$home" Edit "$home/AGENTS.md" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a home without rules was checked: $out"
  pass "other files, reads, other sessions, and homes without rules pass silently"
}

test_agent_text_waits_for_the_skill
test_skill_read_by_path_counts
test_other_files_sessions_and_tools_pass
