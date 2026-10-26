#!/usr/bin/env bash
# tests/fm-reply-check.test.sh - the Stop-hook check on captain-facing replies.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-reply-check)
CHECK_BIN="$ROOT/bin/fm-reply-check.sh"

# A plain-checkout primary home with reply rules and one recorded task.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin" "$home/state" "$home/config"
  : > "$home/AGENTS.md"
  git -C "$home" init -q
  : > "$home/state/retro-fixes.meta"
  cat > "$home/config/reply-check.json" <<'JSON'
{"id_patterns": ["BACK-[0-9]+", "![0-9]+"], "task_ids": true, "min_words": 3,
 "homework_phrases": ["не нашёл", "дальше не стал"], "ask_endings": ["запускаю?", "делать?"],
 "back_reference_phrases": ["см. выше", "я писал раньше", "as I wrote above"]}
JSON
  printf '%s\n' "$home"
}

check_text() {
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" "$CHECK_BIN" --text
}

# Stop payload whose last_assistant_message is <reply>, over a transcript that
# has not caught up yet and still ends at the previous reply, <stale>.
run_hook() {  # <home> <cwd> <stop-hook-active> <reply> [<stale>]
  local home=$1 transcript="$1/transcript.jsonl"
  jq -nc --arg t "${5:-earlier turn}" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}' > "$transcript"
  jq -nc '{type: "user", message: {content: "status?"}}' >> "$transcript"
  jq -nc --arg c "$2" --arg t "$transcript" --argjson a "$3" --arg m "$4" \
    '{hook_event_name: "Stop", cwd: $c, transcript_path: $t, stop_hook_active: $a}
     + (if $m == "" then {} else {last_assistant_message: $m} end)' \
    | FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$CHECK_BIN"
}

test_text_mode_names_each_broken_rule() {
  local home out rc=0
  home=$(make_home text)
  out=$(printf 'Готово.\n- BACK-34617\n- retro-fixes\n- Проверки overdraft по BACK-34617 зелёные\nЗа пару попыток не нашёл.\nЗапускаю?\n' \
    | check_text "$home") || rc=$?
  [ "$rc" -eq 1 ] || fail "a reply breaking the rules exited $rc: $out"
  printf '%s\n' "$out" | grep -F '"BACK-34617" stands without plain words' >/dev/null || fail "bare ticket key missed: $out"
  printf '%s\n' "$out" | grep -F '"retro-fixes" stands without plain words' >/dev/null || fail "bare task id missed: $out"
  [ "$(printf '%s\n' "$out" | grep -c 'stands without plain words')" -eq 2 ] || fail "a key with plain words beside it was flagged: $out"
  printf '%s\n' "$out" | grep -F '"не нашёл" hands' >/dev/null || fail "homework phrase missed: $out"
  printf '%s\n' "$out" | grep -F 'ends by asking "запускаю?"' >/dev/null || fail "ask ending missed: $out"
  out=$(printf 'Фикс overdraft E2E зелёный, MR ждёт твоего ревью. Следующим беру тех долг.\n' | check_text "$home") \
    || fail "a clean reply was flagged: $out"
  [ -z "$out" ] || fail "a clean reply printed: $out"
  pass "text mode names bare identifiers, homework, and a closing ask, and passes a clean reply"
}

test_back_reference_is_flagged() {
  local home out rc=0
  home=$(make_home backref)
  out=$(printf 'Решение по оверлимиту - как Я ПИСАЛ РАНЬШЕ, вариант B.\n' | check_text "$home") || rc=$?
  [ "$rc" -eq 1 ] || fail "a reply pointing back exited $rc: $out"
  printf '%s\n' "$out" | grep -F '"я писал раньше" points the captain back at an earlier message' >/dev/null \
    || fail "the back reference was not named: $out"
  out=$(printf 'Overdraft limit: option B, the migration stays out.\n' | check_text "$home") \
    || fail "a reply restating the essentials was flagged: $out"
  pass "a reply that points the captain back at an earlier message is flagged, a restated one passes"
}

test_homework_spares_a_relayed_worker_finding() {
  local home out
  home=$(make_home relay)
  out=$(printf 'По тарифу расхождение подтверждено кодом. Лимиты компании скаут в скоринге не нашёл. Рекомендую в риск не нести.\n' \
    | check_text "$home") || fail "a scout finding relayed to the captain was flagged: $out"
  out=$(printf 'Воркер прогнал E2E, но причину флака не нашёл.\n' | check_text "$home") \
    || fail "a worker finding relayed to the captain was flagged: $out"
  out=$(printf 'Скаут вернулся с отчётом. За пару попыток не нашёл, где падает.\n' | check_text "$home") \
    && fail "firstmate giving up in its own sentence passed: $out"
  printf '%s\n' "$out" | grep -F '"не нашёл" hands' >/dev/null || fail "own homework missed beside a scout mention: $out"
  out=$(printf 'В отчёте скаута не нашёл лимитов.\n' | check_text "$home") \
    && fail "a scout named only as the place firstmate searched excused its failure: $out"
  printf '%s\n' "$out" | grep -F '"не нашёл" hands' >/dev/null || fail "own homework in a scout report missed: $out"
  pass "a homework phrase fires on firstmate's own step, not on a worker's or scout's relayed finding"
}

test_hook_blocks_only_the_primary_session_once() {
  local home out
  home=$(make_home hook)
  out=$(run_hook "$home" "$home" false 'Готово: BACK-1. Делать?')
  printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("делать?"))' >/dev/null \
    || fail "a breaking reply in the primary session was not sent back: $out"
  out=$(run_hook "$home" "$home" true 'Готово: BACK-1. Делать?')
  [ -z "$out" ] || fail "a stop_hook_active turn was checked again: $out"
  out=$(run_hook "$home" "$TMP_ROOT" false 'Готово: BACK-1. Делать?')
  [ -z "$out" ] || fail "a session outside the primary home was checked: $out"
  out=$(run_hook "$home" "$home" false 'Фикс overdraft зелёный, MR на ревью у тебя.')
  [ -z "$out" ] || fail "a clean reply was blocked: $out"
  out=$(run_hook "$home" "$home" false 'Фикс overdraft зелёный, MR на ревью у тебя.' 'Готово: BACK-1. Делать?')
  [ -z "$out" ] || fail "the previous reply still at the transcript's end was judged: $out"
  out=$(run_hook "$home" "$home" false '' 'Готово: BACK-1. Делать?')
  [ -z "$out" ] || fail "a payload without last_assistant_message was judged from the transcript: $out"
  rm "$home/config/reply-check.json"
  out=$(run_hook "$home" "$home" false 'Готово: BACK-1. Делать?')
  [ -z "$out" ] || fail "a home without rules was checked: $out"
  pass "the hook judges only this turn's final reply, sends it back once, only in the primary session, only where rules exist"
}

test_text_mode_names_each_broken_rule
test_homework_spares_a_relayed_worker_finding
test_hook_blocks_only_the_primary_session_once
test_back_reference_is_flagged
