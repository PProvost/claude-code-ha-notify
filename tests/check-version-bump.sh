#!/usr/bin/env bash
#
# check-version-bump.sh - fail when the plugin's shipped files change without
# a version bump.
#
# Claude Code decides whether an update exists by comparing the `version` in
# .claude-plugin/plugin.json. The commit sha recorded at install time is not
# used for it. So shipping a change without bumping the version means the new
# code never reaches anyone who already has the plugin installed, and the only
# symptom is a silent non-update on someone else's machine weeks later.
#
# Usage: check-version-bump.sh [BASE] [HEAD] [REPO]
#   BASE  commit to compare from (default: origin/main)
#   HEAD  commit to compare to   (default: HEAD)
#   REPO  repository to inspect  (default: this one)
#
# Exits 0 if the rule holds or no shipped file changed, 1 if it is broken.

set -u

BASE="${1:-origin/main}"
HEAD_REF="${2:-HEAD}"
REPO="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

MANIFEST="claude-code/.claude-plugin/plugin.json"

# Everything under claude-code/ ships to the user's machine except the manual
# install guide, which is only ever read in this repository. Excluding by
# exception rather than listing directories means a new shipped folder is
# covered automatically.
SHIPPED=(claude-code/ ":(exclude)claude-code/manual-install.md")

git() { command git -C "$REPO" "$@"; }

changed="$(git diff --name-only "$BASE" "$HEAD_REF" -- "${SHIPPED[@]}" 2>/dev/null)"

if [ -z "$changed" ]; then
  echo "check-version-bump: no shipped plugin files changed"
  exit 0
fi

version_at() {
  git show "$1:$MANIFEST" 2>/dev/null \
    | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

base_version="$(version_at "$BASE")"
head_version="$(version_at "$HEAD_REF")"

# No manifest at BASE means the plugin is new in this range; nothing to bump.
if [ -z "$base_version" ]; then
  echo "check-version-bump: no manifest at $BASE, treating the plugin as new"
  exit 0
fi

if [ -z "$head_version" ]; then
  echo "check-version-bump: $MANIFEST has no version at $HEAD_REF" >&2
  exit 1
fi

if [ "$base_version" != "$head_version" ]; then
  echo "check-version-bump: ok, $base_version -> $head_version"
  exit 0
fi

{
  echo "check-version-bump: shipped plugin files changed but the version is still $head_version"
  echo
  echo "Changed:"
  printf '%s\n' "$changed" | sed 's/^/  /'
  echo
  echo "Bump \"version\" in $MANIFEST. Claude Code compares that field to decide"
  echo "an update exists, so without it these changes reach nobody who already"
  echo "has the plugin installed."
} >&2
exit 1
