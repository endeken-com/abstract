#!/bin/sh
# The shape guard passes on the repository and fails on a planted literal.
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$root/scripts/check-shapes.sh" "$root" > /dev/null

plant() {
    rm -rf "$tmp/repo"
    mkdir -p "$tmp/repo/Abstract/Features" "$tmp/repo/Abstract/Theme" "$tmp/repo/Abstract/Components"
    printf '%s\n' "$2" > "$tmp/repo/Abstract/$1"
}
fails() {
    if "$root/scripts/check-shapes.sh" "$tmp/repo" > "$tmp/output" 2>&1; then
        echo "check-shapes accepted: $1" >&2
        exit 1
    fi
}
passes() {
    "$root/scripts/check-shapes.sh" "$tmp/repo" > "$tmp/output" 2>&1 || { cat "$tmp/output" >&2; exit 1; }
}

plant Features/A.swift '.background(RoundedRectangle(cornerRadius: 6, style: .continuous))'
fails 'a literal corner radius'
grep -q 'Features/A.swift:1' "$tmp/output"
plant Features/A.swift 'Circle().strokeBorder(Color.btBorder, lineWidth: 0.5)'
fails 'a literal stroke width'
plant Features/A.swift '.stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))'
fails 'a literal width in a StrokeStyle'
plant Features/A.swift 'let outline = Path(roundedRect: frame, cornerRadius: 2.6)'
fails 'a literal radius in a Path'
plant Features/A.swift '.btRaised(radius: 14)'
fails 'a literal radius passed to btRaised'
plant Features/A.swift 'view.cornerRadius(8)'
fails 'the cornerRadius modifier with a number'

plant Features/A.swift '.background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))'
passes
plant Features/A.swift '.buttonStyle(RowButtonStyle(cornerRadius: .zero))'
passes
plant Theme/Typography.swift 'static let x = RoundedRectangle(cornerRadius: 8)'
passes
plant Components/Buttons.swift '.overlay(shape.strokeBorder(border, lineWidth: 1))'
passes
plant Features/A.swift '.shadow(color: .black, radius: 14, y: 6)'
passes
echo "check-shapes-test: ok"
