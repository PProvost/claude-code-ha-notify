#!/usr/bin/env bash
#
# Test suite for the Claude Code side of claude-code-ha-notify.
#
# Usage: tests/run-tests.sh [name-filter]
#
# The tests never reach the network: payload tests use CLAUDE_NOTIFY_DRY_RUN=1,
# and the tests that check how curl is called install a fake curl that records
# its arguments. Requires bash, jq, git.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

FILTER="${1:-}"
group() {
  case "$1" in
    *"$FILTER"*) printf '\n%s\n' "$1"; return 0 ;;
    *)           return 1 ;;
  esac
}

# ---- payload ----------------------------------------------------------------

test_payload() {
  group "payload" || return 0
  local project out
  project="$(make_project my-repo)"

  it "sends event, project and message when Claude finishes a turn"
  out="$(hook_stop "$project" "All done." | CLAUDE_NOTIFY_DRY_RUN=1 \
    CLAUDE_NOTIFY_URL=http://ha.test/api/webhook/x \
    CLAUDE_PROJECT_DIR="$project" bash "$NOTIFY_SH")"
  assert_eq "payload for a Stop event" \
    '{"event":"stop","project":"my-repo","message":"All done."}' "$out"
}

# ---- event mapping ----------------------------------------------------------

test_events() {
  group "events" || return 0
  local project out
  project="$(make_project my-repo)"

  run_hook() {
    CLAUDE_NOTIFY_DRY_RUN=1 CLAUDE_NOTIFY_URL=http://ha.test/api/webhook/x \
      CLAUDE_PROJECT_DIR="$project" bash "$NOTIFY_SH"
  }
  event_of() { jq -r '.event // empty' <<<"$1" 2>/dev/null; }

  it "maps a permission prompt to the permission event"
  out="$(hook_notification "$project" "Claude needs your permission" permission_prompt | run_hook)"
  assert_eq "event kind" permission "$(event_of "$out")"

  it "maps an idle prompt to the idle event"
  out="$(hook_notification "$project" "Waiting for your input" idle_prompt | run_hook)"
  assert_eq "event kind" idle "$(event_of "$out")"

  it "maps an elicitation dialog to the permission event"
  out="$(hook_notification "$project" "Needs more detail" elicitation_dialog | run_hook)"
  assert_eq "event kind" permission "$(event_of "$out")"

  it "guesses permission from the text when notification_type is missing"
  out="$(hook_notification "$project" "Claude needs your permission to run curl" | run_hook)"
  assert_eq "event kind" permission "$(event_of "$out")"

  it "guesses idle from the text when notification_type is missing"
  out="$(hook_notification "$project" "Waiting for your input" | run_hook)"
  assert_eq "event kind" idle "$(event_of "$out")"

  it "sends nothing for a notification type that does not need you"
  out="$(hook_notification "$project" "Logged in" auth_success | run_hook)"
  assert_empty "no payload" "$out"

  it "sends the question as an idle event when Claude asks something"
  out="$(hook_pretooluse "$project" AskUserQuestion "Which database?" | run_hook)"
  assert_eq "payload" '{"event":"idle","project":"my-repo","message":"Which database?"}' "$out"

  it "falls back to a default message when the question text is missing"
  out="$(hook_pretooluse "$project" AskUserQuestion "" | run_hook)"
  assert_contains "default message" '"message":"Has a question for you"' "$out"

  it "ignores PreToolUse for any other tool"
  out="$(hook_pretooluse "$project" Bash "" | run_hook)"
  assert_empty "no payload" "$out"

  it "sends clear when you answer at the desk"
  out="$(hook_prompt_submit "$project" | run_hook)"
  assert_eq "payload" '{"event":"clear","project":"my-repo"}' "$out"

  it "sends nothing when a Stop hook made Claude continue"
  out="$(hook_stop "$project" "Carrying on" true | run_hook)"
  assert_empty "no payload" "$out"

  it "ignores hook events it does not handle"
  out="$(jq -nc --arg c "$project" '{hook_event_name: "PostToolUse", cwd: $c}' | run_hook)"
  assert_empty "no payload" "$out"

  it "sends nothing when the hook input is empty"
  out="$(printf '' | run_hook)"
  assert_empty "no payload" "$out"
}

# ---- mute -------------------------------------------------------------------

test_mute() {
  group "mute" || return 0
  local project out expiry mutefile
  project="$(make_project my-repo)"
  mutefile="$project/.claude/notify-muted"

  run_hook() {
    CLAUDE_NOTIFY_DRY_RUN=1 CLAUDE_NOTIFY_URL=http://ha.test/api/webhook/x \
      CLAUDE_PROJECT_DIR="$project" bash "$NOTIFY_SH"
  }

  it "sends nothing for a finished turn while muted"
  echo "$(( $(date +%s) + 600 ))" > "$mutefile"
  out="$(hook_stop "$project" "Done." | run_hook)"
  assert_empty "no payload" "$out"

  it "still sends clear while muted"
  out="$(hook_prompt_submit "$project" | run_hook)"
  assert_eq "payload" '{"event":"clear","project":"my-repo"}' "$out"

  it "sends again once the mute has expired"
  echo "$(( $(date +%s) - 60 ))" > "$mutefile"
  out="$(hook_stop "$project" "Done." | run_hook)"
  assert_contains "payload" '"event":"stop"' "$out"

  it "treats an empty mute file as not muted"
  : > "$mutefile"
  out="$(hook_stop "$project" "Done." | run_hook)"
  assert_contains "payload" '"event":"stop"' "$out"

  it "treats an unreadable mute file as not muted"
  printf 'not a number\n' > "$mutefile"
  out="$(hook_stop "$project" "Done." | run_hook)"
  assert_contains "payload" '"event":"stop"' "$out"
  rm -f "$mutefile"
}

# ---- notify-mute ------------------------------------------------------------

test_notify_mute() {
  group "notify-mute" || return 0
  local project out rc expiry mutefile sub
  project="$(make_project my-repo)"
  mutefile="$project/.claude/notify-muted"

  it "mutes for two hours by default and says until when"
  out="$(cd "$project" && bash "$NOTIFY_MUTE" on)"
  assert_contains "status line" "muted until" "$out"

  it "writes the mute end time into the file"
  expiry="$(cat "$mutefile")"
  if [ "$expiry" -gt "$(( $(date +%s) + 7000 ))" ] && [ "$expiry" -le "$(( $(date +%s) + 7200 ))" ]; then
    pass
  else
    fail "end time about 120 minutes ahead" "~$(( $(date +%s) + 7200 ))" "$expiry"
  fi

  it "accepts a duration in minutes"
  (cd "$project" && bash "$NOTIFY_MUTE" on 30) >/dev/null
  expiry="$(cat "$mutefile")"
  if [ "$expiry" -gt "$(( $(date +%s) + 1700 ))" ] && [ "$expiry" -le "$(( $(date +%s) + 1800 ))" ]; then
    pass
  else
    fail "end time about 30 minutes ahead" "~$(( $(date +%s) + 1800 ))" "$expiry"
  fi

  it "reports the mute when asked for status"
  out="$(cd "$project" && bash "$NOTIFY_MUTE" status)"
  assert_contains "status line" "muted until" "$out"

  it "removes the mute"
  out="$(cd "$project" && bash "$NOTIFY_MUTE" off)"
  assert_eq "status line" "notifications on" "$out"

  it "deletes the mute file when unmuting"
  if [ -e "$mutefile" ]; then fail "the mute file to be gone" "(absent)" "(present)"; else pass; fi

  it "reports status by default"
  out="$(cd "$project" && bash "$NOTIFY_MUTE")"
  assert_eq "status line" "notifications on" "$out"

  it "rejects an unknown argument with usage and exit 2"
  out="$(cd "$project" && bash "$NOTIFY_MUTE" sideways 2>&1)"; rc=$?
  assert_eq "exit code" 2 "$rc"

  it "prints the usage on stderr, not stdout"
  out="$(cd "$project" && bash "$NOTIFY_MUTE" sideways 2>/dev/null)"
  assert_empty "nothing on stdout" "$out"

  it "rejects a duration that is not a number"
  (cd "$project" && bash "$NOTIFY_MUTE" on abc) >/dev/null 2>&1; rc=$?
  assert_eq "exit code" 2 "$rc"

  # The divergence this guards against: the hook gets CLAUDE_PROJECT_DIR, but
  # notify-mute runs in the Bash tool, which does not. If one used the git root
  # and the other the starting directory, they would use different files and the
  # mute would silently do nothing. See design spec section 8 item 6.
  it "uses the same mute file whether run from the repo root or a subdirectory"
  sub="$project/deep/nested"
  mkdir -p "$sub"
  (cd "$sub" && env -u CLAUDE_PROJECT_DIR bash "$NOTIFY_MUTE" on) >/dev/null
  out="$(hook_stop "$project" "Done." | CLAUDE_NOTIFY_DRY_RUN=1 \
    CLAUDE_NOTIFY_URL=http://ha.test/api/webhook/x \
    CLAUDE_PROJECT_DIR="$project" bash "$NOTIFY_SH")"
  assert_empty "the hook sees the mute set from a subdirectory" "$out"
  (cd "$project" && bash "$NOTIFY_MUTE" off) >/dev/null
}

# ---- url and transport ------------------------------------------------------

test_transport() {
  group "transport" || return 0
  local project args out rc tmp
  project="$(make_project my-repo)"

  # Each case runs the hook for real against a fake curl that records its
  # arguments, so these check the actual request, not a dry-run summary.
  record() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/ccnotify-curl.XXXXXX")"
    (
      fake_curl "$dir" >/dev/null
      hook_stop "$project" "Done." | env "$@" bash "$NOTIFY_SH" >/dev/null 2>&1
    )
    cat "$dir/fakebin/curl-args" 2>/dev/null
  }

  it "posts JSON to the webhook URL"
  args="$(record CLAUDE_PROJECT_DIR="$project" CLAUDE_NOTIFY_URL=http://ha.test/api/webhook/abc)"
  assert_contains "the URL" "http://ha.test/api/webhook/abc" "$args"

  it "sends the payload as the request body"
  assert_contains "the payload" '"event":"stop"' "$args"

  it "sets the JSON content type"
  assert_contains "the header" "Content-Type: application/json" "$args"

  it "lets CLAUDE_NOTIFY_URL override the plugin option"
  args="$(record CLAUDE_PROJECT_DIR="$project" \
    CLAUDE_PLUGIN_OPTION_WEBHOOK_URL=http://option.test/hook \
    CLAUDE_NOTIFY_URL=http://env.test/hook)"
  assert_contains "the environment URL" "http://env.test/hook" "$args"

  it "uses the plugin option when the environment variable is unset"
  args="$(record CLAUDE_PROJECT_DIR="$project" \
    CLAUDE_PLUGIN_OPTION_WEBHOOK_URL=http://option.test/hook)"
  assert_contains "the option URL" "http://option.test/hook" "$args"

  it "logs and gives up quietly when no URL is configured"
  out="$(hook_stop "$project" "Done." | env -u CLAUDE_NOTIFY_URL \
    -u CLAUDE_PLUGIN_OPTION_WEBHOOK_URL CLAUDE_PROJECT_DIR="$project" \
    bash "$NOTIFY_SH" 2>&1 >/dev/null)"
  assert_contains "a message naming the missing setting" "webhook" "$out"

  it "never blocks Claude Code, even with no URL configured"
  hook_stop "$project" "Done." | env -u CLAUDE_NOTIFY_URL \
    -u CLAUDE_PLUGIN_OPTION_WEBHOOK_URL CLAUDE_PROJECT_DIR="$project" \
    bash "$NOTIFY_SH" >/dev/null 2>&1; rc=$?
  assert_eq "exit code" 0 "$rc"

  it "checks certificates by default"
  args="$(record CLAUDE_PROJECT_DIR="$project" CLAUDE_NOTIFY_URL=https://ha.test/hook)"
  assert_not_contains "no -k flag" "-k" "$args"

  it "skips certificate checks only when CLAUDE_NOTIFY_INSECURE is set"
  args="$(record CLAUDE_PROJECT_DIR="$project" CLAUDE_NOTIFY_URL=https://ha.test/hook \
    CLAUDE_NOTIFY_INSECURE=1)"
  assert_contains "the -k flag" "-k" "$args"

  it "skips certificate checks when the insecure_tls option is true"
  args="$(record CLAUDE_PROJECT_DIR="$project" CLAUDE_NOTIFY_URL=https://ha.test/hook \
    CLAUDE_PLUGIN_OPTION_INSECURE_TLS=true)"
  assert_contains "the -k flag" "-k" "$args"

  it "ignores an insecure_tls option that is not true"
  args="$(record CLAUDE_PROJECT_DIR="$project" CLAUDE_NOTIFY_URL=https://ha.test/hook \
    CLAUDE_PLUGIN_OPTION_INSECURE_TLS=false)"
  assert_not_contains "no -k flag" "-k" "$args"

  it "passes a CA certificate from the environment to curl"
  args="$(record CLAUDE_PROJECT_DIR="$project" CLAUDE_NOTIFY_URL=https://ha.test/hook \
    CLAUDE_NOTIFY_CACERT=/etc/ssl/my-ca.pem)"
  assert_contains "the --cacert flag" "--cacert" "$args"

  it "passes the CA certificate path itself"
  assert_contains "the path" "/etc/ssl/my-ca.pem" "$args"

  it "passes a CA certificate from the plugin option to curl"
  args="$(record CLAUDE_PROJECT_DIR="$project" CLAUDE_NOTIFY_URL=https://ha.test/hook \
    CLAUDE_PLUGIN_OPTION_CA_CERT=/opt/ca/option.pem)"
  assert_contains "the option path" "/opt/ca/option.pem" "$args"

  it "lets CLAUDE_NOTIFY_CACERT override the ca_cert option"
  args="$(record CLAUDE_PROJECT_DIR="$project" CLAUDE_NOTIFY_URL=https://ha.test/hook \
    CLAUDE_PLUGIN_OPTION_CA_CERT=/opt/ca/option.pem \
    CLAUDE_NOTIFY_CACERT=/etc/ssl/env.pem)"
  assert_contains "the environment path" "/etc/ssl/env.pem" "$args"

  it "does not also pass the overridden option path"
  assert_not_contains "the option path" "/opt/ca/option.pem" "$args"

  it "exits 0 even when the request fails"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ccnotify-fail.XXXXXX")/fakebin"
  mkdir -p "$tmp"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$tmp/curl"; chmod +x "$tmp/curl"
  hook_stop "$project" "Done." | PATH="$tmp:$PATH" CLAUDE_PROJECT_DIR="$project" \
    CLAUDE_NOTIFY_URL=https://ha.test/hook bash "$NOTIFY_SH" >/dev/null 2>&1; rc=$?
  assert_eq "exit code" 0 "$rc"

  it "logs when the request fails"
  out="$(hook_stop "$project" "Done." | PATH="$tmp:$PATH" CLAUDE_PROJECT_DIR="$project" \
    CLAUDE_NOTIFY_URL=https://ha.test/hook bash "$NOTIFY_SH" 2>&1 >/dev/null)"
  assert_contains "a failure message" "ha-notify" "$out"
}

# ---- message and project name -----------------------------------------------

test_message() {
  group "message" || return 0
  local project out long cut transcript nogit sub
  project="$(make_project my-repo)"

  run_hook() {
    CLAUDE_NOTIFY_DRY_RUN=1 CLAUDE_NOTIFY_URL=http://ha.test/api/webhook/x \
      CLAUDE_PROJECT_DIR="${1:-$project}" bash "$NOTIFY_SH"
  }
  message_of() { jq -r '.message // empty' <<<"$1" 2>/dev/null; }

  it "collapses newlines and runs of spaces into single spaces"
  out="$(hook_stop "$project" "$(printf 'First line.\n\nSecond    line.')" | run_hook)"
  assert_eq "message" "First line. Second line." "$(message_of "$out")"

  it "trims surrounding whitespace"
  out="$(hook_stop "$project" "   padded   " | run_hook)"
  assert_eq "message" "padded" "$(message_of "$out")"

  it "cuts a long message to 240 characters"
  long="$(printf 'x%.0s' $(seq 1 400))"
  out="$(hook_stop "$project" "$long" | run_hook)"
  cut="$(message_of "$out")"
  assert_eq "message length" 240 "${#cut}"

  it "marks a cut message with an ellipsis"
  assert_contains "the ellipsis" "…" "$cut"

  it "keeps a message of exactly 240 characters whole"
  long="$(printf 'y%.0s' $(seq 1 240))"
  out="$(hook_stop "$project" "$long" | run_hook)"
  assert_not_contains "no ellipsis" "…" "$(message_of "$out")"

  it "leaves the message out entirely when there is no text"
  out="$(hook_stop "$project" "" | run_hook)"
  assert_eq "payload" '{"event":"stop","project":"my-repo"}' "$out"

  it "reads the last thing Claude wrote from the transcript when the hook input omits it"
  transcript="$project/transcript.jsonl"
  {
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Earlier text."}]}}'
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"A question."}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"The final answer."}]}}'
  } > "$transcript"
  out="$(jq -nc --arg c "$project" --arg t "$transcript" \
    '{hook_event_name: "Stop", cwd: $c, transcript_path: $t}' | run_hook)"
  assert_eq "message" "The final answer." "$(message_of "$out")"

  it "survives a transcript that is missing or unreadable"
  out="$(jq -nc --arg c "$project" '{hook_event_name: "Stop", cwd: $c, transcript_path: "/nope/missing.jsonl"}' | run_hook)"
  assert_eq "payload" '{"event":"stop","project":"my-repo"}' "$out"

  it "names the project after the git repository root, not the working directory"
  sub="$project/packages/inner"
  mkdir -p "$sub"
  out="$(hook_stop "$sub" "Done." | run_hook "$sub")"
  assert_contains "the repository name" '"project":"my-repo"' "$out"

  it "falls back to the directory name outside a git repository"
  nogit="$(mktemp -d "${TMPDIR:-/tmp}/ccnotify-nogit.XXXXXX")/plain-dir"
  mkdir -p "$nogit"
  out="$(hook_stop "$nogit" "Done." | run_hook "$nogit")"
  assert_contains "the directory name" '"project":"plain-dir"' "$out"
}

# ---- install layout ---------------------------------------------------------

# The manual install (claude-code/manual-install.md) copies the three files into
# .claude/hooks, .claude/lib and .claude/bin. Both scripts find the shared lib
# one directory up from their own, so that layout has to keep working.
test_layout() {
  group "layout" || return 0
  local project out rc
  project="$(make_project my-repo)"
  mkdir -p "$project/.claude/hooks" "$project/.claude/lib" "$project/.claude/bin"
  cp "$REPO_ROOT/claude-code/scripts/notify.sh" "$project/.claude/hooks/"
  cp "$REPO_ROOT/claude-code/lib/project.sh"    "$project/.claude/lib/"
  cp "$REPO_ROOT/claude-code/bin/notify-mute"   "$project/.claude/bin/"

  it "the hook runs from the manual install layout"
  out="$(hook_stop "$project" "Done." | CLAUDE_NOTIFY_DRY_RUN=1 \
    CLAUDE_NOTIFY_URL=http://ha.test/hook CLAUDE_PROJECT_DIR="$project" \
    bash "$project/.claude/hooks/notify.sh" 2>/dev/null)"
  assert_contains "a payload" '"event":"stop"' "$out"

  it "notify-mute runs from the manual install layout"
  out="$(cd "$project" && bash "$project/.claude/bin/notify-mute" status 2>/dev/null)"
  assert_eq "status line" "notifications on" "$out"

  it "the mute set by the copied toggle is seen by the copied hook"
  (cd "$project" && bash "$project/.claude/bin/notify-mute" on 10) >/dev/null 2>&1
  out="$(hook_stop "$project" "Done." | CLAUDE_NOTIFY_DRY_RUN=1 \
    CLAUDE_NOTIFY_URL=http://ha.test/hook CLAUDE_PROJECT_DIR="$project" \
    bash "$project/.claude/hooks/notify.sh" 2>/dev/null)"
  assert_empty "no payload" "$out"
  (cd "$project" && bash "$project/.claude/bin/notify-mute" off) >/dev/null 2>&1
}

# ---- broken install ---------------------------------------------------------

# Both scripts source lib/project.sh. Sourcing a missing file does not stop a
# bash script, so without a guard the hook would post events with an empty
# project name and notify-mute would report "notifications on" while muting
# nothing. Either is worse than a visible error.
test_broken_install() {
  group "broken" || return 0
  local project out rc broken
  project="$(make_project my-repo)"
  broken="$project/broken"
  mkdir -p "$broken/scripts" "$broken/bin"
  cp "$REPO_ROOT/claude-code/scripts/notify.sh" "$broken/scripts/"
  cp "$REPO_ROOT/claude-code/bin/notify-mute"   "$broken/bin/"

  it "the hook sends nothing when its library is missing"
  out="$(hook_stop "$project" "Done." | CLAUDE_NOTIFY_DRY_RUN=1 \
    CLAUDE_NOTIFY_URL=http://ha.test/hook CLAUDE_PROJECT_DIR="$project" \
    bash "$broken/scripts/notify.sh" 2>/dev/null)"
  assert_empty "no payload at all" "$out"

  it "the hook says what is wrong when its library is missing"
  out="$(hook_stop "$project" "Done." | CLAUDE_NOTIFY_DRY_RUN=1 \
    CLAUDE_NOTIFY_URL=http://ha.test/hook CLAUDE_PROJECT_DIR="$project" \
    bash "$broken/scripts/notify.sh" 2>&1 >/dev/null)"
  assert_contains "a message naming the library" "project.sh" "$out"

  it "the hook still does not block Claude Code when its library is missing"
  hook_stop "$project" "Done." | CLAUDE_NOTIFY_DRY_RUN=1 \
    CLAUDE_NOTIFY_URL=http://ha.test/hook CLAUDE_PROJECT_DIR="$project" \
    bash "$broken/scripts/notify.sh" >/dev/null 2>&1; rc=$?
  assert_eq "exit code" 0 "$rc"

  it "notify-mute fails loudly when its library is missing"
  (cd "$project" && bash "$broken/bin/notify-mute" on) >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then pass; else fail "a non-zero exit" "not 0" "$rc"; fi

  it "notify-mute does not claim notifications are on when its library is missing"
  out="$(cd "$project" && bash "$broken/bin/notify-mute" status 2>/dev/null)"
  assert_not_contains "no misleading status" "notifications on" "$out"
}

# ---- run --------------------------------------------------------------------

test_payload
test_events
test_mute
test_notify_mute
test_transport
test_message
test_layout
test_broken_install

printf '\n%d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
