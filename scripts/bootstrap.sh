#!/usr/bin/env bash
# Bootstraps the Tripto Xcode project from project.yml.
#
# Usage:
#   scripts/bootstrap.sh          generate Tripto.xcodeproj
#   scripts/bootstrap.sh --open   generate, then open it in Xcode
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
fi

# One-time wiring: pulls/checkouts auto-regenerate the gitignored project
# (scripts/git-hooks/post-merge + post-checkout) — a checkout that pulls
# merges from worktree-built PRs otherwise opens a stale .xcodeproj.
git config core.hooksPath scripts/git-hooks 2>/dev/null || true

if [[ "${1:-}" == "--quiet" ]]; then
    xcodegen generate --quiet
    exit 0
fi

echo "-> xcodegen generate"
xcodegen generate

if [[ "${1:-}" == "--open" ]]; then
    open Tripto.xcodeproj
else
    echo "Done. Open Tripto.xcodeproj (or run: open Tripto.xcodeproj) and run the Tripto scheme."
fi
