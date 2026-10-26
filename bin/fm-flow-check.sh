#!/usr/bin/env bash
# Check that a Claude worker actually ran the delivery flow its task names.
# Usage: fm-flow-check.sh <task-id> [--flow <name>] [--steered]
#
# The flow comes from --flow, else from flow= in state/<task-id>.meta. Its rules
# come from that flow's object in config/flow-checks.json:
#   {"own": {"require_skills": ["implement", "review-pass"],
#            "allow_skills": ["pr", "test-on-stand"],
#            "allow_agents": ["general-purpose"],
#            "todo": ".audit/{task}.todo.md"}}
# Every key is optional; names in the allow lists may end in `*` as a prefix
# match. A required skill counts as run when the worker invoked it or read its
# SKILL.md (a user-invoked skill reaches a worker only by path), from a Read or a
# shell command naming `.../<skill>/SKILL.md`. The evidence is the worker's own
# Claude transcripts: every session file (subagent transcripts included) under
# ~/.claude/projects/<worktree-slug>/ whose first record is not older than the
# task's spawn, so an earlier task that used the same pooled worktree is never
# read. `todo` is a path relative to the worktree that must exist.
#
# --steered records the findings this run prints in state/<task-id>.flow-steered
# against the worker's spawn generation, once firstmate has steered the worker
# about them; later runs for the same spawn print them as one `steered` count
# instead of repeating them, and a relaunch starts with none recorded.
#
# Prints one `FLOW <task-id> <flow>: ok` line, or one `FLOW <task-id> <flow>: <finding>`
# line per finding, and exits 0 clean, 1 with findings, 2 when the check cannot
# tell (no flow, unknown flow, non-Claude worker, no transcript).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CLAUDE_PROJECTS="${FM_CLAUDE_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-flow-check.sh <task-id> [--flow <name>] [--steered]" >&2
  exit 2
}

ID=${1-}
fm_pr_task_id_valid "$ID" || usage
shift
FLOW=
STEERED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --flow) [ "$#" -ge 2 ] || usage; FLOW=$2; shift ;;
    --steered) STEERED=1 ;;
    *) usage ;;
  esac
  shift
done

META="$STATE/$ID.meta"
cant_tell() { printf 'FLOW %s %s: cannot tell - %s\n' "$ID" "${FLOW:--}" "$1"; exit 2; }
meta_get() { sed -n "s/^$1=//p" "$META" 2>/dev/null | head -1; }

[ -f "$META" ] || cant_tell "no task record"
[ -n "$FLOW" ] || FLOW=$(meta_get flow)
[ -n "$FLOW" ] || cant_tell "the task names no flow"
RULES=$(jq -ce --arg f "$FLOW" '.[$f] | objects' "$CONFIG/flow-checks.json" 2>/dev/null) \
  || cant_tell "config/flow-checks.json has no object for this flow"
[ "$(meta_get harness)" = claude ] || cant_tell "only Claude transcripts are read"
WORKTREE=$(meta_get worktree)
[ -n "$WORKTREE" ] || cant_tell "the task record names no worktree"
SPAWN_GEN=$(meta_get spawn_gen)
SPAWNED=${SPAWN_GEN#s}
SPAWNED=${SPAWNED%%.*}
case "$SPAWNED" in ''|*[!0-9]*) SPAWNED=0 ;; esac

SLUG=$(printf '%s' "$WORKTREE" | tr '/.' '--')
TRANSCRIPTS=()
for f in "$CLAUDE_PROJECTS/$SLUG"/*.jsonl; do
  [ -f "$f" ] || continue
  started=$(jq -r 'select(.timestamp) | .timestamp' "$f" 2>/dev/null | head -1)
  started=$(jq -rn --arg t "$started" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0')
  [ "${started:-0}" -ge "$SPAWNED" ] || continue
  TRANSCRIPTS+=("$f")
  for sub in "${f%.jsonl}"/subagents/*.jsonl; do
    [ -f "$sub" ] && TRANSCRIPTS+=("$sub")
  done
done
[ "${#TRANSCRIPTS[@]}" -gt 0 ] || cant_tell "no Claude transcript of this task under $CLAUDE_PROJECTS/$SLUG"

USES=$(jq -c 'select(.type == "assistant") | .message.content[]?
  | select(.type == "tool_use")
  | if .name == "Skill" then {skill: (.input.skill // "")}
    elif .name == "Agent" or .name == "Task" then {agent: (.input.subagent_type // "general-purpose")}
    elif .name == "Read" then {read: [(.input.file_path // "") | capture("/(?<s>[^/]+)/SKILL\\.md$").s]}
    elif .name == "Bash" then {read: [(.input.command // "") | scan("/([^/\\s\"'"'"']+)/SKILL\\.md") | .[0]]}
    else empty end' \
  "${TRANSCRIPTS[@]}" 2>/dev/null | jq -sc '.')

FINDINGS=$(jq -rn --argjson r "$RULES" --argjson u "$USES" '
  def allowed($name; $list): any($list[]; . as $p
    | if ($p | endswith("*")) then ($name | startswith($p[:-1])) else $name == $p end);
  ([$u[] | .skill // empty] | unique) as $skills
  | ([$u[] | .agent // empty] | unique) as $agents
  | ([$u[] | .read[]?] | unique) as $read
  | ([$r.require_skills[]? | select(. as $s | ($skills | index($s)) or ($read | index($s | sub("^[^:]*:"; ""))) | not)
      | "never invoked required skill \(.)"]
     + (if $r.allow_skills then [$skills[] | select(allowed(.; $r.allow_skills) | not) | "invoked skill outside the flow: \(.)"] else [] end)
     + (if $r.allow_agents then [$agents[] | select(allowed(.; $r.allow_agents) | not) | "spawned subagent outside the flow: \(.)"] else [] end))[]')

TODO=$(jq -rn --argjson r "$RULES" '$r.todo // empty')
if [ -n "$TODO" ]; then
  TODO=${TODO//\{task\}/$ID}
  [ -f "$WORKTREE/$TODO" ] || FINDINGS="${FINDINGS:+$FINDINGS
}no todo list at $TODO"
fi

STEERED_FILE="$STATE/$ID.flow-steered"
if [ "$STEERED" -eq 1 ] && [ -n "$FINDINGS" ]; then
  while IFS= read -r finding; do
    grep -qxF "$SPAWN_GEN	$finding" "$STEERED_FILE" 2>/dev/null \
      || printf '%s\t%s\n' "$SPAWN_GEN" "$finding" >> "$STEERED_FILE" \
      || { echo "error: cannot record steered findings in $STEERED_FILE" >&2; exit 2; }
  done <<EOF
$FINDINGS
EOF
fi
NEW=
OMITTED=0
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  if [ "$STEERED" -eq 0 ] && grep -qxF "$SPAWN_GEN	$finding" "$STEERED_FILE" 2>/dev/null; then
    OMITTED=$((OMITTED + 1))
  else
    NEW="$NEW$finding
"
  fi
done <<EOF
$FINDINGS
EOF

if [ -z "$NEW" ]; then
  if [ "$OMITTED" -gt 0 ]; then
    printf 'FLOW %s %s: ok - %s steered finding(s) not repeated\n' "$ID" "$FLOW" "$OMITTED"
  else
    printf 'FLOW %s %s: ok\n' "$ID" "$FLOW"
  fi
  exit 0
fi
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  printf 'FLOW %s %s: %s\n' "$ID" "$FLOW" "$finding"
done <<EOF
$NEW
EOF
[ "$OMITTED" -eq 0 ] || printf 'FLOW %s %s: %s steered finding(s) not repeated\n' "$ID" "$FLOW" "$OMITTED"
exit 1
