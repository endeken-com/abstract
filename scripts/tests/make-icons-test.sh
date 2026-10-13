#!/bin/sh
# Tests scripts/make-icons.sh --check against a copy of the icons: sh scripts/tests/make-icons-test.sh
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
cd "$root"
mkdir -p "$work/scripts"
cp scripts/make-icons.sh scripts/make-icons.swift "$work/scripts/"
tar cf - Abstract/Resources/AppIcon.icon mobile/assets/icon-*.png mobile/ios/Abstract/Images.xcassets/AppIcon.appiconset | tar xf - -C "$work"
check() { zsh "$work/scripts/make-icons.sh" --check > "$work/out" 2>&1; }

check || { echo "FAIL the checked-in icons don't pass"; cat "$work/out"; exit 1; }

# A size that's missing.
mv "$work/mobile/assets/icon-arc.png" "$work/arc.png"
if check; then echo "FAIL a missing icon passed"; exit 1; fi
grep -q "icon-arc.png is missing" "$work/out" || { echo "FAIL the missing icon wasn't named"; cat "$work/out"; exit 1; }
mv "$work/arc.png" "$work/mobile/assets/icon-arc.png"

# A size that's the wrong number of pixels.
sips -z 512 512 "$work/mobile/assets/icon-light.png" > /dev/null
if check; then echo "FAIL a 512 px icon passed as 1024"; exit 1; fi
grep -q "icon-light.png is 512×512, not 1024×1024" "$work/out" || { echo "FAIL the wrong size wasn't named"; cat "$work/out"; exit 1; }
cp mobile/assets/icon-light.png "$work/mobile/assets/icon-light.png"

# The Icon Composer document names an image that isn't in it.
rm "$work/Abstract/Resources/AppIcon.icon/Assets/horizonte-dark.png"
if check; then echo "FAIL a missing Mac master passed"; exit 1; fi
grep -q "names horizonte-dark.png" "$work/out" || { echo "FAIL the document's missing image wasn't named"; cat "$work/out"; exit 1; }
echo "all make-icons tests passed"
