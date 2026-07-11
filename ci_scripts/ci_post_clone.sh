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

# Xcode Cloud disables automatic SPM resolution and requires a committed
# Package.resolved. Ours normally lives inside the gitignored .xcodeproj, so a
# pinned copy is committed at ci_scripts/Package.resolved — drop it into the
# freshly generated project so the "Resolve package dependencies" step finds it.
echo "▸ Placing pinned Package.resolved…"
SWIFTPM_DIR="Tripto.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$SWIFTPM_DIR"
cp ci_scripts/Package.resolved "$SWIFTPM_DIR/Package.resolved"

echo "▸ Done: $(ls -d Tripto.xcodeproj) + Package.resolved in place"
