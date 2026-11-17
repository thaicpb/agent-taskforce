#!/usr/bin/env bash
# Install the agent-taskforce skill + agents into ~/.claude via symlinks (without the plugin system).
# Use this to edit prompts in the cloned repo and see changes immediately.
#   ./install.sh              # create symlinks, skip files that already exist
#   ./install.sh --force      # overwrite (old files are renamed to *.bak.<timestamp>)
#   ./install.sh --uninstall  # remove symlinks pointing into this repo
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MODE="${1:-install}"
TS="$(date +%Y%m%d%H%M%S)"

link() {
  local src="$1" dst="$2"
  if [ "$MODE" = "--uninstall" ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      rm "$dst" && echo "removed  $dst"
    fi
    return
  fi
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    echo "ok       $dst"; return
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ "$MODE" != "--force" ]; then
      echo "skip     $dst (already exists; use --force to overwrite)"; return
    fi
    mv "$dst" "$dst.bak.$TS" && echo "backup   $dst -> $dst.bak.$TS"
  fi
  ln -s "$src" "$dst" && echo "linked   $dst -> $src"
}

link "$REPO_DIR/skills/dev-task" "$CLAUDE_DIR/skills/dev-task"
for f in "$REPO_DIR"/agents/*.md; do
  link "$f" "$CLAUDE_DIR/agents/$(basename "$f")"
done
