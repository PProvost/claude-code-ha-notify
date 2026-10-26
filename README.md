# claude-code-ha-notify

Send Claude Code events to your phone through Home Assistant, so you know when
Claude has finished a turn, needs a permission, or is waiting for you — while
you are away from the desk.

> **Status:** working end to end on iOS — a finished turn in Claude Code reaches
> the phone with buttons. The reminder loop, the buttons themselves, night mode
> and the morning release have not been exercised yet. Android is untested. The
> full design lives in [docs/design-spec.md](docs/design-spec.md).

```
Claude Code hook ──HTTP POST (JSON)──▶ Home Assistant webhook ──▶ companion app ──▶ phone
 (dev environment)                      (automation + scripts)
```

## What it does

- Notifies you when Claude **finishes a turn**, **needs a permission**, or is
  **waiting for input** (including an `AskUserQuestion` question).
- Each notification carries **Dismiss**, **Remind me in 5m**, and **Ignore 1h**
  buttons, and repeats every 10 minutes (up to 3 times) until you act.
- Answering at your desk clears the notification on your phone automatically.
- **Night mode** holds events instead of waking you, then releases them in order
  the next morning.
- **Desk mute** silences notifications for one project for a couple of hours
  without touching Home Assistant.

## Requirements

- Home Assistant, reachable from the machine where Claude Code runs, with the
  [companion app](https://companion.home-assistant.io/) set up on your phone.
- `bash`, `curl`, and `jq` in the dev environment.
- Tested on iOS. The Android-specific notification keys are included but
  untested.

## Install

The two halves install in two different places and share nothing but the
[payload contract](#payload-contract). Do Home Assistant first — the Claude Code
side needs the webhook URL it gives you.

### Part 1 — Home Assistant

One YAML package, two secrets, and two Local To-do lists you create in the UI.
**Needs Home Assistant 2024.10 or newer.**

Full steps, and what to check when nothing arrives:
**[home-assistant/README.md](home-assistant/README.md)**.

### Part 2 — Claude Code

In an interactive Claude Code session:

```
/plugin install ha-notify --marketplace PProvost/claude-code-ha-notify
```

`/plugin` is not available everywhere — the VS Code extension and SDK sessions
do not have it. From a shell, which works anywhere:

```bash
claude plugin marketplace add PProvost/claude-code-ha-notify
claude plugin install ha-notify@ha-notify \
  --config webhook_url='http://<your-ha>:8123/api/webhook/<your-webhook-id>'
```

**Set `webhook_url` or nothing happens.** It is the one required option, and
without it the hook logs to stderr and exits 0 — silently, so it can never block
Claude Code. That is the right behaviour for a notifier and a confusing one to
debug, so check it is set:

```bash
claude plugin install ha-notify@ha-notify   # prints how many options are unset
```

The webhook ID in that URL is effectively a password, so it is stored as a
sensitive value — in the macOS Keychain, or in `~/.claude/.credentials.json` on
Linux — never in `settings.json`.

Two optional settings. Nothing prompts for these; name them when you want them,
and skip both unless your Home Assistant uses TLS:

| Option | When you need it | Set it with |
|---|---|---|
| `ca_cert` | Home Assistant uses a certificate from an internal CA | `--config ca_cert=/path/to/ca.pem` |
| `insecure_tls` | Last resort; sends with `curl -k` | `--config insecure_tls=true` |

To change any of them later: `/plugin configure ha-notify@ha-notify` in an
interactive session, or re-run the `claude plugin install ... --config` line.
Non-sensitive values land in `pluginConfigs` in `~/.claude/settings.json`.

Each has an environment-variable override, which is also how you point a single
project somewhere else:

| Variable | Overrides |
|---|---|
| `CLAUDE_NOTIFY_URL` | the webhook URL |
| `CLAUDE_NOTIFY_CACERT` | the CA certificate |
| `CLAUDE_NOTIFY_INSECURE=1` | turns certificate checking off |

Check it without sending anything:

```bash
echo '{"hook_event_name":"Stop","cwd":"'"$PWD"'","last_assistant_message":"Test"}' \
  | CLAUDE_NOTIFY_DRY_RUN=1 CLAUDE_PROJECT_DIR="$PWD" \
    bash ~/.claude/plugins/cache/*/ha-notify/*/scripts/notify.sh
```

Can't use plugins? See [claude-code/manual-install.md](claude-code/manual-install.md).

Add `/.claude/notify-muted` to each project's `.gitignore`.

### Muting at the desk

```
/ha-notify:mute            # show the current state
/ha-notify:mute on         # quiet for 120 minutes
/ha-notify:mute on 30      # quiet for 30 minutes
/ha-notify:mute off
```

`notify-mute` is also on the Bash tool's PATH, so `! notify-mute on` works
straight from the prompt without spending a model turn.

### In a devcontainer

Sensitive plugin values live in `~/.claude`, which a rebuild throws away. Keep it
on a volume:

```jsonc
"mounts": ["source=${devcontainerId}-claude-config,target=/home/vscode/.claude,type=volume"]
```

## Payload contract

The hook sends a `POST` to the webhook URL with `Content-Type: application/json`:

```json
{"event": "stop|permission|idle|clear", "project": "my-repo", "message": "optional text, max 240 chars"}
```

| `event` | Meaning |
|---|---|
| `stop` | Claude finished its turn. `message` is the last thing Claude wrote. |
| `permission` | A permission prompt or elicitation dialog is waiting. |
| `idle` | Claude is waiting for input, or has asked you a question. |
| `clear` | You answered at the desk. Home Assistant removes the notification, stops the reminders, and drops any held night event. |

`project` is the git repository name, or the directory name if there is no
repository. It is what groups notifications and reminders together, so the two
halves must agree on it.

`clear` is always sent, even while muted — otherwise a notification you muted
mid-turn would keep reminding you after you had already replied.

## Two kinds of mute

These are deliberately separate, and they fail differently:

| | Where | What it does | Works when Home Assistant is unreachable |
|---|---|---|---|
| **Desk mute** | The dev environment, via `notify-mute` | Stops events before they are sent | Yes |
| **Phone mute** | Home Assistant, via the **Ignore 1h** button | Home Assistant drops events it receives | No |

The desk mute can always report its own state locally, which the phone mute
cannot: the webhook is one-way, so asking Home Assistant "am I muted?" would
need a second credential.

## Caveats

- The webhook is **local-only** by default: Home Assistant will only accept
  requests from your own network, so remote or cloud dev environments cannot
  reach it.
- The webhook ID is the only thing protecting the webhook — Home Assistant
  webhooks have no login. Treat the URL as a password, and rotate the ID if it
  leaks.
- Automations defined in YAML are read-only in the Home Assistant UI. Traces
  still work.

## Development

```bash
tests/run-tests.sh              # 66 tests, no network: dry runs and a fake curl
tests/run-tests.sh mute         # just the groups whose name matches
tests/check-ha-package.py       # 32 structural checks on the YAML package
shellcheck -x claude-code/scripts/notify.sh claude-code/bin/notify-mute claude-code/lib/project.sh
yamllint -c .yamllint home-assistant/packages .github/workflows
claude plugin validate --strict ./claude-code
```

CI runs all of it, on Linux and macOS for the shell scripts.

`tests/check-ha-package.py` cross-references the package: every script called
exists, every variable passed to a script is one of its declared fields, every
required field is supplied, every entity resolves, and the `!secret` names match
`secrets.example.yaml`. It cannot tell you Home Assistant will accept the file —
only your instance can — but it catches the typos that would otherwise fail
silently at 3am.

## License

MIT — see [LICENSE](LICENSE).
