#!/usr/bin/env bash
# Deploy the panel installer(s) to this machine.
#
# There's no remote server here — both installers already write straight to
# ~/.local/bin, ~/.zshrc, ~/.config/ghostty/config, and ~/.claude/settings.json,
# so "deploy" means "run the installer(s) again to pick up the latest script
# changes." Both are idempotent (see README's "Idempotent" note), so re-running
# after every edit is always safe.
#
# Usage:
#   bash deploy.sh            # deploy both panels (default)
#   bash deploy.sh claude     # deploy only the Claude Code panel
#   bash deploy.sh opencode   # deploy only the OpenCode panel

set -euo pipefail

main() {
  local target="${1:-all}"
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  case "$target" in
    claude)
      echo "==> Deploying Claude Code panel..."
      bash "$dir/claude-panel-setup.sh"
      ;;
    opencode)
      echo "==> Deploying OpenCode panel..."
      bash "$dir/opencode-panel-setup.sh"
      ;;
    all)
      echo "==> Deploying Claude Code panel..."
      bash "$dir/claude-panel-setup.sh"
      echo
      echo "==> Deploying OpenCode panel..."
      bash "$dir/opencode-panel-setup.sh"
      ;;
    *)
      echo "usage: bash deploy.sh [claude|opencode|all]" >&2
      exit 1
      ;;
  esac

  echo
  echo "Deploy complete."
}

main "$@"
