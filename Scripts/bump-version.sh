#!/bin/bash
# Bumps the MacTools version number in VERSION.
#
#   ./Scripts/bump-version.sh small   small update: +0.1   (2.2 → 2.3, 2.9 → 2.10)
#   ./Scripts/bump-version.sh full    full update: next whole number (2.7 → 3.0)
set -euo pipefail
cd "$(dirname "$0")/.."

current="$(tr -d '[:space:]' < VERSION)"
major="${current%%.*}"
minor="${current#*.}"
[[ "$minor" == "$current" ]] && minor=0
if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
  echo "VERSION should look like 2.2 (it says \"$current\")"
  exit 1
fi

case "${1:-}" in
  small) minor=$((minor + 1)) ;;
  full) major=$((major + 1)); minor=0 ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac

echo "$major.$minor" > VERSION
echo "MacTools $current → $major.$minor"
