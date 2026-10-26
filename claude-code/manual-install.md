# Manual install (fallback)

Use this if you cannot install plugins. The plugin route in the main
[README](../README.md) is easier and updates itself; this does the same thing by
hand.

## 1. Copy the scripts

From a clone of this repository, into the project where Claude Code runs:

```bash
mkdir -p .claude/hooks .claude/lib .claude/bin
cp claude-code/scripts/notify.sh  .claude/hooks/
cp claude-code/lib/project.sh     .claude/lib/
cp claude-code/bin/notify-mute    .claude/bin/
chmod +x .claude/hooks/notify.sh .claude/bin/notify-mute
```

`notify.sh` and `notify-mute` both expect `lib/project.sh` one directory up from
their own, which the layout above preserves. Keep it.

## 2. Add the hooks and the URL

In `.claude/settings.json` (create it if it does not exist). Replace the URL with
your own webhook — the ID in it is effectively a password, so if you commit this
file, use the environment instead and keep the URL out of git.

```json
{
  "env": {
    "CLAUDE_NOTIFY_URL": "https://homeassistant.local:8123/api/webhook/your-webhook-id"
  },
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/notify.sh\"", "timeout": 10 } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/notify.sh\"", "timeout": 10 } ] }
    ],
    "PreToolUse": [
      { "matcher": "AskUserQuestion",
        "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/notify.sh\"", "timeout": 10 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/notify.sh\"", "timeout": 10 } ] }
    ]
  }
}
```

For an internal CA, add to the same `env` block:

```json
"CLAUDE_NOTIFY_CACERT": "/etc/ssl/certs/my-internal-ca.pem"
```

Only if you cannot fix the certificate properly, `"CLAUDE_NOTIFY_INSECURE": "1"`
turns certificate checking off.

## 3. Ignore the mute file

```bash
echo '/.claude/notify-muted' >> .gitignore
```

## 4. Check it

```bash
echo '{"hook_event_name":"Stop","cwd":"'"$PWD"'","last_assistant_message":"Test"}' \
  | CLAUDE_NOTIFY_DRY_RUN=1 CLAUDE_PROJECT_DIR="$PWD" bash .claude/hooks/notify.sh
```

That prints the payload without sending. Drop `CLAUDE_NOTIFY_DRY_RUN=1` to send
it for real; your phone should notify.

## Differences from the plugin

- No `/ha-notify:mute` command. Run `.claude/bin/notify-mute` directly, or add
  `.claude/bin` to your PATH to use `! notify-mute on` from the prompt.
- Updates are a manual re-copy.
- The URL lives in `.claude/settings.json` rather than Claude Code's credential
  store, so take care not to commit it.
