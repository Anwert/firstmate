#!/usr/bin/env bash
# Report merge requests of this home's tasks that have gone into conflict.
# Usage: fm-mr-conflicts.sh
#
# Reads every state/<task-id>.meta that records pr=, asks the forge whether that
# GitHub pull request or GitLab merge request conflicts with its target, and prints
# `conflict: <task-id> <url>` once when it starts conflicting, or
# `conflict-check-blind: <task-id> <url>` once when it cannot be read. A GitHub
# request whose mergeability is not computed yet prints nothing until a later poll.
# A state/<task-id>.conflict-seen marker holds what was last reported and is cleared
# when the request reads clean or not computed, so a conflict that returns is
# reported again.
# Merged and closed requests are skipped. Prints nothing when nothing changed.
# It is meant to run as a registered watcher check (state/<id>.check.sh), so
# firstmate hears of a conflict and steers the owning worker before the captain
# sees it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Prints clean, conflict, closed, pending, or blind for one request URL; pending
# means GitHub has not computed mergeability yet and a later poll will.
request_state() {  # <url>
  local url=$1 project number json
  case "$url" in
    https://github.com/*/pull/*)
      json=$(gh pr view "$url" --json state,mergeable 2>/dev/null) || { echo blind; return; }
      printf '%s' "$json" | jq -r '
        if .state != "OPEN" then "closed"
        elif .mergeable == "CONFLICTING" then "conflict"
        elif .mergeable == "MERGEABLE" then "clean"
        elif .mergeable == "UNKNOWN" then "pending"
        else "blind" end' 2>/dev/null || echo blind
      ;;
    https://*/-/merge_requests/*)
      project=${url%/-/merge_requests/*}
      number=${url##*/}
      json=$(glab mr view "$number" -R "$project" -F json 2>/dev/null) || { echo blind; return; }
      printf '%s' "$json" | jq -r '
        if .state != "opened" then "closed"
        elif .has_conflicts == true or .detailed_merge_status == "conflict" then "conflict"
        elif .has_conflicts == false then "clean"
        else "blind" end' 2>/dev/null || echo blind
      ;;
    *) echo closed ;;
  esac
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  task=${meta##*/}
  task=${task%.meta}
  url=$(sed -n 's/^pr=//p' "$meta" | tail -1)
  [ -n "$url" ] || continue
  marker="$STATE/$task.conflict-seen"
  verdict=$(request_state "$url")
  case "$verdict" in
    conflict|blind)
      [ "$(cat "$marker" 2>/dev/null || true)" != "$verdict $url" ] || continue
      printf '%s %s\n' "$verdict" "$url" > "$marker"
      if [ "$verdict" = conflict ]; then
        printf 'conflict: %s %s\n' "$task" "$url"
      else
        printf 'conflict-check-blind: %s %s\n' "$task" "$url"
      fi
      ;;
    *) rm -f "$marker" ;;
  esac
done
exit 0
