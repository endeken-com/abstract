#!/bin/zsh
# Sets the app's version to main's version bumped one level: scripts/bump-version.sh major|minor|patch.
# It bumps from main, not the working tree, so a branch is bumped once however often this runs,
# and rerunning with a bigger level escalates rather than stacking.
set -euo pipefail
cd "$(dirname "$0")/.."

LEVEL=${1:-}
[[ $LEVEL == (major|minor|patch) ]] || { echo "usage: $0 major|minor|patch" >&2; exit 64; }

git fetch -q origin main 2>/dev/null || true
BASE=$(scripts/version.sh origin/main 2>/dev/null || true)
[[ -n $BASE ]] || BASE=$(scripts/version.sh)
IFS=. read MAJOR MINOR PATCH <<< "$BASE"
case $LEVEL in
  major) NEXT=$((MAJOR + 1)).0.0 ;;
  minor) NEXT=$MAJOR.$((MINOR + 1)).0 ;;
  patch) NEXT=$MAJOR.$MINOR.$((PATCH + 1)) ;;
esac

sed -i '' -E "s/^( *CFBundleShortVersionString: )\"[^\"]*\"/\1\"$NEXT\"/" project.yml
echo "$BASE -> $NEXT"
