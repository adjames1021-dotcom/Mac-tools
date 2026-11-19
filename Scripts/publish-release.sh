#!/bin/bash
# Builds MacTools and publishes it as a GitHub release, so the in-app
# "Download Ready-Made" update can install it without compiling.
#
#   ./Scripts/publish-release.sh        release the version in VERSION (tag vX.Y)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first, so the release matches the code."; exit 1; }
git push

VERSION="$(tr -d '[:space:]' < VERSION)"
./build.sh --force
ZIP="build.noindex/MacTools.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build.noindex/MacTools.app "$ZIP"

TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" --clobber   # same version again: replace the app
else
  gh release create "$TAG" "$ZIP" --title "MacTools $VERSION" --target "$(git rev-parse HEAD)" --generate-notes
fi
echo "Published MacTools $VERSION ($TAG)."
