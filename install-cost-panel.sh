#!/usr/bin/env bash
# Explicitly-named entry point for "install the cost panel". Delegates
# entirely to deploy.sh, this repo's one real installer (already idempotent,
# see README's "Idempotent" section) -- no logic is duplicated here.
#
# Usage: bash install-cost-panel.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/deploy.sh" claude
