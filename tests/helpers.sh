# Shared helpers for the claude-code-ha-notify test suite.
# Sourced by run-tests.sh. Not executable on its own.
# shellcheck shell=bash

# NOTIFY_SH and NOTIFY_MUTE are used by run-tests.sh.
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY_SH="$REPO_ROOT/claude-code/scripts/notify.sh"
NOTIFY_MUTE="$REPO_ROOT/claude-code/bin/notify-mute"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

# ---- test declaration -------------------------------------------------------

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$CURRENT_TEST"
  printf '       %s\n' "$1"
  [ -n "${2:-}" ] && printf '       expected: %s\n       actual:   %s\n' "$2" "${3:-}"
  return 0
}

pass() { printf '  \033[32mok\033[0m   %s\n' "$CURRENT_TEST"; }

# ---- assertions -------------------------------------------------------------

assert_eq() {
  if [ "$2" = "$3" ]; then pass; else fail "$1" "$2" "$3"; fi
}

assert_contains() {
  case "$3" in
    *"$2"*) pass ;;
    *)      fail "$1" "something containing '$2'" "$3" ;;
  esac
}

assert_not_contains() {
  case "$3" in
    *"$2"*) fail "$1" "something without '$2'" "$3" ;;
    *)      pass ;;
  esac
}

assert_empty() {
  if [ -z "$2" ]; then pass; else fail "$1" "(no output)" "$2"; fi
}

# ---- fixtures ---------------------------------------------------------------

# Makes an isolated project directory that looks like a git repo, so the
# scripts resolve a stable project name and mute path. Echoes the path.
make_project() {
  local name="${1:-test-project}" dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/ccnotify.XXXXXX")/$name"
  mkdir -p "$dir/.claude"
  git -C "$dir" init -q 2>/dev/null
  echo "$dir"
}

# Installs a fake curl that records its arguments instead of sending anything,
# and prepends it to PATH. Call inside a subshell. Echoes the record file path.
fake_curl() {
  local bindir="${1:?bindir required}/fakebin"
  mkdir -p "$bindir"
  cat > "$bindir/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS_FILE"
exit 0
STUB
  chmod +x "$bindir/curl"
  export PATH="$bindir:$PATH"
  export CURL_ARGS_FILE="$bindir/curl-args"
  echo "$CURL_ARGS_FILE"
}

# Hook input builders. Each echoes one line of JSON on stdout.
hook_stop() {
  jq -nc --arg cwd "$1" --arg msg "${2:-}" --argjson active "${3:-false}" \
    '{hook_event_name: "Stop", cwd: $cwd, stop_hook_active: $active}
     + (if $msg == "" then {} else {last_assistant_message: $msg} end)'
}

hook_notification() {
  jq -nc --arg cwd "$1" --arg msg "${2:-}" --arg type "${3:-}" \
    '{hook_event_name: "Notification", cwd: $cwd, message: $msg}
     + (if $type == "" then {} else {notification_type: $type} end)'
}

hook_pretooluse() {
  jq -nc --arg cwd "$1" --arg tool "${2:-AskUserQuestion}" --arg q "${3:-}" \
    '{hook_event_name: "PreToolUse", cwd: $cwd, tool_name: $tool}
     + (if $q == "" then {} else {tool_input: {questions: [{question: $q}]}} end)'
}

hook_prompt_submit() {
  jq -nc --arg cwd "$1" '{hook_event_name: "UserPromptSubmit", cwd: $cwd}'
}

# ---- Codex hook input builders ----------------------------------------------
# Codex sends one JSON object on stdin like Claude Code does, with the same
# hook_event_name / cwd / transcript_path fields, so most of the hook is shared.
# These match the payloads in https://learn.chatgpt.com/docs/hooks.md

codex_stop() {
  jq -nc --arg cwd "$1" --arg msg "${2:-}" --argjson active "${3:-false}" \
    '{session_id: "thr_123", transcript_path: null, cwd: $cwd,
      hook_event_name: "Stop", model: "gpt-5-codex", turn_id: "turn_1",
      permission_mode: "default", stop_hook_active: $active}
     + (if $msg == "" then {} else {last_assistant_message: $msg} end)'
}

codex_prompt_submit() {
  jq -nc --arg cwd "$1" --arg prompt "${2:-do the thing}" \
    '{session_id: "thr_123", cwd: $cwd, hook_event_name: "UserPromptSubmit",
      model: "gpt-5-codex", prompt: $prompt}'
}

codex_permission_request() {
  jq -nc --arg cwd "$1" --arg tool "${2:-}" --arg cmd "${3:-}" \
    '{session_id: "thr_123", cwd: $cwd, hook_event_name: "PermissionRequest",
      model: "gpt-5-codex", turn_id: "turn_1"}
     + (if $tool == "" then {} else {tool_name: $tool} end)
     + (if $cmd == "" then {} else {tool_input: {command: $cmd}} end)'
}
