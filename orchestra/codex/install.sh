#!/usr/bin/env bash
# Install the Codex entrypoints for this plugin's orchestrator and player skills.
#
# Codex reads skills from ~/.agents/skills/<name>/SKILL.md. This creates (or refreshes)
#   ~/.agents/skills/orchestrator/{SKILL.md,agents/openai.yaml,scripts -> <plugin>/skills/orchestrator/scripts}
#   ~/.agents/skills/player/{SKILL.md,agents/openai.yaml,scripts -> <plugin>/skills/player/scripts}
# The scripts are linked, not copied, so both harnesses run the same files. Re-run after the
# plugin moves (a Claude Code plugin update installs a new version directory) or link this
# script's checkout of the repository instead of the plugin cache.
#
# Usage: install.sh [--skills-dir DIR] [--force]
#   --skills-dir DIR  install under DIR instead of ~/.agents/skills
#   --force           replace an existing non-linked scripts directory or SKILL.md
set -eu
here="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
plugin="$(cd "$here/.." && pwd)"
dest="${HOME}/.agents/skills"; force=0
while [ $# -gt 0 ]; do case "$1" in
  --skills-dir) dest="$2"; shift;; --force) force=1;;
  -h|--help) sed -n '2,14p' "$0"; exit 0;;
  *) echo "install.sh: unknown argument $1" >&2; exit 2;; esac; shift; done
for skill in orchestrator player; do
  src="$here/$skill"; scripts="$plugin/skills/$skill/scripts"; target="$dest/$skill"
  [ -d "$scripts" ] || { echo "install.sh: $scripts is missing; run this from an intact plugin checkout" >&2; exit 1; }
  mkdir -p "$target/agents"
  if [ -e "$target/scripts" ] && [ ! -L "$target/scripts" ] && [ $force = 0 ]; then
    echo "install.sh: $target/scripts exists and is not a link; pass --force to replace it" >&2; exit 1
  fi
  if [ -e "$target/SKILL.md" ] && [ $force = 0 ] && ! cmp -s "$src/SKILL.md" "$target/SKILL.md"; then
    echo "install.sh: $target/SKILL.md differs from the plugin's; pass --force to replace it" >&2; exit 1
  fi
  rm -rf "$target/scripts"
  ln -s "$scripts" "$target/scripts"
  cp "$src/SKILL.md" "$target/SKILL.md"
  cp "$src/agents/openai.yaml" "$target/agents/openai.yaml"
  echo "installed $target (scripts -> $scripts)"
done
echo "Codex skills installed; invoke them as \$orchestrator and \$player (explicit-only)."
