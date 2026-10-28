# Working in this repository

Read by Claude Code and Codex. Humans are welcome too.

## What this is

Two independently-installed halves that share nothing but a three-field JSON
payload:

| Folder | Installed where | How |
|---|---|---|
| `claude-code/` | The dev machine | Claude Code plugin, or a manual copy |
| `codex/` | The dev machine | Manual install only (see its README) |
| `home-assistant/` | Home Assistant | One YAML package + two UI-created To-do lists |

The design and the reasoning behind every decision are in
[docs/design-spec.md](docs/design-spec.md). Read section 8 before re-litigating
anything: it records what was already tried and what the answer turned out to
be.

## Release discipline — the thing most easily got wrong

**If you change a file that ships inside the plugin, bump `version` in
`claude-code/.claude-plugin/plugin.json`.**

Claude Code decides an update exists by comparing that field. It records a
commit sha at install time but does not use it for update detection. Ship a
change without a bump and the new code reaches nobody who already has the
plugin: no error, no warning, and the only symptom is someone else's machine
quietly staying on the old version.

Shipped = everything under `claude-code/` except `manual-install.md`.
`tests/check-version-bump.sh` enforces this and CI runs it.

Which number:

| Change | Bump |
|---|---|
| New event handled, new option, new behaviour | minor (`0.2.0` → `0.3.0`) |
| Bug fix, no interface change | patch (`0.2.0` → `0.2.1`) |
| Payload contract or option names change | major, and update section 6 of the spec |

Then tag the release so it is visible on GitHub:

```bash
claude plugin tag ./claude-code --push
```

That creates `ha-notify--v<version>`, after checking the manifest and the
marketplace entry agree. Tags are not needed to resolve the plugin — the
marketplace tracks `main` with no ref — they exist so a release is findable.

To pick an update up on another machine, the marketplace cache must be
refreshed first; it does not re-pull on its own:

```bash
claude plugin marketplace update ha-notify
claude plugin update ha-notify
```

## The scripts are shared

`claude-code/scripts/notify.sh`, `claude-code/lib/project.sh` and
`claude-code/bin/notify-mute` are used by **both** the Claude Code plugin and
the Codex install. They live under `claude-code/` because the plugin needs them
there, not because they are Claude-Code-specific. A change to any of them
affects both harnesses — run the whole suite, not just one group.

`notify.sh` branches on `hook_event_name`. Claude Code and Codex send the same
shape of JSON on stdin and agree on `Stop`, `UserPromptSubmit`,
`stop_hook_active` and `last_assistant_message`; `PermissionRequest` is Codex
only. See [codex/README.md](codex/README.md) for the full mapping.

## Testing

```bash
tests/run-tests.sh              # the hook, the mute, both harnesses
tests/run-tests.sh codex        # one group; the argument is a name filter
tests/check-ha-package.py       # structural checks on the YAML package
tests/check-version-bump.sh     # compares against origin/main by default
```

The suite never touches the network. Payload tests use
`CLAUDE_NOTIFY_DRY_RUN=1`; tests that check how `curl` is called install a fake
`curl` that records its arguments.

**Write the test first.** Several real bugs in this repository were found by a
test written before the code, and two were found by deliberately breaking a
fixture to prove the test could fail. If a test passes the moment you write it,
you have learned nothing — break the thing it guards and watch it go red.

Before claiming anything works:

```bash
tests/run-tests.sh && tests/check-ha-package.py \
  && shellcheck -x claude-code/scripts/notify.sh claude-code/bin/notify-mute \
       claude-code/lib/project.sh tests/*.sh \
  && yamllint -c .yamllint .github/workflows home-assistant/packages \
  && claude plugin validate --strict ./claude-code \
  && claude plugin validate --strict .
```

## Home Assistant specifics

The package is **not** a UI export, and the difference bites. Home Assistant
merges a package with `_recursive_merge`, which drops empty mappings — so the
`selector: {text: {}}` that the UI writes arrives as `selector: {}` and is
rejected. `tests/check-ha-package.py` fails on any empty mapping for that
reason. Read its header before editing the package.

Two more things that cost a debugging round each, recorded in spec section 8b:

- The notify **entity** (`notify.<device>`) is not the notify **action**
  (`notify.mobile_app_<device>`). Only the action takes a `data:` block, which
  is where the buttons, the `tag` and the interruption level live.
- The webhook URL needs the port. Home Assistant listens on 8123.

`home-assistant/README.md` documents the package's sha256 so people can verify
a download. If you change the package, that hash changes —
`tests/check-ha-package.py` fails until the guide is updated, because a stale
hash tells someone their correct file is corrupt.

## Conventions

- Shell is bash, `set -u`, shellcheck-clean, and portable between macOS and
  Linux — CI runs the suite on both. `date -r` vs `date -d` is the usual trap;
  `lib/project.sh` already handles it.
- The hook **always exits 0**. A notifier must never block the agent. Failures
  go to stderr and the run continues.
- Comments explain *why*, not what. If a line looks wrong but is deliberate,
  say what goes wrong without it.
- Don't commit or push unless asked.
