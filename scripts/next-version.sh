#!/bin/sh
# Computes release versions from the current repository's git tags.
#   scripts/next-version.sh cut minor|major   ->  0.9.0 0.9.0
#   scripts/next-version.sh patch v0.9.x      ->  0.9.1 0.9.1   (run on the release branch)
#   scripts/next-version.sh nightly 42        ->  0.10.0-nightly.42 0.10.0.42
#   scripts/next-version.sh previous 0.9.1    ->  v0.9.0        (empty when there is none)
#   scripts/next-version.sh latest            ->  0.9.1         (empty when there is none)
# cut, patch and nightly print "<CFBundleShortVersionString> <CFBundleVersion>".
# Only vMAJOR.MINOR.PATCH tags count: v1.0, v0.9.0-rc1 and nightly are ignored.
# POSIX sh so the Linux release jobs can run it too.
set -eu

die() { echo "next-version: $*" >&2; exit 64; }

# Stable versions without the v, oldest first. Numeric sort, so 0.10.0 follows 0.9.0.
stable() {
    git tag --list 'v*' |
        sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' |
        sort -t. -k1,1n -k2,2n -k3,3n
}

latest() { stable | tail -n 1; }

# Splits a MAJOR.MINOR.PATCH version into $ma $mi $pa.
split() {
    ma=${1%%.*}; rest=${1#*.}; mi=${rest%%.*}; pa=${rest#*.}
}

# The stable tag on HEAD, if any.
tagged_here() {
    git tag --points-at HEAD | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | head -n 1
}

case "${1:-}" in
cut)
    case "${2:-}" in minor|major) ;; *) die "usage: next-version.sh cut minor|major" ;; esac
    here=$(tagged_here)
    [ -z "$here" ] || die "HEAD is already v$here; merge something new before cutting another release"
    base=$(latest); split "${base:-0.0.0}"
    if [ "$2" = major ]; then next=$((ma + 1)).0.0; else next=$ma.$((mi + 1)).0; fi
    echo "$next $next"
    ;;
patch)
    line=$(printf '%s\n' "${2:-}" | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\)\.x$/\1/p')
    [ -n "$line" ] || die "patch needs a release branch like v0.9.x, got '${2:-}'"
    last=$(stable | awk -F. -v line="$line" '$1 "." $2 == line' | tail -n 1)
    [ -n "$last" ] || die "no v$line.* tag yet; cut the release before patching it"
    here=$(tagged_here)
    [ -z "$here" ] || die "the branch head is already v$here; cherry-pick the fix onto v$line.x first"
    split "$last"
    next=$ma.$mi.$((pa + 1))
    echo "$next $next"
    ;;
nightly)
    case "${2:-}" in ''|*[!0-9]*) die "usage: next-version.sh nightly <run-number>" ;; esac
    base=$(latest); split "${base:-0.0.0}"
    next=$ma.$((mi + 1)).0
    echo "$next-nightly.$2 $next.$2"
    ;;
previous)
    printf '%s\n' "${2:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "usage: next-version.sh previous MAJOR.MINOR.PATCH"
    split "$2"
    stable | awk -F. -v ma="$ma" -v mi="$mi" -v pa="$pa" '
        $1 + 0 < ma + 0 || ($1 + 0 == ma + 0 && ($2 + 0 < mi + 0 || ($2 + 0 == mi + 0 && $3 + 0 < pa + 0))) { found = $0 }
        END { if (found != "") print "v" found }'
    ;;
latest)
    latest
    ;;
*)
    die "usage: next-version.sh cut|patch|nightly|previous|latest ..."
    ;;
esac
