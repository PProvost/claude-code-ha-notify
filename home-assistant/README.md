# Home Assistant side

One YAML package holding three automations, two scripts and three helpers, plus
two Local To-do lists you create in the UI.

**Minimum version: Home Assistant 2024.10.** The package uses the plural
`triggers:` / `conditions:` / `actions:` automation keys and `action:` for
service calls, which arrived in 2024.8–2024.10.

## Before you start

- The [companion app](https://companion.home-assistant.io/) set up on your phone
  and notifying successfully. Test it under **Developer tools → Actions** with
  your `notify.mobile_app_*` action before going further — if that does not
  reach your phone, nothing here will.
- A way to edit `/config`: the **File editor** or **Studio Code Server** add-on,
  or direct file access.

## 1. Create the two To-do lists

**Settings → Devices & services → Add integration → Local To-do**, twice:

| Name it | Must end up as |
|---|---|
| `Claude muted` | `todo.claude_muted` |
| `Claude pending` | `todo.claude_pending` |

Check the entity IDs afterwards under **Settings → Devices & services →
Entities**. The package refers to them by exactly these IDs, so if Home
Assistant assigned something else, rename the entity.

These cannot be created from YAML — Local To-do is UI-only — which is why they
are a manual step.

## 2. Turn on packages

In `/config/configuration.yaml`. If you already have a `homeassistant:` block,
add the one line to it rather than making a second block:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## 3. Copy the package

Copy `packages/claude_code_notify.yaml` to `/config/packages/`, so you end up
with `/config/packages/claude_code_notify.yaml`.

A subfolder works too — `!include_dir_named` searches subdirectories, and keys
each package by the filename alone, so
`/config/packages/claude-code-ha-notify/claude_code_notify.yaml` loads as the
same package. It buys you nothing here, though: because the key is the filename
with the path thrown away, two files of the same name in different subfolders
would collide rather than being kept apart.

**Copy the one file, not this repository.** The search is recursive, so a clone
under `/config/packages/` would also pick up `secrets.example.yaml` and try to
load it as a package, and Check configuration would fail on it.

## 4. Add the two secrets

Add the contents of [secrets.example.yaml](secrets.example.yaml) to
`/config/secrets.yaml`, with your own values:

```yaml
claude_code_webhook_id: "a-long-random-string"
claude_code_notify_service: notify.mobile_app_your_phone
```

The webhook ID is the **only** thing protecting the webhook — Home Assistant
webhooks have no login — so make it long and random, and treat the resulting URL
as a password. Generate one with:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

## 5. Check the configuration and restart

**Developer tools → YAML → Check configuration**, then restart Home Assistant.

Later updates to this file only need **Reload automations** and **Reload
scripts**, not a restart.

## 6. Set the night times

A fresh install leaves both night-time helpers at 00:00, and while they are
equal the night schedule does nothing — so night mode is simply off until you
set them. Set them to whatever suits you (22:00 and 06:30 are reasonable):

- `input_datetime.claude_night_start`
- `input_datetime.claude_night_end`

These deliberately have no `initial:` value, so Home Assistant remembers what
you set across restarts. The cost of that choice is this manual first-time step.

If you would rather drive night mode from something else — a person entity, an
alarm panel, a bedtime scene — delete the `claude_code_night_mode` automation
and switch `input_boolean.claude_night_mode` however you like. Nothing else
depends on how it gets switched.

## 7. Connect Claude Code

Your webhook URL is:

```
https://<your-home-assistant>/api/webhook/<claude_code_webhook_id>
```

Set up [the Claude Code side](../README.md#part-2--claude-code) with that URL,
then send a test event:

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"event":"stop","project":"test","message":"Hello from curl"}' \
  https://<your-home-assistant>/api/webhook/<your-webhook-id>
```

Your phone should notify within a second or two, with three buttons. If it does
not, see below.

## If nothing arrives

Work down this list — it is ordered by how often each one is the cause.

1. **Check the automation trace.** Settings → Automations → *Claude Code ->
   phone* → Traces. A trace means the webhook arrived and you can see which
   `stop:` it hit — `Project is muted`, `Held for the morning`, or none.
2. **No trace at all?** The request never reached the automation. The webhook is
   `local_only: true`, so it only accepts requests from your own network. Check
   the webhook ID matches your secret, and that you used `POST`.
3. **A trace that reaches the end, but no notification?** The
   `claude_code_notify_service` secret is probably wrong. Call it by hand under
   Developer tools → Actions.
4. **Nothing at night.** Expected: events are held in `todo.claude_pending` and
   released when night mode turns off. Check
   `input_boolean.claude_night_mode`.
5. **One project is silent.** It is probably muted from the phone. Look in
   `todo.claude_muted` — each item is a project name whose description is the
   Unix time the mute ends. Delete the item to unmute immediately.

## Things worth knowing

- **Automations defined in YAML are read-only in the UI.** You can see them and
  their traces, but you must edit the file to change them. That is the trade for
  keeping the five pieces wired together in one updatable file.
- **`local_only: true`** means remote or cloud dev environments cannot reach the
  webhook. Remove it only if you understand that the webhook ID is then the only
  thing standing between the internet and your notifications.
- **Tested on iOS.** The `priority`, `ttl` and `channel` keys for Android are
  included but untested; iOS ignores them.
- **Desk mute and phone mute are separate.** The **Ignore** button writes to
  `todo.claude_muted` and makes Home Assistant drop events it receives. The desk
  mute (`/ha-notify:mute`) stops them being sent at all, and keeps working when
  Home Assistant is unreachable.
- **`!secret` in an `action:` key.** The package reads the notify action from
  `secrets.yaml` in five places. Home Assistant resolves `!secret` while loading
  the YAML, so by the time it is validated the value is an ordinary string — but
  this has not been run against a live instance yet. If Check configuration
  complains about it, replace each `action: !secret claude_code_notify_service`
  with your literal action name, for example
  `action: notify.mobile_app_your_phone`.

## What is in the package

| Thing | ID | Does what |
|---|---|---|
| Automation | `claude_code_phone` | Receives the webhook; clears, drops, holds or sends |
| Automation | `claude_code_night_mode` | Switches night mode at the two helper times |
| Automation | `claude_code_morning_release` | Replays held events when night mode ends |
| Script | `claude_code_notify` | One event: notify, buttons, reminders |
| Script | `claude_code_hold` | Keeps the newest held event per project |
| Helper | `input_boolean.claude_night_mode` | Night mode on/off |
| Helpers | `input_datetime.claude_night_start` / `_end` | When night mode flips |
