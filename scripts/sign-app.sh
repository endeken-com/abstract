#!/bin/zsh
# Re-signs a built Abstract.app for distribution: scripts/sign-app.sh <app> <identity> [keychain]
# Signs inside out, as notarization requires: Sparkle's helpers, Sparkle, the `abstract`
# command line, then the app, each
# with the hardened runtime and a secure timestamp. Identity "-" signs ad hoc, for local checks,
# and leaves the runtime off: its library validation refuses ad hoc frameworks.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=$1 IDENTITY=$2 KEYCHAIN=${3:-}
FLAGS=(--force --sign "$IDENTITY")
[[ $IDENTITY == "-" ]] || FLAGS+=(--options runtime --timestamp)
[[ -z $KEYCHAIN ]] || FLAGS+=(--keychain "$KEYCHAIN")

SPARKLE=$APP/Contents/Frameworks/Sparkle.framework
# Abstract isn't sandboxed, so Sparkle's XPC services go unused: remove them and the
# top-level symlink to them (a dangling symlink fails strict verification).
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"
codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${FLAGS[@]}" "$SPARKLE"
codesign "${FLAGS[@]}" "$APP/Contents/Helpers/abstract"
codesign "${FLAGS[@]}" --entitlements Abstract/Resources/Abstract.entitlements "$APP"
codesign --verify --deep --strict "$APP"
