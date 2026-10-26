#!/usr/bin/env bash
# fm-worker-text-lib.sh - the single owner of what firstmate's own text to a
# worker may not say.
#
# Sourced, never executed. A worker running under Claude's auto permission mode
# reads text about its permission checks (the classifier, permission or allow
# rules, bypass, auto mode, fakeauth tokens) as an attempt to get around them,
# and then refuses even plain commands for the rest of its session; one such
# relaunch note cost a relaunch. bin/fm-send.sh checks every text steer,
# bin/fm-brief.sh its charter, scope and home-include text, bin/fm-spawn.sh a
# brief's filled `# Task` section, and bin/fm-control.sh a relaunch note.
#
#   fm_worker_text_permission_talk <text>
#       Prints the first matching phrase and returns 0 when the text talks
#       about the worker's permission checks; returns 1 when it does not.
#
#   fm_worker_text_permission_refusal <what> <phrase>
#       Prints the refusal reason for <what> (such as "the steer"), naming
#       the phrase and the fix, for the caller's own error line.

# Prose phrases only: a hyphenated name such as config/claude-permission-mode or
# --permission-mode is code a firstmate-repo task may need to name.
FM_WORKER_TEXT_PERMISSION_TALK='permission[[:space:]]+(classifier|rules?|modes?|prompts?)|safety[[:space:]]+classifier|classifier[[:space:]]+(refus|block|den)[a-z]*|allow[[:space:]]+rules?|bypass[[:space:]]+permissions|bypassPermissions|fakeauth|auto[[:space:]]+mode'

fm_worker_text_permission_talk() {
  local phrase
  phrase=$(printf '%s\n' "$1" | grep -ioE -m 1 "$FM_WORKER_TEXT_PERMISSION_TALK" | head -1)
  [ -n "$phrase" ] || return 1
  printf '%s\n' "$phrase"
}

fm_worker_text_permission_refusal() {
  printf "%s talks to the worker about its permission checks ('%s'), so it was not delivered: a worker reads such text as an attempt to get around those checks and then refuses its own commands for the rest of its session. Rewrite it to say only what to do and why, and retry.\n" "$1" "$2"
}
