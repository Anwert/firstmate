#!/usr/bin/env bash
# Claude Stop hook: ask firstmate to rewrite a captain-facing reply that breaks
# the home's reply rules, before the captain reads it.
# Usage: fm-reply-check.sh            (Stop hook payload on stdin)
#        fm-reply-check.sh --text      (a reply on stdin, for a manual check)
#
# Rules come from config/reply-check.json; a home without it is never checked:
#   {"id_patterns": ["BACK-[0-9]+", "![0-9]+"],
#    "task_ids": true,
#    "min_words": 3,
#    "homework_phrases": ["не нашёл", "дальше не стал", "не получилось"],
#    "ask_endings": ["запускаю?", "делать?", "создавать?"]}
# A line naming an identifier - a match of id_patterns, or with task_ids a task id
# recorded in state/*.meta - is flagged when fewer than min_words plain words
# remain on it once identifiers, URLs, and code spans are removed. A
# homework_phrases entry anywhere is flagged, and so is a reply whose last
# non-blank line ends with an ask_endings entry, because work the captain
# already chose is started and reported, not asked about again. Matching
# ignores case.
# As a hook it reads only the session's last assistant message from the payload's
# transcript, only for a session whose cwd is this primary home, and never on a
# stop_hook_active turn, so a reply is rewritten at most once. A finding prints
# {"decision":"block","reason":...}, which sends the reason back to the model;
# everything else prints nothing. --text prints the findings and exits 1 on any.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RULES="$CONFIG/reply-check.json"

MODE=hook
case "${1-}" in
  '') ;;
  --text) MODE=text ;;
  *) echo "usage: fm-reply-check.sh [--text]" >&2; exit 2 ;;
esac

[ -f "$RULES" ] || exit 0
INPUT=$(cat)

if [ "$MODE" = hook ]; then
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_HOME" "$STATE" || exit 0
  [ "$(printf '%s' "$INPUT" | jq -r '(.stop_hook_active // .stopHookActive // false) | tostring' 2>/dev/null)" = false ] || exit 0
  cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$cwd" ] && [ "$(cd "$cwd" 2>/dev/null && pwd -P)" = "$(cd "$FM_HOME" && pwd -P)" ] || exit 0
  transcript=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
  [ -f "$transcript" ] || exit 0
  INPUT=$(jq -rs '[.[] | select(.type == "assistant")
      | [.message.content[]? | select(.type == "text") | .text] | join("\n")
      | select(length > 0)] | last // empty' "$transcript" 2>/dev/null)
  [ -n "$INPUT" ] || exit 0
fi

TASK_IDS=
if jq -e '.task_ids == true' "$RULES" >/dev/null 2>&1; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    meta=${meta##*/}
    TASK_IDS="$TASK_IDS${meta%.meta}
"
  done
fi

FINDINGS=$(printf '%s' "$INPUT" | RULES_JSON=$(cat "$RULES") TASK_IDS="$TASK_IDS" perl -CSDA -MJSON::PP -e '
  use strict; use warnings;
  my $r = JSON::PP->new->utf8->decode($ENV{RULES_JSON});
  my $text = do { local $/; <STDIN> };
  my @ids = map { qr/$_/i } @{ $r->{id_patterns} // [] };
  push @ids, map { qr/(?<![\w.-])\Q$_\E(?![\w.-])/i } grep { length } split /\n/, $ENV{TASK_IDS};
  my $min = $r->{min_words} // 3;
  my @out;
  for my $line (split /\n/, $text) {
    my $rest = $line;
    $rest =~ s{https?://\S+}{ }g;
    $rest =~ s{`[^`]*`}{ }g;
    my $hit;
    for my $re (@ids) { $hit //= $1 // $& if $rest =~ /($re)/; $rest =~ s/$re/ /g; }
    next unless defined $hit;
    my @words = grep { /\p{L}{2,}/ } split /[^\p{L}\p{N}-]+/, $rest;
    push @out, "\"$hit\" stands without plain words: name the work in the captain'"'"'s nouns beside it"
      if @words < $min;
  }
  for my $p (@{ $r->{homework_phrases} // [] }) {
    push @out, "\"$p\" hands firstmate'"'"'s own failure to the captain: solve it, or name the one action only the captain can take"
      if index(lc $text, lc $p) >= 0;
  }
  my ($last) = grep { /\S/ } reverse split /\n/, $text;
  $last //= "";
  $last =~ s/\s+$//;
  for my $p (@{ $r->{ask_endings} // [] }) {
    if (length($last) >= length($p) && lc(substr($last, -length($p))) eq lc $p) {
      push @out, "the reply ends by asking \"$p\": work the captain already chose is started in this reply and reported started; ask only a call nobody else can make, with options and a recommendation";
      last;
    }
  }
  print join("\n", @out);
')

[ -n "$FINDINGS" ] || exit 0
if [ "$MODE" = text ]; then
  printf '%s\n' "$FINDINGS"
  exit 1
fi
jq -n --arg r "Rewrite this reply before the captain reads it:
$FINDINGS" '{decision: "block", reason: $r}'
