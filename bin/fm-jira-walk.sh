#!/usr/bin/env bash
# Move a Jira issue to a target status one reachable transition at a time.
# Usage: fm-jira-walk.sh <issue-key> <target-status> [--mr <merge-request-url>]
#
# Settings come from config/jira-walk.json:
#   {"rest": "/abs/path/jira-rest",
#    "path": ["To Do", "In Progress", "Code review", "Ready for test", "In Testing", "TestDone"],
#    "merged_required": ["Resolved"],
#    "mr_field": "customfield_10171"}
# `rest` is a command called as `<rest> GET|POST <api-path> [json-file]` that prints
# the response body and then a final `HTTP <code>` line; it owns authentication.
# Each step reads the transitions Jira offers from the current status and takes the
# one into the target, else the one into the next status of `path` toward it; when
# neither is offered it refuses and names what is. A target in `merged_required` is
# refused until the merge request (--mr, else the issue's `mr_field`) reports merged
# through `glab mr view`. After every move the exact `.fields.status.name` is read
# back, because a status category such as Done can hide which status was reached.
# Prints one `<key>: <from> -> <to>` line per move and exits 0 at the target, 1 on a
# refusal or a failed move, 2 on bad usage or configuration.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SETTINGS="$CONFIG/jira-walk.json"
MAX_STEPS=12

usage() {
  echo "usage: fm-jira-walk.sh <issue-key> <target-status> [--mr <merge-request-url>]" >&2
  exit 2
}
refuse() { printf 'fm-jira-walk: %s\n' "$*" >&2; exit 1; }

KEY=${1-}
TARGET=${2-}
[[ "$KEY" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] && [ -n "$TARGET" ] || usage
shift 2
MR=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mr) [ "$#" -ge 2 ] || usage; MR=$2; shift ;;
    *) usage ;;
  esac
  shift
done

jq -e '(.rest | type == "string") and ((.path // []) | type == "array")' "$SETTINGS" >/dev/null 2>&1 \
  || { echo "fm-jira-walk: $SETTINGS must name a rest command and a status path" >&2; exit 2; }
REST=$(jq -r '.rest' "$SETTINGS")
MR_FIELD=$(jq -r '.mr_field // empty' "$SETTINGS")

# Calls the rest command and leaves the body in REST_BODY, failing on a non-2xx code.
REST_BODY=
rest_call() {  # <method> <api-path> [json-file]
  local out code
  out=$("$REST" "$@" 2>&1) || refuse "$1 $2 failed: ${out##*$'\n'}"
  code=${out##*$'\n'}
  REST_BODY=${out%$'\n'*}
  case "$code" in
    "HTTP 2"*) ;;
    *) refuse "$1 $2 answered ${code:-nothing}: $(printf '%s' "$REST_BODY" | head -c 300)" ;;
  esac
}

current_status() {
  rest_call GET "/rest/api/3/issue/$KEY?fields=status${MR_FIELD:+,$MR_FIELD}"
  printf '%s' "$REST_BODY" | jq -r '.fields.status.name // empty'
}

if jq -e --arg t "$TARGET" '(.merged_required // []) | index($t)' "$SETTINGS" >/dev/null; then
  if [ -z "$MR" ] && [ -n "$MR_FIELD" ]; then
    rest_call GET "/rest/api/3/issue/$KEY?fields=$MR_FIELD"
    MR=$(printf '%s' "$REST_BODY" | jq -r --arg f "$MR_FIELD" '.fields[$f] // empty | if type == "string" then . else (.url // empty) end')
  fi
  [ -n "$MR" ] || refuse "$KEY -> $TARGET needs a merged merge request, and none is linked; pass --mr"
  state=$(glab mr view "$MR" --output json 2>/dev/null | jq -r '.state // empty')
  [ "$state" = merged ] || refuse "$KEY -> $TARGET refused: $MR is ${state:-unreadable}, not merged"
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jira-walk.XXXXXX") || exit 1
trap 'rm -f -- "$TMP"' EXIT
step=0
from=$(current_status)
[ -n "$from" ] || refuse "$KEY has no readable status"
while [ "$from" != "$TARGET" ]; do
  step=$((step + 1))
  [ "$step" -le "$MAX_STEPS" ] || refuse "$KEY did not reach $TARGET within $MAX_STEPS moves"
  rest_call GET "/rest/api/3/issue/$KEY/transitions"
  offered=$REST_BODY
  next=$(jq -rn --arg f "$from" --arg t "$TARGET" --slurpfile s "$SETTINGS" '
    ($s[0].path // []) as $p
    | if ($p | index($f)) != null and ($p | index($t)) != null and ($p | index($t)) > ($p | index($f))
      then $p[($p | index($f)) + 1] else empty end')
  pick=$(printf '%s' "$offered" | jq -r --arg t "$TARGET" --arg n "$next" '
    [.transitions[] | {id, to: .to.name}] as $all
    | (first($all[] | select(.to == $t)) // first($all[] | select($n != "" and .to == $n)) // empty)
    | "\(.id)\t\(.to)"')
  if [ -z "$pick" ]; then
    refuse "$KEY: no transition from $from toward $TARGET; offered: $(printf '%s' "$offered" | jq -r '[.transitions[].to.name] | join(", ")')"
  fi
  id=${pick%%$'\t'*}
  want=${pick#*$'\t'}
  jq -n --arg id "$id" '{transition: {id: $id}}' > "$TMP"
  rest_call POST "/rest/api/3/issue/$KEY/transitions" "$TMP"
  now=$(current_status)
  [ "$now" = "$want" ] || refuse "$KEY moved $from -> $want but reads back as ${now:-nothing}"
  printf '%s: %s -> %s\n' "$KEY" "$from" "$now"
  from=$now
done
