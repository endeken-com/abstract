#!/bin/sh
# Tests scripts/superseded-nightly-dmgs.jq over sample asset lists: sh scripts/tests/superseded-nightly-dmgs-test.sh
set -eu
filter="$(cd "$(dirname "$0")/.." && pwd)/superseded-nightly-dmgs.jq"
failures=0

expect() { # expect "<what>" "<wanted names, space-separated>" "<assets JSON>"
    what=$1 want=$2 assets=$3
    got=$(printf '%s' "$assets" | KEEP=Abstract-0.13.0-nightly.80.dmg jq -r -f "$filter" | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then echo "ok   $what"; else echo "FAIL $what: wanted '$want', got '$got'"; failures=$((failures + 1)); fi
}
asset() { printf '{"name":"%s","createdAt":"2026-11-%sT06:30:00Z"}' "$1" "$2"; }

expect "only old DMGs are selected, oldest last" \
    "Abstract-0.13.0-nightly.78.dmg Abstract-0.13.0-nightly.77.dmg" \
    "{\"assets\":[$(asset Abstract-0.13.0-nightly.77.dmg 10),$(asset Abstract-0.13.0-nightly.78.dmg 11),
      $(asset Abstract-0.13.0-nightly.79.dmg 12),$(asset sh.abstract.bitbucket-1.0.1.zip 12),
      $(asset plugins.json 13),$(asset sh.abstract.bitbucket-1.0.2.zip 13),$(asset sh.abstract.github-1.1.0.zip 13),
      $(asset sh.abstract.theme.paper-1.0.0.zip 13),$(asset Abstract-0.13.0-nightly.80.dmg 13)]}"

expect "the previous DMG stays even when it is older than the catalog" "" \
    "{\"assets\":[$(asset Abstract-0.13.0-nightly.79.dmg 12),$(asset plugins.json 13),
      $(asset sh.abstract.github-1.1.0.zip 13),$(asset Abstract-0.13.0-nightly.80.dmg 13)]}"

expect "a first nightly deletes nothing" "" \
    "{\"assets\":[$(asset plugins.json 13),$(asset sh.abstract.github-1.1.0.zip 13),$(asset Abstract-0.13.0-nightly.80.dmg 13)]}"

expect "a release without the new DMG keeps its newest" "Abstract-0.13.0-nightly.78.dmg" \
    "{\"assets\":[$(asset Abstract-0.13.0-nightly.78.dmg 11),$(asset Abstract-0.13.0-nightly.79.dmg 12),$(asset plugins.json 12)]}"

if [ "$failures" -ne 0 ]; then echo "$failures failed"; exit 1; fi
echo "all passed"
