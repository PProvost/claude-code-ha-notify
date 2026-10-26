# claude-code-ha-notify

Send Claude Code events to your phone through Home Assistant, so you know when
Claude has finished a turn, needs a permission, or is waiting for you — while
you are away from the desk.

> **Status:** design agreed, implementation in progress. The full design lives in
> [docs/design-spec.md](docs/design-spec.md). The install steps below are marked
> _(not yet available)_ until the matching folder lands.

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

_(not yet available)_ — will be `home-assistant/`: one YAML package holding the
automations, scripts, and helpers, plus two Local To-do lists you create in the
UI. See section 5 of the [design spec](docs/design-spec.md) for what it contains.

### Part 2 — Claude Code

_(not yet available)_ — will be `claude-code/`, installable as a plugin with
`/plugin install`, or copied in by hand. It asks for your webhook URL at install
time. See section 4 of the [design spec](docs/design-spec.md).

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

## License

MIT — see [LICENSE](LICENSE).
