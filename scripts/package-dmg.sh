#!/bin/zsh
# Builds Abstract for release and packages it as build/release/Abstract-<version>.dmg:
# the app beside an Applications link, with the app's icon on the volume and the file.
set -euo pipefail
cd "$(dirname "$0")/.."

# BUILD_NUMBER becomes CFBundleVersion; the full build log lands in build/xcodebuild-release.log.
mkdir -p build
xcodebuild -project Abstract.xcodeproj -scheme Abstract -configuration Release \
  -derivedDataPath build/dd-release -skipPackagePluginValidation \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" build | tee build/xcodebuild-release.log | tail -1

APP=build/dd-release/Build/Products/Release/Abstract.app
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
echo "$DMG"
