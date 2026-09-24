#!/bin/zsh
# Builds Abstract for release and prints the path of the .app: scripts/build-app.sh
# MARKETING_VERSION and BUILD_NUMBER set its version (default 0.0.0 and 1: a dev build).
# The app comes out signed ad hoc; scripts/sign-app.sh re-signs it for distribution.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
xcodebuild -project Abstract.xcodeproj -scheme Abstract -configuration Release \
  -derivedDataPath build/dd-release -skipPackagePluginValidation \
  MARKETING_VERSION="${MARKETING_VERSION:-0.0.0}" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  build > build/xcodebuild-release.log 2>&1 || { tail -40 build/xcodebuild-release.log >&2; exit 1; }
echo "$PWD/build/dd-release/Build/Products/Release/Abstract.app"
