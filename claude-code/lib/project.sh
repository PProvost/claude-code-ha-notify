# shellcheck shell=bash
# Shared by scripts/notify.sh and bin/notify-mute.
#
# Both must agree on one thing: which directory is "the project". The hook is
# given CLAUDE_PROJECT_DIR; notify-mute is not, because CLAUDE_PLUGIN_* and
# CLAUDE_PROJECT_DIR are absent from commands Claude runs through the Bash tool.
# If the two resolved it differently they would read different mute files and
# the mute would silently do nothing, so the logic lives here once.

# Resolves the project directory from a starting point. The git repository root
# wins, because that is also what names the project in the payload; without a
# repository the starting directory is used as-is.
ha_notify_project_dir() {
  local start="${1:-$PWD}" top
  if top="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
    printf '%s\n' "$top"
  else
    printf '%s\n' "$start"
  fi
}

ha_notify_mute_file() {
  printf '%s/.claude/notify-muted\n' "${1:?project dir required}"
}

# True while the mute file holds an end time that has not passed yet. A missing,
# empty or unparsable file means "not muted" - the mute must never be able to
# silence notifications permanently through a damaged file.
ha_notify_is_muted() {
  local file="${1:?mute file required}" until
  [ -r "$file" ] || return 1
  until="$(tr -cd '0-9' < "$file" 2>/dev/null)"
  [ -n "$until" ] || return 1
  [ "$until" -gt "$(date +%s)" ] 2>/dev/null
}

# Formats Unix seconds as HH:MM. BSD date (macOS) and GNU date disagree on the
# flag, so try both.
ha_notify_clock() {
  local epoch="${1:?epoch required}"
  date -r "$epoch" +%H:%M 2>/dev/null \
    || date -d "@$epoch" +%H:%M 2>/dev/null \
    || printf '%s\n' "$epoch"
}
