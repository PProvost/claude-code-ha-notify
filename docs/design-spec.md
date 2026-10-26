# claude-code-ha-notify — design

Status: working end to end, 2026-10-26. The plugin is installed, the package is
loaded, and a finished turn in Claude Code reaches the phone with buttons.
Untested so far: the reminder loop, the three buttons, night mode and the
morning release. `master-table-analysis` has not been migrated (section 9).

Origin: the hook and Home Assistant setup built in the `master-table-analysis` project (commits `5cc8a91a`, `e534cf39`).

## 1. Purpose

Send Claude Code events to a phone through Home Assistant, so you know when Claude has finished a turn, needs a permission, or is waiting for you, while you are away from the desk.

```
Claude Code hook ──HTTP POST (JSON)──▶ Home Assistant webhook ──▶ companion app ──▶ phone
 (dev environment)                      (automation + scripts)
```

The repo has two parts, installed in two different places:

| Folder | Installed in | How |
|---|---|---|
| `claude-code/` | The dev environment (where Claude Code runs) | Claude Code plugin (`/plugin install`), or a manual copy |
| `home-assistant/` | Home Assistant | One YAML package, plus two Local To-do lists created in the UI |

The only thing the two parts share is the payload contract (section 6).

## 2. Decisions

| # | Topic | Decision | Why |
|---|---|---|---|
| 1 | Claude Code install | Plugin as the main route; manual install documented as a fallback | One-command install and updates; the fallback covers people who can't use plugins |
| 2 | Webhook URL | Plugin `userConfig` option `webhook_url` (`sensitive: true`); environment variable `CLAUDE_NOTIFY_URL` overrides it | The webhook ID works as a password (Home Assistant webhooks have no login). `userConfig` asks once at install. The variable covers the manual install and per-project overrides, which `userConfig` can't do (it is user level only) |
| 3 | TLS | Optional `ca_cert` (type `file`) → `curl --cacert`; `insecure_tls` (boolean, default `false`) → `curl -k`. Overrides: `CLAUDE_NOTIFY_CACERT`, `CLAUDE_NOTIFY_INSECURE=1` | Certificate checking stays on by default; internal-CA users get a proper fix; `-k` stays available |
| 4 | Mute toggle | Executable `bin/notify-mute` (used as `! notify-mute on`) plus a slash command `/ha-notify:mute` | `!` costs no model turn; the slash command is easy to find |
| 5 | Home Assistant packaging | One YAML package; user values in `secrets.yaml`; night-mode times as `input_datetime` helpers; two Local To-do lists created in the UI | The 3 automations and 2 scripts refer to each other by entity ID; a package keeps that wiring in one file. Updates mean replacing the file, with nothing to re-edit |
| 6 | Desk mute and phone mute | Kept separate; the README explains the difference | The desk mute works when Home Assistant can't be reached and can always report its state locally. The webhook is one-way, so a merged mute would need a second secret (a long-lived access token) to report status |
| 7 | Names | Repo `claude-code-ha-notify`; plugin `ha-notify`; marketplace `ha-notify` | Plugin names starting with `claude-` are reserved (validation error) |
| 8 | License | MIT; public repo | |
| 9 | Android | Add `priority: high`, `ttl: 0` and a `channel` to notify calls; marked untested in the README | iOS ignores these keys; no Android device is available to test |

## 3. Repo layout

```
claude-code-ha-notify/
├── README.md                    # how it works; Part 1: Home Assistant; Part 2: Claude Code; payload contract
├── LICENSE                      # MIT
├── .claude-plugin/
│   └── marketplace.json         # marketplace "ha-notify", one entry: source "./claude-code"
├── claude-code/                 # → dev environment
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json
│   ├── scripts/notify.sh        # the hook (today: claude-notify.sh)
│   ├── bin/notify-mute          # the mute toggle (today: claude-notify-mute)
│   ├── commands/mute.md         # /ha-notify:mute
│   └── manual-install.md        # fallback: copy scripts + settings.json snippet
├── home-assistant/              # → Home Assistant
│   ├── packages/claude_code_notify.yaml
│   ├── secrets.example.yaml
│   └── README.md                # install steps (section 5.3)
└── tests/                       # dry-run cases, run in CI
```

## 4. Claude Code side

### 4.1 plugin.json

- `name: "ha-notify"`, `version`, `description`, `author`, `license: "MIT"`, `repository`.
- `userConfig`:

| Key | type | Required | Default | sensitive | Purpose |
|---|---|---|---|---|---|
| `webhook_url` | string | yes | — | yes | Full Home Assistant webhook URL |
| `ca_cert` | file | no | — | no | CA certificate for `curl --cacert` |
| `insecure_tls` | boolean | no | `false` | no | Use `curl -k` |

Hooks receive these as `CLAUDE_PLUGIN_OPTION_WEBHOOK_URL`, `CLAUDE_PLUGIN_OPTION_CA_CERT`, `CLAUDE_PLUGIN_OPTION_INSECURE_TLS`.

Don't use `options` on any field: it raises the minimum Claude Code version to v2.1.271.

### 4.2 hooks/hooks.json

The same four registrations as today, each running `"\"${CLAUDE_PLUGIN_ROOT}\"/scripts/notify.sh"`:

- `Stop`
- `Notification`
- `PreToolUse` with matcher `AskUserQuestion`
- `UserPromptSubmit` (sends `clear`)

The file needs the top-level `"hooks"` wrapper.

### 4.3 scripts/notify.sh: changes from today's claude-notify.sh

1. **URL.** Use `CLAUDE_NOTIFY_URL`, then `CLAUDE_PLUGIN_OPTION_WEBHOOK_URL`. Remove the hard-coded default. If neither is set, log to stderr and exit 0.
2. **TLS.** Use `--cacert` when `CLAUDE_NOTIFY_CACERT` or the `ca_cert` option is set. Use `-k` only when `CLAUDE_NOTIFY_INSECURE=1` or `insecure_tls` is true. Never add `-k` by default.
3. **Mute file location.** `$CLAUDE_PROJECT_DIR/.claude/notify-muted`, not relative to the script (the plugin root is a shared cache that changes on update).
4. **Mute expiry stored in the file.** `notify-mute on [minutes]` writes the end time (Unix seconds) into the file. The hook mutes only while `now < end time`. This removes today's duplicated `MUTE_MINUTES` constant. It also matters because the Bash tool environment, which runs `notify-mute`, does not receive `CLAUDE_PLUGIN_OPTION_*` values. An empty or unreadable file means "not muted".
5. Everything else stays as it is: event mapping, `stop_hook_active` check, transcript fallback, 240-character cut, `CLAUDE_NOTIFY_DRY_RUN`, always exit 0.

### 4.4 bin/notify-mute

- `on [minutes]` (default 120; running it again restarts the time), `off`, `status` (the default).
- Project directory: `CLAUDE_PROJECT_DIR` if set, else `git rev-parse --show-toplevel`, else `$PWD`. The hook and this script must resolve to the same directory (see section 8).
- The README tells users to add `/.claude/notify-muted` to each project's `.gitignore`.

### 4.5 commands/mute.md

`/ha-notify:mute [on [minutes]|off|status]`. Runs `bin/notify-mute` with the argument and reports the result in one line. The docs say `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PROJECT_DIR}` are substituted in command content, so the command can pass the exact paths. The docs recommend `skills/` over `commands/` for new plugins, so decide which to use when building.

### 4.6 Manual install (fallback)

Copy `scripts/notify.sh` and `bin/notify-mute` into `.claude/hooks/`, then paste a `settings.json` snippet with the four hooks and an `env` block containing `CLAUDE_NOTIFY_URL` (plus optional `CLAUDE_NOTIFY_CACERT` / `CLAUDE_NOTIFY_INSECURE`). This is what `master-table-analysis` has today.

### 4.7 Devcontainer note for the README

Sensitive `userConfig` values are stored in `~/.claude/.credentials.json` on Linux; non-sensitive ones go under `pluginConfigs` in `~/.claude/settings.json`. Both are lost on rebuild unless `~/.claude` is a volume, for example:

```jsonc
"mounts": ["source=${devcontainerId}-claude-config,target=/home/vscode/.claude,type=volume"]
```

## 5. Home Assistant side

### 5.1 Package contents (`packages/claude_code_notify.yaml`)

| Item | ID | Source (Appendix B) | Changes |
|---|---|---|---|
| Automation: webhook | `claude_code_phone` | B.1 | `webhook_id: !secret claude_code_webhook_id`; notify action from the secret |
| Automation: night-mode schedule | `claude_code_night_mode` | B.2 | Times from `input_datetime.claude_night_start` / `claude_night_end` instead of fixed times; optional |
| Automation: morning release | `claude_code_morning_release` | B.3 | None |
| Script: notify phone | `claude_code_notify` | B.4 | Notify action from the secret (4 places); durations in one variables block; Android keys; generic description |
| Script: hold event | `claude_code_hold` | B.5 | None |
| Helper | `input_boolean.claude_night_mode` | — | Defined in the package |
| Helpers | `input_datetime.claude_night_start` / `claude_night_end` | — | New; time only |

Every automation gets an `id:` so traces work. The two To-do lists can't be created from YAML (Local To-do is UI-only).

Durations to collect in one variables block in the notify script: reminder interval 10 min, reminder count 3, snooze 5 min, ignore length 1 h. Night defaults are 22:00 and 06:30.

### 5.2 secrets.yaml

```yaml
claude_code_webhook_id: "<long random string>"
claude_code_notify_service: notify.mobile_app_your_phone
```

### 5.3 Install steps (for home-assistant/README.md)

Before you start: the companion app on your phone, a way to edit `/config` (the File editor or Studio Code Server add-on, or direct file access), and the minimum Home Assistant version (to be confirmed).

1. Settings → Devices & services → Add integration → **Local To-do**, twice: `Claude muted` and `Claude pending`. Check the entity IDs are `todo.claude_muted` and `todo.claude_pending`.
2. Turn on packages in `configuration.yaml` (add to an existing `homeassistant:` block if there is one):
   ```yaml
   homeassistant:
     packages: !include_dir_named packages
   ```
3. Copy `claude_code_notify.yaml` to `/config/packages/`.
4. Add the two values to `secrets.yaml` (5.2).
5. Developer Tools → YAML → Check configuration, then restart. Later updates only need "Reload automations" and "Reload scripts".
6. Set the night times in the two `input_datetime` helpers, if the defaults don't suit you.
7. Set up the Claude Code side with the same webhook URL and send a test event.

### 5.4 README caveats

- Automations defined in YAML are read-only in the UI; traces still work.
- `local_only: true`: the webhook only accepts requests from the local network. Remote or cloud dev environments can't reach it.
- Tested on iOS. Android keys are included but untested.
- Desk mute (dev environment file) and phone mute ("Ignore 1h" → `todo.claude_muted`) are separate. The desk mute stops events before they're sent; the phone mute makes Home Assistant drop them.

## 6. Payload contract

`POST` to the webhook URL, `Content-Type: application/json`:

```json
{"event": "stop|permission|idle|clear", "project": "<git repo name or directory name>", "message": "<text, optional, max 240 chars>"}
```

- `stop`: Claude finished its turn. `message` is the last text Claude wrote.
- `permission`: permission prompt or elicitation dialog.
- `idle`: waiting for input, or an `AskUserQuestion` question (`message` is the question).
- `clear`: the user answered at the desk. Home Assistant removes the notification, stops reminders and drops the held night event. Always sent, even while muted.

No version field for now; add one only if the format changes.

## 7. Checks and CI

- `shellcheck` on both scripts.
- `claude plugin validate --strict ./claude-code` (and the marketplace).
- `yamllint` on the Home Assistant package.
- `tests/`: dry-run cases with `CLAUDE_NOTIFY_DRY_RUN=1`: not muted (sent), muted stop (not sent), muted clear (sent), expired mute (sent), missing URL (logs, exit 0), unknown argument to `notify-mute` (usage, exit 2), TLS flag selection.
- A full Home Assistant config check in CI is possible but heavy; leave it out at first.

## 8. Verified while building

All six are settled. Items 2 and 5 were confirmed against a live Home Assistant;
the rest were verified locally.

| # | Question | Answer |
|---|---|---|
| 1 | Does `!` find `bin/notify-mute` on the PATH? | **Yes.** Claude Code injects `<plugin>/bin` into the Bash tool's PATH — it appears there even for a plugin version whose directory no longer exists. `! notify-mute on` works, and the slash command stays as the discoverable route |
| 2 | Does `action: !secret ...` work? | **Yes.** Check configuration passes, and a script trace shows the resolved action name, so the secret is substituted before validation. No script variable or wrapper needed |
| 3 | Minimum Home Assistant version | **2024.10**, from the plural `triggers:` / `conditions:` / `actions:` keys and `action:` service calls. Derived from the syntax used, not tested against older versions |
| 4 | Marketplace naming rules for `ha-notify` | Fine. `claude plugin validate --strict` passes on both manifests; only `claude-` prefixes are reserved |
| 5 | `input_datetime` `initial:` | **Omit it**, so the times survive a restart. A fresh install therefore starts at 00:00, so the night schedule no-ops while the two times are equal rather than flipping night mode at midnight. Setting them is an install step |
| 6 | Is `CLAUDE_PROJECT_DIR` the git top level? | **Not reliably — and it is absent entirely** from the Bash tool environment, where `notify-mute` runs. Both scripts now resolve the project through one shared `lib/project.sh`, preferring the git root, so they cannot disagree about which mute file to read |

### 8b. Four things this design did not anticipate

Each cost a round trip on the first real install, and each is now covered by a
test or by the install guide.

1. **A package is not the same as a UI export.** Home Assistant merges packages
   with `_recursive_merge`, which skips empty dict values outright. The
   `selector: {text: {}}` that the UI exports — and that appendix B contains —
   arrives as `selector: {}` and is rejected with "Only one type can be
   specified". The same YAML in `scripts.yaml` is fine. `tests/check-ha-package.py`
   now fails on any empty mapping.
2. **The notify entity is not the notify action.** The companion app registers
   both `notify.<device>` (an entity) and `notify.mobile_app_<device>` (an
   action) and only the action takes a `data:` block — which is where the
   buttons, the `tag` and the interruption level live. `notify.send_message`
   has no `data` field at all, so the legacy action is not an old spelling to
   be modernised. Using the entity id gives "Action notify.<name> not found".
3. **The webhook URL needs the port.** Home Assistant listens on 8123, and a
   URL without it connects to nothing unless a reverse proxy is in front.
4. **An unconfigured plugin looks exactly like a working one.** `/plugin` does
   not exist in every environment (the VS Code extension and SDK sessions do
   not have it), nothing prompts for optional options, and a missing
   `webhook_url` makes the hook log to stderr and exit 0 — which is correct,
   since a notifier must never block Claude Code, but leaves no visible
   difference between "silent because nothing to say" and "silent because
   unconfigured". `claude plugin install <name>` re-run on an installed plugin
   reports how many options are unset; that is the check, and the README
   documents it. A SessionStart warning would be the real fix.

## 9. Migrating master-table-analysis

After the plugin is installed and working there:

1. Remove the four `claude-notify.sh` hook entries from `.claude/settings.json`. Otherwise every event fires twice.
2. Delete `.claude/hooks/claude-notify.sh` and `.claude/hooks/claude-notify-mute`, and the `/.claude/notify-muted` line from `.gitignore` (or keep it; the plugin uses the same path).
3. In Home Assistant: delete the 3 UI automations and 2 UI scripts before restarting with the package. Otherwise two automations compete for the same webhook ID and the script IDs clash. The existing To-do lists and `input_boolean.claude_night_mode` can stay; remove the UI helper if the package defines it (an ID clash otherwise).
4. Create a new webhook ID while you're at it, since the old one has appeared in a chat transcript.

## 10. Documentation references (checked 2026-10-26, Claude Code 2.1.296)

- Plugin manifest, `userConfig`, environment variables, `bin/`, standard layout: https://code.claude.com/docs/en/plugins/manifest-reference
  - Values reach hooks as `CLAUDE_PLUGIN_OPTION_<KEY>` (uppercased), including sensitive ones.
  - `${user_config.KEY}` is rejected in shell-form hook commands; read the environment variable instead.
  - `CLAUDE_PLUGIN_*` variables are not present in commands Claude runs through the Bash tool.
  - Plugin names starting with `claude-` are a validation error.
- `pluginConfigs`: https://code.claude.com/docs/en/settings-reference
  - Sensitive values: macOS Keychain; on Linux, `~/.claude/.credentials.json` (mode 0600).
  - Project and local `pluginConfigs` entries are ignored (user level only).
- Changing values later: `/plugin` → plugin → "Configure options"; non-sensitive options also appear in `/config`.

---

# Appendix A: current Claude Code scripts (from master-table-analysis)

The webhook URL default has been replaced with a placeholder.

## A.1 `.claude/hooks/claude-notify.sh`

```bash
#!/usr/bin/env bash
#
# claude-notify.sh
#
# Sends Claude Code hook events to the Home Assistant automation
# "Claude Code → phone" (automation.claude_code_phone).
#
# Use this script for these hook events:
#   - Stop          Claude finished its turn.
#   - Notification  Claude needs permission, or waits for your input.
#   - PreToolUse        Only for the AskUserQuestion tool. Claude asks you a question.
#   - UserPromptSubmit  You answered at your desk. Home Assistant removes the
#                       notification and stops the reminders for this project.
#
# The script reads the hook input (JSON) from stdin.
# It sends this payload to the webhook:
#   {"event": "<stop|permission|idle|clear>", "project": "<name>", "message": "<text>"}
#
# The script always exits with code 0. Thus, it does not block Claude Code.
#
# Mute: if the file .claude/notify-muted is newer than MUTE_MINUTES, the script
# sends only "clear" events. Use claude-notify-mute (next to this script) to
# set or remove the mute.
#
# Requirements: bash, curl, jq.
# Test without a send: CLAUDE_NOTIFY_DRY_RUN=1 (the script prints the payload).

# ---- Configuration ----------------------------------------------------------

# The Home Assistant webhook URL. The CLAUDE_NOTIFY_URL environment variable
# overrides this value.
HA_WEBHOOK_URL="${CLAUDE_NOTIFY_URL:-https://homeassistant.local:8123/api/webhook/REPLACE_WITH_WEBHOOK_ID}"

# The maximum length of the message text. The automation also cuts at 240.
MAX_MESSAGE_LENGTH=240

# The maximum time (in seconds) for the HTTP request.
CURL_TIMEOUT=5

# The mute file, and how long (in minutes) a mute stays active.
MUTE_FILE="$(dirname "$0")/../notify-muted"
MUTE_MINUTES=120

# -----------------------------------------------------------------------------

set -u

log() { echo "claude-notify: $*" >&2; }

command -v jq   >/dev/null 2>&1 || { log "jq is not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { log "curl is not installed"; exit 0; }
[ -n "$HA_WEBHOOK_URL" ]        || { log "HA_WEBHOOK_URL is empty"; exit 0; }

input="$(cat)"
[ -n "$input" ] || exit 0

# Read one field from the hook input. Gives an empty string if it is missing.
field() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }

hook_event="$(field '.hook_event_name')"
cwd="$(field '.cwd')"

# Project name: the name of the git repository root. If there is no
# repository, use the name of the project directory.
project_dir="${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}"
if top="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  project="$(basename "$top")"
else
  project="$(basename "$project_dir")"
fi

kind=""
message=""

case "$hook_event" in
  Stop)
    # If a Stop hook made Claude continue, this is not the end of the turn.
    [ "$(field '.stop_hook_active')" = "true" ] && exit 0
    kind="stop"

    # Use the last text that Claude wrote. Newer Claude Code versions put it
    # in the hook input. Older versions do not, so read the transcript.
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
    # The automation has no "question" kind. "idle" makes the notice urgent.
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

# If the mute is active, send nothing. A "clear" is always sent.
if [ "$kind" != "clear" ] && [ -n "$(find "$MUTE_FILE" -mmin "-$MUTE_MINUTES" 2>/dev/null)" ]; then
  exit 0
fi

# Make the payload. Change all whitespace to single spaces, and cut long text.
# If the message is empty, do not send it. Then the automation uses its default.
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

curl -fsSk --max-time "$CURL_TIMEOUT" \
  -X POST \
  -H 'Content-Type: application/json' \
  -d "$payload" \
  "$HA_WEBHOOK_URL" >/dev/null 2>&1 \
  || log "could not send the notification to $HA_WEBHOOK_URL"

exit 0```

## A.2 `.claude/hooks/claude-notify-mute`

```bash
#!/usr/bin/env bash
#
# claude-notify-mute
#
# Turns the phone notifications of claude-notify.sh off and on.
#
# Usage:
#   claude-notify-mute on      Mute for MUTE_MINUTES. Run it again to restart the time.
#   claude-notify-mute off     Remove the mute.
#   claude-notify-mute status  Show the current state (also the default).
#
# The mute is the file .claude/notify-muted. claude-notify.sh ignores the file
# when it is older than MUTE_MINUTES. Keep MUTE_MINUTES the same in both scripts.

MUTE_FILE="$(dirname "$0")/../notify-muted"
MUTE_MINUTES=120

set -u

status() {
  if [ -n "$(find "$MUTE_FILE" -mmin "-$MUTE_MINUTES" 2>/dev/null)" ]; then
    until="$(date -d "@$(( $(stat -c %Y "$MUTE_FILE") + MUTE_MINUTES * 60 ))" +%H:%M)"
    echo "muted until $until"
  else
    echo "notifications on"
  fi
}

case "${1:-status}" in
  on)     touch "$MUTE_FILE" && status ;;
  off)    rm -f "$MUTE_FILE" && status ;;
  status) status ;;
  *)      echo "usage: $(basename "$0") [on|off|status]" >&2; exit 2 ;;
esac
```

# Appendix B: current Home Assistant YAML (UI-created, personal details removed)

These are the five items as they exist in Home Assistant today. They are the source for the package (section 5.1), not the package itself.

## B.1 Automation: webhook

```yaml
alias: Claude Code → phone
description: >-
  Receives Claude Code hook events over a local-only webhook. 'clear' (you
  answered at your desk) removes the project's notification and held event.
  Muted projects (todo.claude_muted) are skipped. In night mode the newest event
  per project is held in todo.claude_pending for the morning. Otherwise
  script.claude_code_notify sends it with buttons and reminders.
triggers:
  - allowed_methods:
      - POST
    local_only: true
    trigger: webhook
    webhook_id: REPLACE_WITH_WEBHOOK_ID
conditions:
  - condition: template
    value_template: '{{ trigger.json is defined }}'
actions:
  - if:
      - condition: template
        value_template: '{{ kind == ''clear'' }}'
    then:
      - event: claude_code_update
        event_data:
          project: '{{ project }}'
        note: Stops reminders for this project.
      - action: notify.mobile_app_YOUR_PHONE
        data:
          data:
            tag: claude-code-{{ project | slugify }}
          message: clear_notification
      - action: script.claude_code_hold
        data:
          kind: clear
          project: '{{ project }}'
        note: Removes a held night event for this project.
      - stop: Cleared
  - action: todo.get_items
    data:
      status: needs_action
    response_variable: muted
    target:
      entity_id: todo.claude_muted
  - variables:
      mute_until: >-
        {{ (muted['todo.claude_muted']['items'] | selectattr('summary', 'eq',
        project) | map(attribute='description') | map('float', 0) | list + [0])
        | max }}
  - if:
      - condition: template
        value_template: '{{ mute_until | float(0) > now().timestamp() }}'
    then:
      - stop: Project is muted
  - if:
      - condition: state
        entity_id: input_boolean.claude_night_mode
        state: 'on'
    then:
      - event: claude_code_update
        event_data:
          project: '{{ project }}'
      - action: script.claude_code_hold
        data:
          body: '{{ body }}'
          kind: '{{ kind }}'
          project: '{{ project }}'
          ts: '{{ ts }}'
      - stop: Held for the morning
  - action: script.turn_on
    data:
      variables:
        body: '{{ body }}'
        kind: '{{ kind }}'
        project: '{{ project }}'
        ts: '{{ ts }}'
    target:
      entity_id: script.claude_code_notify
max: 25
mode: parallel
variables:
  body: '{{ trigger.json.message | default(''Finished its turn'') | truncate(240) }}'
  kind: '{{ trigger.json.event | default(''stop'') }}'
  project: '{{ trigger.json.project | default(''Claude Code'') }}'
  ts: '{{ now().timestamp() }}'
```

## B.2 Automation: night-mode schedule

```yaml
alias: Claude Code → night mode schedule
description: >-
  Turns Claude night mode on at 22:00 and off at 06:30 every day. Replace or
  extend this if another signal should control night mode.
triggers:
  - at: '22:00:00'
    id: night_on
    trigger: time
  - at: '06:30:00'
    id: night_off
    trigger: time
conditions: []
actions:
  - choose:
      - conditions:
          - condition: trigger
            id: night_on
        sequence:
          - action: input_boolean.turn_on
            target:
              entity_id: input_boolean.claude_night_mode
      - conditions:
          - condition: trigger
            id: night_off
        sequence:
          - action: input_boolean.turn_off
            target:
              entity_id: input_boolean.claude_night_mode
mode: single
```

## B.3 Automation: morning release

```yaml
alias: Claude Code → morning release
description: >-
  When Claude night mode turns off, sends the held Claude Code events
  (todo.claude_pending) in the order they came, each with the normal buttons and
  reminders, then empties the list.
triggers:
  - entity_id: input_boolean.claude_night_mode
    from: 'on'
    to: 'off'
    trigger: state
conditions: []
actions:
  - action: todo.get_items
    data:
      status: needs_action
    response_variable: pending
    target:
      entity_id: todo.claude_pending
  - variables:
      held: >-
        {% set ns = namespace(l=[]) %}{% for i in
        pending['todo.claude_pending']['items'] %}{% set d = (i.description or
        '{}') | from_json %}{% set ns.l = ns.l + [{'uid': i.uid, 'project':
        i.summary, 'kind': d.kind | default('stop'), 'body': d.body |
        default(''), 'ts': d.ts | default(0) | float}] %}{% endfor %}{{ ns.l |
        sort(attribute='ts') }}
  - repeat:
      for_each: '{{ held }}'
      sequence:
        - action: todo.remove_item
          data:
            item: '{{ repeat.item.uid }}'
          target:
            entity_id: todo.claude_pending
        - action: script.turn_on
          data:
            variables:
              body: '{{ repeat.item.body }}'
              kind: '{{ repeat.item.kind }}'
              project: '{{ repeat.item.project }}'
              ts: '{{ repeat.item.ts }}'
          target:
            entity_id: script.claude_code_notify
        - delay: '00:00:02'
          note: Keeps the arrival order on the phone.
mode: single
```

## B.4 Script: notify phone (`script.claude_code_notify`)

```yaml
alias: 'Claude Code: notify phone'
description: >-
  Sends one Claude Code event to the phone with Dismiss / Remind me in 5m /
  Ignore 1h buttons, then reminds every 10 minutes (max 3). Stops on a button, a
  newer event or clear for the same project (claude_code_update event), or when
  night mode turns on (the event is then held for the morning).
fields:
  body:
    name: Message
    selector:
      text: {}
  kind:
    name: Kind
    required: true
    selector:
      select:
        options:
          - stop
          - permission
          - idle
  project:
    name: Project
    required: true
    selector:
      text: {}
  ts:
    name: Event time (Unix seconds)
    selector:
      number:
        max: 9999999999
        min: 0
        mode: box
icon: mdi:cellphone-message
max: 25
mode: parallel
sequence:
  - variables:
      run_id: >-
        {{ project | slugify }}_{{ (now().timestamp() * 1000) | int }}_{{
        range(99999) | random }}
    note: >-
      Unique for each run. Runs started by one caller share context.id, so it
      cannot be used.
  - variables:
      done: false
      ev_ts: '{{ ts | default(now().timestamp(), true) | float }}'
      id_dismiss: CC_DISMISS_{{ run_id }}
      id_ignore: CC_IGNORE_{{ run_id }}
      id_snooze: CC_SNOOZE_{{ run_id }}
      resend: false
      sends_left: 3
      slug: '{{ project | slugify }}'
      subtitle: >-
        {{ {'permission': '⚠️ Needs permission', 'idle': '❓ Waiting for
        you'}.get(kind, '✅ Finished') }}
      tag: claude-code-{{ project | slugify }}
  - event: claude_code_update
    event_data:
      project: '{{ project }}'
    note: Tells older runs for this project to stop their reminders.
  - repeat:
      sequence:
        - action: notify.mobile_app_YOUR_PHONE
          data:
            data:
              actions:
                - action: '{{ id_dismiss }}'
                  title: Dismiss
                - action: '{{ id_snooze }}'
                  title: Remind me in 5m
                - action: '{{ id_ignore }}'
                  destructive: true
                  title: Ignore 1h
              group: '{{ tag }}'
              push:
                interruption-level: time-sensitive
              subtitle: '{{ subtitle }}{{ '' · reminder'' if resend else '''' }}'
              tag: '{{ tag }}'
            message: '{{ body if body else ''Finished its turn'' }}'
            title: '{{ project }}'
        - continue_on_timeout: true
          timeout: '00:10:00'
          wait_for_trigger:
            - event_data:
                action: '{{ id_dismiss }}'
              event_type: mobile_app_notification_action
              id: dismiss
              trigger: event
            - event_data:
                action: '{{ id_snooze }}'
              event_type: mobile_app_notification_action
              id: snooze
              trigger: event
            - event_data:
                action: '{{ id_ignore }}'
              event_type: mobile_app_notification_action
              id: ignore
              trigger: event
            - event_data:
                project: '{{ project }}'
              event_type: claude_code_update
              id: superseded
              trigger: event
            - entity_id: input_boolean.claude_night_mode
              id: night
              to: 'on'
              trigger: state
        - variables:
            resend: true
            result: '{{ wait.trigger.id if wait.trigger else ''timeout'' }}'
        - choose:
            - conditions:
                - condition: template
                  value_template: '{{ result == ''dismiss'' }}'
              sequence:
                - action: notify.mobile_app_YOUR_PHONE
                  data:
                    data:
                      tag: '{{ tag }}'
                    message: clear_notification
                - variables:
                    done: true
            - conditions:
                - condition: template
                  value_template: '{{ result == ''ignore'' }}'
              sequence:
                - action: notify.mobile_app_YOUR_PHONE
                  data:
                    data:
                      tag: '{{ tag }}'
                    message: clear_notification
                - action: todo.get_items
                  data:
                    status: needs_action
                  response_variable: muted
                  target:
                    entity_id: todo.claude_muted
                - repeat:
                    for_each: >-
                      {{ muted['todo.claude_muted']['items'] |
                      selectattr('summary', 'eq', project) |
                      map(attribute='uid') | list }}
                    sequence:
                      - action: todo.remove_item
                        data:
                          item: '{{ repeat.item }}'
                        target:
                          entity_id: todo.claude_muted
                - action: todo.add_item
                  data:
                    description: '{{ (now() + timedelta(hours=1)).timestamp() | int }}'
                    item: '{{ project }}'
                  note: Description holds the mute end time (Unix seconds).
                  target:
                    entity_id: todo.claude_muted
                - variables:
                    done: true
            - conditions:
                - condition: template
                  value_template: '{{ result == ''superseded'' }}'
              sequence:
                - variables:
                    done: true
            - conditions:
                - condition: template
                  value_template: '{{ result == ''night'' }}'
              sequence:
                - action: script.claude_code_hold
                  data:
                    body: '{{ body }}'
                    kind: '{{ kind }}'
                    project: '{{ project }}'
                    ts: '{{ ev_ts }}'
                - variables:
                    done: true
            - conditions:
                - condition: template
                  value_template: '{{ result == ''snooze'' }}'
              sequence:
                - action: notify.mobile_app_YOUR_PHONE
                  data:
                    data:
                      tag: '{{ tag }}'
                    message: clear_notification
                - continue_on_timeout: true
                  timeout: '00:05:00'
                  wait_for_trigger:
                    - event_data:
                        project: '{{ project }}'
                      event_type: claude_code_update
                      id: superseded
                      trigger: event
                    - entity_id: input_boolean.claude_night_mode
                      id: night
                      to: 'on'
                      trigger: state
                - choose:
                    - conditions:
                        - condition: template
                          value_template: >-
                            {{ wait.trigger is not none and wait.trigger.id ==
                            'night' }}
                      sequence:
                        - action: script.claude_code_hold
                          data:
                            body: '{{ body }}'
                            kind: '{{ kind }}'
                            project: '{{ project }}'
                            ts: '{{ ev_ts }}'
                        - variables:
                            done: true
                    - conditions:
                        - condition: template
                          value_template: '{{ wait.trigger is not none }}'
                      sequence:
                        - variables:
                            done: true
                  default:
                    - variables:
                        sends_left: 3
                  note: >-
                    After the snooze, the loop sends again and the 10-minute
                    reminders restart (max 3).
          default:
            - else:
                - variables:
                    sends_left: '{{ sends_left | int - 1 }}'
              if:
                - condition: template
                  value_template: '{{ sends_left | int <= 0 }}'
              then:
                - variables:
                    done: true
      until:
        - condition: template
          value_template: '{{ done }}'
```

## B.5 Script: hold event (`script.claude_code_hold`)

```yaml
alias: 'Claude Code: hold event'
description: >-
  Keeps the newest held Claude Code event for each project in
  todo.claude_pending (night mode). With kind 'clear', it only removes the
  project's held event.
fields:
  body:
    name: Message
    selector:
      text: {}
  kind:
    name: Kind
    required: true
    selector:
      text: {}
  project:
    name: Project
    required: true
    selector:
      text: {}
  ts:
    name: Event time (Unix seconds)
    selector:
      number:
        max: 9999999999
        min: 0
        mode: box
icon: mdi:inbox-arrow-down
max: 20
mode: queued
sequence:
  - action: todo.get_items
    data:
      status: needs_action
    response_variable: pending
    target:
      entity_id: todo.claude_pending
  - note: Only the newest event for a project matters, so remove older held events.
    repeat:
      for_each: >-
        {{ pending['todo.claude_pending']['items'] | selectattr('summary', 'eq',
        project) | map(attribute='uid') | list }}
      sequence:
        - action: todo.remove_item
          data:
            item: '{{ repeat.item }}'
          target:
            entity_id: todo.claude_pending
  - if:
      - condition: template
        value_template: '{{ kind != ''clear'' }}'
    then:
      - action: todo.add_item
        data:
          description: >-
            {{ {'kind': kind, 'body': body | default(''), 'ts': ts |
            default(now().timestamp(), true) | float} | to_json }}
          item: '{{ project }}'
        target:
          entity_id: todo.claude_pending
```
