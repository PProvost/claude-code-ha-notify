# Codex

Home Assistant notifications from [OpenAI Codex](https://developers.openai.com/codex/),
using Codex's own hooks engine.

> **Status: untested.** The Home Assistant side and the Claude Code side are both
> working in practice. This half has been built against the
> [published hooks reference](https://learn.chatgpt.com/docs/hooks.md) and is
> covered by the test suite, but nobody has yet run it against a real Codex
> install. Expect to find something. [Known unknowns](#known-unknowns) lists what
> to check first, and a PR fixing any of it is very welcome.

This is a **manual install**, not a plugin. Codex does have a plugin model
(`.codex-plugin/plugin.json`, marketplaces) and packaging this as one is a
reasonable follow-on — see [Why not a plugin yet](#why-not-a-plugin-yet).

## What works, and what does not

The two agents are close enough that `notify.sh` is shared between them
unmodified. Codex sends the same kind of JSON on stdin, and its `Stop` payload
even uses the same `stop_hook_active` and `last_assistant_message` field names.

| Event | Claude Code | Codex | |
|---|---|---|---|
| `stop` | `Stop` | `Stop` | Same payload fields |
| `clear` | `UserPromptSubmit` | `UserPromptSubmit` | Same |
| `permission` | `Notification` | `PermissionRequest` | Different event, same intent |
| `idle` | `Notification`, `AskUserQuestion` | — | **Not available** |

**You lose the `idle` event.** Codex has no `Notification` event and no
`AskUserQuestion` tool, so there is nothing to map it to. In practice this
matters less than it sounds: Codex's `Stop` fires when the turn ends *and the
agent is waiting for you*, which is most of what `idle` was telling you.

## Requirements

- Codex CLI with hooks available. Check with `/hooks` — if that command is
  missing or reports that only managed hooks run, stop here and read
  [If your workspace is managed](#if-your-workspace-is-managed).
- `bash`, `curl` and `jq` on PATH.
- A working Home Assistant side: [home-assistant/README.md](../home-assistant/README.md).

## Install

### 1. Copy the scripts

From a clone of this repository:

```bash
mkdir -p ~/.codex/ha-notify/{hooks,lib,bin}
cp claude-code/scripts/notify.sh  ~/.codex/ha-notify/hooks/
cp claude-code/lib/project.sh     ~/.codex/ha-notify/lib/
cp claude-code/bin/notify-mute    ~/.codex/ha-notify/bin/
chmod +x ~/.codex/ha-notify/hooks/notify.sh ~/.codex/ha-notify/bin/notify-mute
```

They live under `claude-code/` because that is where the plugin needs them;
the three files themselves are harness-neutral. `notify.sh` and `notify-mute`
both look for `lib/project.sh` one directory up from their own, so keep the
layout above.

### 2. Store the webhook URL

```bash
printf 'http://your-ha:8123/api/webhook/your-webhook-id' > ~/.codex/ha-notify/webhook-url
chmod 600 ~/.codex/ha-notify/webhook-url
```

Keep the port. The webhook ID is effectively a password, which is why it lives
in its own `600` file rather than in `hooks.json` — that way `hooks.json` stays
shareable and the secret does not.

If you would rather use the environment, `export HA_NOTIFY_URL=...` from your
shell profile works too, and the hook prefers `CLAUDE_NOTIFY_URL` over both.

### 3. Install the hooks

```bash
cp codex/hooks.json ~/.codex/hooks.json
```

If you already have a `~/.codex/hooks.json`, merge the three entries into it
rather than overwriting. If you keep hooks inline in `config.toml` instead,
convert them — Codex merges both and warns at startup, so pick one.

### 4. Trust the hooks

Codex will not run a hook it has not been shown. Start Codex, run `/hooks`,
review the three entries and trust them.

**Trust is recorded against the hook's hash, so you must do this again after
every change** — including when you update these scripts.

### 5. Test

```bash
printf '{"hook_event_name":"Stop","cwd":"%s","last_assistant_message":"Test"}' "$PWD" \
  | CLAUDE_NOTIFY_DRY_RUN=1 bash ~/.codex/ha-notify/hooks/notify.sh
```

That prints the payload without sending. Drop `CLAUDE_NOTIFY_DRY_RUN=1` and add
`HA_NOTIFY_URL="$(cat ~/.codex/ha-notify/webhook-url)"` to send it for real.

**Never set `CLAUDE_NOTIFY_DRY_RUN` in `hooks.json`.** Codex feeds a hook's
stdout back into the model as context on `UserPromptSubmit`, so a dry run wired
into the hook would inject JSON into your conversation.

## Known unknowns

Check these first; they are where this is most likely to be wrong.

1. **Does `Stop` need JSON on stdout?** The reference says "Exit 0 with no
   output means success" and also that "`SubagentStop`, `Stop`, and `Interrupt`
   require JSON on stdout when exiting 0". Those cannot both be true for our
   case, and `notify.sh` exits 0 silently. If every turn reports a hook failure,
   either fix works — in the `Stop` entry only:

   ```jsonc
   // append an empty directive object
   "command": "... bash \"$HOME/.codex/ha-notify/hooks/notify.sh\" && echo '{}'"

   // or make it fire-and-forget, which cannot return a decision at all
   "async": true
   ```

   Do **not** apply the `echo` to `UserPromptSubmit` — stdout there becomes
   model context.

2. **Do hooks inherit your shell environment?** The install above does not
   depend on it, reading the URL from a file instead. If you use the
   `export HA_NOTIFY_URL` route and nothing arrives, this is why.

3. **Is `PermissionRequest` too chatty?** It fires whenever Codex is about to
   ask for approval. If that is noisier than useful, delete that one entry;
   `stop` and `clear` are independent.

## If nothing arrives

1. `/hooks` — are all three trusted and enabled? An untrusted hook is skipped
   silently.
2. Run the step 5 command by hand. If that prints a payload, the script is fine
   and the problem is the wiring.
3. Check the Home Assistant automation trace. A trace means the event arrived
   and the problem is downstream — see
   [home-assistant/README.md](../home-assistant/README.md#if-nothing-arrives).
4. No trace, and the hook runs? The URL is wrong or unreachable. Remember the
   webhook is `local_only` by default.

## Muting

There is no `/ha-notify:mute` here — Codex plugins ship skills, not slash
commands, and there is no equivalent of Claude Code's `bin/` on PATH. Run the
script directly:

```bash
~/.codex/ha-notify/bin/notify-mute on 30   # quiet for 30 minutes
~/.codex/ha-notify/bin/notify-mute off
~/.codex/ha-notify/bin/notify-mute         # status
```

A shell alias makes that bearable:

```bash
alias notify-mute='~/.codex/ha-notify/bin/notify-mute'
```

The mute file is per project, at `<repo>/.claude/notify-muted` — the same path
Claude Code uses, so a project muted in one is muted in the other. Add
`/.claude/notify-muted` to the project's `.gitignore`.

## If your workspace is managed

Codex admins can set `allow_managed_hooks_only = true`, which ignores user,
project, session and plugin hooks entirely. If that is set, none of this will
run and there is no user-level workaround — the hooks would have to be deployed
as managed hooks by whoever administers your workspace.

## Why not a plugin yet

Codex plugins would give you install and update in one command. Two things
argue for waiting:

- **Nowhere to put the webhook URL.** Codex plugins have no equivalent of
  Claude Code's `userConfig`, and so no sensitive-value storage. The URL would
  end up in an environment variable or a file either way — exactly what the
  manual install already does, with none of the packaging.
- **A manual install works under more restrictions.** If plugins or
  marketplaces are limited in your workspace, a `hooks.json` and three scripts
  still work.

The shape is known if it becomes worth doing: a `.codex-plugin/plugin.json`
alongside the existing `.claude-plugin/plugin.json`, sharing one body of
content. That is how [superpowers](https://github.com/obra/superpowers) carries
Claude Code, Codex, Cursor and several others in one repository.

## Changing things

`notify.sh`, `project.sh` and `notify-mute` are shared with the Claude Code
side, so a change here affects both. The suite covers Codex payloads
explicitly:

```bash
tests/run-tests.sh codex
```

Please add a case there for anything you fix.
