#!/bin/sh

# Xcode Cloud post-clone hook.
#
# The repo commits project.yml (the XcodeGen source of truth) but NOT the
# generated Tripto.xcodeproj — it's .gitignored (see scripts/bootstrap.sh).
# Xcode Cloud clones the repo and then needs a real .xcodeproj to build, so
# regenerate it here, right after the clone and before the build starts.

set -e

echo "▸ Installing XcodeGen…"
brew install xcodegen

echo "▸ Generating Tripto.xcodeproj from project.yml…"
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

echo "▸ Done: $(ls -d Tripto.xcodeproj)"
