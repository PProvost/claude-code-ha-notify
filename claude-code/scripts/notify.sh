#!/usr/bin/env bash
#
# notify.sh - sends Claude Code hook events to a Home Assistant webhook, which
# forwards them to your phone through the companion app.
#
# Registered in hooks/hooks.json for four events:
#   Stop              Claude finished its turn.
#   Notification      Claude needs a permission, or is waiting for your input.
#   PreToolUse        Only for AskUserQuestion: Claude is asking you something.
#   UserPromptSubmit  You answered at the desk. Home Assistant then removes the
#                     notification and stops the reminders for this project.
#
# Reads the hook input (JSON) on stdin and posts:
#   {"event": "<stop|permission|idle|clear>", "project": "<name>", "message": "<text>"}
#
# Configuration, in order of precedence:
#   CLAUDE_NOTIFY_URL      / webhook_url option    The webhook URL (required)
#   CLAUDE_NOTIFY_CACERT   / ca_cert option        CA certificate for curl --cacert
#   CLAUDE_NOTIFY_INSECURE / insecure_tls option   Send with curl -k
#
# Mute: while .claude/notify-muted in the project holds a future Unix time, only
# "clear" events are sent. Set it with bin/notify-mute or /ha-notify:mute.
#
# This script always exits 0, so a notification problem never blocks Claude Code.
#
# Requirements: bash, curl, jq.
# Test without sending: CLAUDE_NOTIFY_DRY_RUN=1 (prints the payload instead).

set -u

# The maximum length of the message text. Home Assistant also cuts at 240.
MAX_MESSAGE_LENGTH=240

# The maximum time (in seconds) for the HTTP request. The hook must never hold
# up Claude Code waiting for Home Assistant.
CURL_TIMEOUT=5

log() { echo "ha-notify: $*" >&2; }

# Sourcing a missing file does not stop a bash script, and the functions below
# would then be silently absent: events would go out with an empty project name
# and the mute would never apply. Refuse to run instead.
HA_NOTIFY_LIB="$(dirname "${BASH_SOURCE[0]}")/../lib/project.sh"
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/project.sh
if ! . "$HA_NOTIFY_LIB" 2>/dev/null; then
  log "cannot load $HA_NOTIFY_LIB - this install is incomplete"
  exit 0
fi

# The webhook URL. CLAUDE_NOTIFY_URL wins, so a project or a manual install can
# override the value set once at plugin install time. There is no default: a
# guessed URL would silently post nowhere.
HA_WEBHOOK_URL="${CLAUDE_NOTIFY_URL:-${CLAUDE_PLUGIN_OPTION_WEBHOOK_URL:-}}"

# TLS. Certificate checking stays on unless explicitly turned off.
HA_CACERT="${CLAUDE_NOTIFY_CACERT:-${CLAUDE_PLUGIN_OPTION_CA_CERT:-}}"
HA_INSECURE="${CLAUDE_NOTIFY_INSECURE:-}"
[ -n "$HA_INSECURE" ] || \
  case "${CLAUDE_PLUGIN_OPTION_INSECURE_TLS:-}" in
    true | 1) HA_INSECURE=1 ;;
  esac

command -v jq   >/dev/null 2>&1 || { log "jq is not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { log "curl is not installed"; exit 0; }
[ -n "$HA_WEBHOOK_URL" ] || {
  log "no webhook URL: set the plugin's webhook_url option or CLAUDE_NOTIFY_URL"
  exit 0
}

input="$(cat)"
[ -n "$input" ] || exit 0

field() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }

hook_event="$(field '.hook_event_name')"
cwd="$(field '.cwd')"

project_dir="$(ha_notify_project_dir "${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}")"
project="$(basename "$project_dir")"

kind=""
message=""

case "$hook_event" in
  Stop)
    # If a Stop hook made Claude continue, this is not the end of the turn.
    [ "$(field '.stop_hook_active')" = "true" ] && exit 0
    kind="stop"

    # Use the last text that Claude wrote. Newer Claude Code versions put it in
    # the hook input; older ones do not, so fall back to the transcript.
    message="$(field '.last_assistant_message')"
    if [ -z "$message" ]; then
      transcript="$(field '.transcript_path')"
      if [ -n "$transcript" ] && [ -r "$transcript" ]; then
        message="$(tail -n 200 "$transcript" | jq -Rrn '
          [ inputs | fromjson?
            | select(.type == "assistant")
            | .message.content[]?
            | select(.type? == "text")
            | .text ]
          | last // empty' 2>/dev/null)"
      fi
    fi
    ;;

  Notification)
    message="$(field '.message')"
    case "$(field '.notification_type')" in
      permission_prompt)  kind="permission" ;;
      idle_prompt)        kind="idle" ;;
      elicitation_dialog) kind="permission" ;;
      "")
        # Older Claude Code versions do not send notification_type.
        # Find the type from the message text.
        case "$message" in
          *[Pp]ermission*) kind="permission" ;;
          *)               kind="idle" ;;
        esac
        ;;
      *)
        # Other types (for example auth_success) do not need you. Send nothing.
        exit 0
        ;;
    esac
    ;;

  PreToolUse)
    [ "$(field '.tool_name')" = "AskUserQuestion" ] || exit 0
    # There is no "question" kind. "idle" makes the notice urgent.
    kind="idle"
    message="$(field '.tool_input.questions[0].question')"
    [ -n "$message" ] || message="Has a question for you"
    ;;

  UserPromptSubmit)
    kind="clear"
    ;;

  *)
    exit 0
    ;;
esac

# While the mute is active nothing is sent. A "clear" always is: otherwise a
# notification muted mid-turn would keep reminding you after you had replied.
if [ "$kind" != "clear" ] && ha_notify_is_muted "$(ha_notify_mute_file "$project_dir")"; then
  exit 0
fi

payload="$(jq -nc \
  --arg event "$kind" \
  --arg project "$project" \
  --arg message "$message" \
  --argjson max "$MAX_MESSAGE_LENGTH" '
  { event: $event, project: $project }
  + ( $message | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
      | if . == "" then {}
        elif length > $max then { message: (.[0:($max - 1)] + "…") }
        else { message: . } end )')"

if [ "${CLAUDE_NOTIFY_DRY_RUN:-0}" = "1" ]; then
  echo "$payload"
  exit 0
fi

curl_opts=(-fsS --max-time "$CURL_TIMEOUT")
[ -n "$HA_CACERT" ]  && curl_opts+=(--cacert "$HA_CACERT")
[ "$HA_INSECURE" = "1" ] && curl_opts+=(-k)

curl "${curl_opts[@]}" \
  -X POST \
  -H 'Content-Type: application/json' \
  -d "$payload" \
  "$HA_WEBHOOK_URL" >/dev/null 2>&1 \
  || log "could not send the notification to $HA_WEBHOOK_URL"

exit 0
