#!/usr/bin/env bash
# Claude PreToolUse hook: stop firstmate's primary session from writing text an
# agent will read - a skill, an AGENTS.md or CLAUDE.md, a playbook, a brief -
# before the session has loaded the home's writing skill for such text.
# Usage: fm-agent-text-pretool-check.sh   (PreToolUse hook payload on stdin)
#
# Rules come from config/agent-text-check.json; a home without it is never checked:
#   {"skill": "writing-for-agents",
#    "paths": ["*/.agents/skills/*", "*/skills/*/SKILL.md", "*/AGENTS.md", "*/CLAUDE.md",
#              "data/playbooks/*", "data/captain.md", "data/*/brief.md"]}
# A `paths` entry is a shell glob over the edited file's absolute path; an entry
# not starting with `/` or `*` is relative to this home. Only Write, Edit,
# MultiEdit, and NotebookEdit calls are judged. The skill counts as loaded when the
# session's transcript holds a Skill call naming it (a plugin prefix is allowed)
# or a Read of its `<skill>/SKILL.md`. The hook runs only in a session whose cwd is
# this primary home. A judged edit before the load exits 2 with the reason on
# stderr, which Claude shows the model; everything else exits 0 silently, and a
# payload it cannot read is allowed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RULES="$CONFIG/agent-text-check.json"

[ -f "$RULES" ] || exit 0
INPUT=$(cat)

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_HOME" "$STATE" || exit 0
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
home_real=$(cd "$FM_HOME" && pwd -P)
[ -n "$cwd" ] && [ "$(cd "$cwd" 2>/dev/null && pwd -P)" = "$home_real" ] || exit 0
case "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac
file=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[ -n "$file" ] || exit 0
case "$file" in /*) ;; *) file="$cwd/$file" ;; esac

SKILL=$(jq -r '.skill // empty' "$RULES" 2>/dev/null)
[ -n "$SKILL" ] || exit 0
matched=0
while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue
  case "$pattern" in /*|\**) ;; *) pattern="$home_real/$pattern" ;; esac
  # shellcheck disable=SC2254 # the configured entry is a glob on purpose
  case "$file" in $pattern) matched=1; break ;; esac
done <<EOF
$(jq -r '.paths[]? | strings' "$RULES" 2>/dev/null)
EOF
[ "$matched" -eq 1 ] || exit 0

transcript=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -f "$transcript" ] && grep -F "$SKILL" "$transcript" 2>/dev/null \
  | jq -e --arg s "$SKILL" 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
      | select((.name == "Skill" and ((.input.skill // "") | . == $s or endswith(":" + $s)))
        or (.name == "Read" and ((.input.file_path // "") | endswith("/" + $s + "/SKILL.md"))))' >/dev/null 2>&1; then
  exit 0
fi
printf '%s is text an agent will read: load the %s skill with the Skill tool first, then write it by that skill and retry this edit.\n' \
  "$file" "$SKILL" >&2
exit 2
