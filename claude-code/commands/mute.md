---
description: Mute or unmute the Home Assistant phone notifications for this project
argument-hint: "[on [minutes]|off|status]"
allowed-tools: Bash(notify-mute:*)
---

Run the mute toggle with the user's argument and report the result.

```
notify-mute $ARGUMENTS
```

`notify-mute` is on your PATH, from this plugin's `bin/` directory. If the shell
cannot find it, run `bash "${CLAUDE_PLUGIN_ROOT}/bin/notify-mute" $ARGUMENTS`
instead.

With no argument it reports the current state. `on` mutes for 120 minutes;
`on 30` mutes for 30 minutes; `off` removes the mute.

Report the script's output in one short line and nothing else — no preamble, no
explanation of what muting does. If the script exits non-zero, say what it
printed.

Note for the user if they ask: this mute stops events at the desk, before they
are sent. It is separate from the **Ignore 1h** button on the phone, which makes
Home Assistant drop events it receives.
