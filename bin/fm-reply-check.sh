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
#    "homework_reporters": ["скаут", "воркер", "scout", "worker"],
#    "ask_endings": ["запускаю?", "делать?", "создавать?"],
#    "back_reference_phrases": ["см. выше", "как я писал", "as I wrote above"],
#    "next_badge": {"prefix": "next ", "move_with": "config/captain-next.sh <task> <kind> <text>"}}
# A line naming an identifier - a match of id_patterns, or with task_ids a task id
# recorded in state/*.meta - is flagged when fewer than min_words plain words
# remain on it once identifiers, URLs, and code spans are removed. A
# homework_phrases entry is flagged unless a homework_reporters word comes before
# it in the same sentence, because "скаут не нашёл X" relays a worker's finding
# rather than firstmate giving up on its own step; without the key the reporters
# are the ones shown above. A reply whose last non-blank line ends with an
# ask_endings entry is flagged too, because work the captain already chose is
# started and reported, not asked about again. A reply containing a
# back_reference_phrases entry is flagged, because the captain may read only
# this reply: it repeats the essentials instead of pointing back at an earlier
# message. With next_badge, the reply's last non-blank line - its closing next
# step - is flagged when it names a merge request URL or a recorded task other
# than the one carrying the badge: the open captain hold in data/backlog.md whose
# reason starts with `prefix` (the markdown backlog only, as config/captain-next.sh
# writes it), that task's recorded pr=, and an MR its hold
# reason names (as `!<number>` or by URL). The finding names
# move_with, so the badge moves in the same turn. Matching ignores case.
# As a hook it judges only the payload's last_assistant_message, never
# transcript_path: Claude Code writes the transcript asynchronously, so at Stop it
# can still end at the previous reply. A payload without that field is not
# checked. The hook runs only for a session whose cwd is this primary home, and
# never on a stop_hook_active turn, so a reply is rewritten at most once. A finding prints
# {"decision":"block","reason":...}, which sends the reason back to the model;
# everything else prints nothing. --text prints the findings and exits 1 on any.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
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
  INPUT=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty | strings' 2>/dev/null)
  [ -n "$INPUT" ] || exit 0
fi

ALL_TASK_IDS=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  meta=${meta##*/}
  ALL_TASK_IDS="$ALL_TASK_IDS${meta%.meta}
"
done
TASK_IDS=
! jq -e '.task_ids == true' "$RULES" >/dev/null 2>&1 || TASK_IDS=$ALL_TASK_IDS

BADGE_TASK=
BADGE_REASON=
BADGE_PR=
BADGE_PREFIX=$(jq -r '.next_badge.prefix // empty' "$RULES" 2>/dev/null)
if [ -n "$BADGE_PREFIX" ]; then
  # shellcheck source=bin/fm-hold-reason-lib.sh
  . "$SCRIPT_DIR/fm-hold-reason-lib.sh"
  BADGE_ROW=$(fm_hold_reason_decode_stream markdown < "$DATA/backlog.md" 2>/dev/null \
    | BADGE_PREFIX="$BADGE_PREFIX" perl -ne 'if (/^- \[ \] (\S+) - .*\(hold: "?(\Q$ENV{BADGE_PREFIX}\E.*?)"?\) \(hold-kind/) { print "$1\t$2\n"; exit }')
  BADGE_TASK=${BADGE_ROW%%$'\t'*}
  BADGE_REASON=${BADGE_ROW#*$'\t'}
  [ -z "$BADGE_TASK" ] || BADGE_PR=$(sed -n 's/^pr=//p' "$STATE/$BADGE_TASK.meta" 2>/dev/null | head -1)
fi

FINDINGS=$(printf '%s' "$INPUT" | RULES_JSON=$(cat "$RULES") TASK_IDS="$TASK_IDS" \
  BADGE_TASK="$BADGE_TASK" BADGE_REASON="$BADGE_REASON" BADGE_PR="$BADGE_PR" ALL_TASK_IDS="$ALL_TASK_IDS" perl -CSDA -MJSON::PP -e '
  use strict; use warnings; use utf8;
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
  my $reporters = join "|", map { quotemeta } @{ $r->{homework_reporters} // ["скаут", "воркер", "scout", "worker"] };
  my @sentences = split /[.!?;\n]+/, $text;
  for my $p (@{ $r->{homework_phrases} // [] }) {
    my $own = grep { /^(.*?)\Q$p\E/i && !(length $reporters && $1 =~ /(?<!\w)(?:$reporters)(?!\w)/i) } @sentences;
    push @out, "\"$p\" hands firstmate'"'"'s own failure to the captain: solve it, or name the one action only the captain can take"
      if $own;
  }
  for my $p (@{ $r->{back_reference_phrases} // [] }) {
    if ($text =~ /(?<!\p{L})\Q$p\E/i) {
      push @out, "\"$p\" points the captain back at an earlier message: repeat the essentials in this reply";
      last;
    }
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
  if (my $badge = $r->{next_badge}) {
    my @named = $last =~ m{(https?://\S*?/(?:-/)?(?:merge_requests|pull)/\d+)}g;
    for my $id (grep { length } split /\n/, $ENV{ALL_TASK_IDS}) {
      push @named, $id if $last =~ /(?<![\w.-])\Q$id\E(?![\w.-])/i;
    }
    for my $n (@named) {
      my ($num) = $n =~ m{/(\d+)$};
      my $on_badge = $n =~ m{^https?://}
        ? ((length $ENV{BADGE_PR} && $n =~ /^\Q$ENV{BADGE_PR}\E(?!\d)/)
           || (defined $num && $ENV{BADGE_REASON} =~ /(?<![\w\/])!\Q$num\E\b|\Q$n\E/))
        : lc $n eq lc $ENV{BADGE_TASK};
      next if $on_badge;
      my $where = length $ENV{BADGE_TASK} ? "on $ENV{BADGE_TASK}" : "on no task";
      my $move = $badge->{move_with} // "the badge command";
      push @out, "the closing step points the captain at $n, but the next badge is $where: move it there with $move in this turn, or close on the badged work";
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
