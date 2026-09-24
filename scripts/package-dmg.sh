#!/bin/zsh
# Packages Abstract.app as build/release/Abstract-<version>.dmg: the app beside an
# Applications link, with the app's icon on the volume and the file.
#   scripts/package-dmg.sh [path/to/Abstract.app]   (builds a dev app first when none is given)
# DMG_SIGN_IDENTITY, and DMG_KEYCHAIN if the identity lives in one, sign the image.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:-$(scripts/build-app.sh)}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ICON="$APP/Contents/Resources/AppIcon.icns"
OUT=build/release
STAGE=$OUT/stage
RW=$OUT/Abstract-rw.dmg
DMG=$OUT/Abstract-$VERSION.dmg

rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Abstract.app"
ln -s /Applications "$STAGE/Applications"
cp "$ICON" "$STAGE/.VolumeIcon.icns"

hdiutil create -volname "Abstract $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT=$(hdiutil attach "$RW" -nobrowse -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')
# The volume shows the app's icon once mounted.
SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW"

# Signed before the icon is set: the icon is Finder metadata beside the image, not in it.
if [[ -n ${DMG_SIGN_IDENTITY:-} ]]; then
  SIGN=(--force --timestamp --sign "$DMG_SIGN_IDENTITY")
  [[ -z ${DMG_KEYCHAIN:-} ]] || SIGN+=(--keychain "$DMG_KEYCHAIN")
  codesign "${SIGN[@]}" "$DMG"
fi

# The .dmg file itself wears the icon in Finder.
SETICON=$(mktemp -t seticon).swift
cat > "$SETICON" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
_ = NSWorkspace.shared.setIcon(NSImage(contentsOfFile: args[1]), forFile: args[2], options: [])
SWIFT
swift "$SETICON" "$ICON" "$DMG"
rm -f "$SETICON"

hdiutil verify "$DMG" >/dev/null
echo "$PWD/$DMG"
