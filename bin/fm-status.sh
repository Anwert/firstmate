#!/usr/bin/env bash
# Append one coded status line for a task, with no narrative on the command line.
# Usage: fm-status.sh <task-id> <state> <code>
#   <state> is working, needs-decision, blocked, paused, done, failed, or resolved.
#   <code> is a short lowercase slug such as auto-mode-refusal.
# The line written is `<state> [key=<code>] [at=<epoch>]: <code>`, followed by the
# same fleet-ledger notification the brief's own status append makes.
# It exists for a worker whose tool call a permission classifier refused: retried
# calls and refusal or credential prose on later command lines make benign calls
# look suspicious too, so the worker writes the details to data/<task-id>/blocker.md
# with its file tool, reports through this helper, and stops.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-status.sh <task-id> <working|needs-decision|blocked|paused|done|failed|resolved> <code>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
ID=$1 STATUS_STATE=$2 CODE=$3
fm_pr_task_id_valid "$ID" || usage
case "$STATUS_STATE" in
  working|needs-decision|blocked|paused|done|failed|resolved) ;;
  *) usage ;;
esac
[[ "$CODE" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || usage

STATUS_FILE="$STATE/$ID.status"
[ -e "$STATE/$ID.meta" ] || { echo "error: no task record for $ID in $STATE" >&2; exit 1; }
printf '%s [key=%s] [at=%s]: %s\n' "$STATUS_STATE" "$CODE" "$(date +%s)" "$CODE" >> "$STATUS_FILE" || exit 1
[ ! -e "$CONFIG/fleet-ledger" ] \
  || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$STATUS_FILE" >/dev/null 2>&1 || true
