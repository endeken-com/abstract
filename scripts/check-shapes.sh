#!/bin/sh
# Fails when Swift code outside Abstract/Theme and Abstract/Components picks its
# own corner radius or stroke width as a number. Corners and borders come from
# the shape scale (`Radius`, `Stroke` in Abstract/Theme/Typography.swift); see
# docs/design.md.
#   scripts/check-shapes.sh [<repository root>]
set -eu
root=${1:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
number='(-?[0-9]|\.[0-9])'
literal="(cornerRadius|lineWidth): *$number|\\.cornerRadius\\( *$number|\\.(btRaised|btCard|btFieldChrome)\\([^)]*radius: *$number"
found=$(cd "$root" && grep -rnE --include='*.swift' "$literal" Abstract \
    | grep -vE '^Abstract/(Theme|Components)/' || true)
if [ -n "$found" ]; then
    echo "$found"
    echo "check-shapes: use Radius.mark/.control/.card/.sheet and Stroke.hairline/.emphasis/.glyph" \
         "(docs/design.md) instead of a number." >&2
    exit 1
fi
echo "check-shapes: every corner and stroke outside Theme and Components is on the scale."
