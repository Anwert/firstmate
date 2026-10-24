#!/usr/bin/env bash
# fm-browser-tool-lib.sh - the single owner of a home's browser-tool choice
# (docs/configuration.md "Browser tool (config/browser-tool)").
#
# Sourced, never executed. bin/fm-brief.sh names the chosen tool in generated
# briefs, and bin/fm-bootstrap.sh requires it only when it is a CLI and reports
# an invalid value.
#
#   fm_browser_tool <config-dir>
#       Prints chrome-devtools-axi (the default, when config/browser-tool is
#       absent or empty) or claude-in-chrome. Any other value prints an error
#       and returns 1, so a typo never silently falls back to the default.
#
#   fm_browser_rule_phrase <config-dir>
#       Prints the brief phrase naming the chosen browser tool, completing
#       "Use <cli> for GitHub operations and ...".

fm_browser_tool() {
  local file=$1/browser-tool value=''
  [ -f "$file" ] && IFS= read -r value < "$file"
  value=${value//[[:space:]]/}
  case "$value" in
    '') printf '%s\n' chrome-devtools-axi ;;
    chrome-devtools-axi|claude-in-chrome) printf '%s\n' "$value" ;;
    *)
      echo "error: invalid config/browser-tool - holds '$value'; expected one of: chrome-devtools-axi claude-in-chrome" >&2
      return 1
      ;;
  esac
}

fm_browser_rule_phrase() {
  local tool
  tool=$(fm_browser_tool "$1") || return 1
  # shellcheck disable=SC2016  # backticks are literal brief text, not command substitution.
  case "$tool" in
    claude-in-chrome) printf '%s\n' 'the Claude in Chrome tools (`mcp__claude-in-chrome__*`, loaded with one ToolSearch) for browser operations, in your own new tab only' ;;
    *) printf '%s\n' "$tool for browser operations" ;;
  esac
}
