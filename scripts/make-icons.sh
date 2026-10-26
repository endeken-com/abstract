#!/bin/zsh
# Makes every app icon from the two Horizonte sources in Abstract/Resources/Brand:
# the Mac's Icon Composer images and the phone's icons (Abstract/Resources/ICONS.md).
#   scripts/make-icons.sh           remake them all, then check them
#   scripts/make-icons.sh --check   only check that each is there at the right pixel size
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift -O scripts/make-icons.swift "$@"
