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
 "homework_phrases": ["не нашёл", "дальше не стал"], "ask_endings": ["запускаю?", "делать?"]}
JSON
  printf '%s\n' "$home"
}

check_text() {
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" "$CHECK_BIN" --text
}

# Hook payload for a transcript whose last assistant message is <reply>.
run_hook() {  # <home> <cwd> <stop-hook-active> <reply>
  local home=$1 transcript="$1/transcript.jsonl"
  jq -nc '{type: "assistant", message: {content: [{type: "text", text: "earlier turn"}]}}' > "$transcript"
  jq -nc '{type: "user", message: {content: "status?"}}' >> "$transcript"
  jq -nc --arg t "$4" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}' >> "$transcript"
  jq -nc --arg c "$2" --arg t "$transcript" --argjson a "$3" \
    '{hook_event_name: "Stop", cwd: $c, transcript_path: $t, stop_hook_active: $a}' \
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
  rm "$home/config/reply-check.json"
  out=$(run_hook "$home" "$home" false 'Готово: BACK-1. Делать?')
  [ -z "$out" ] || fail "a home without rules was checked: $out"
  pass "the hook sends a breaking reply back once, only in the primary session, only where rules exist"
}

test_text_mode_names_each_broken_rule
test_hook_blocks_only_the_primary_session_once
