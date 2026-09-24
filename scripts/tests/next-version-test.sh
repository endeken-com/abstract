#!/bin/sh
# Tests scripts/next-version.sh against throwaway repositories: sh scripts/tests/next-version-test.sh
set -eu
script="$(cd "$(dirname "$0")/.." && pwd)/next-version.sh"
failures=0

fresh_repo() {
    cd "$(mktemp -d)"
    git init -q
    commit init
}
commit() { git -c user.name=Test -c user.email=test@abstract.local commit -q --allow-empty -m "$1"; }

expect() { # expect "<what>" "<wanted output>" <args...>
    what=$1 want=$2; shift 2
    got=$(sh "$script" "$@" 2>&1) || got="(exit $?) $got"
    if [ "$got" = "$want" ]; then echo "ok   $what"; else echo "FAIL $what: wanted '$want', got '$got'"; failures=$((failures + 1)); fi
}
expect_error() { # expect_error "<what>" "<message fragment>" <args...>
    what=$1 fragment=$2; shift 2
    if out=$(sh "$script" "$@" 2>&1); then
        echo "FAIL $what: wanted an error, got '$out'"; failures=$((failures + 1))
    elif printf '%s' "$out" | grep -qF "$fragment"; then echo "ok   $what"
    else echo "FAIL $what: error '$out' lacks '$fragment'"; failures=$((failures + 1)); fi
}

# No releases yet.
fresh_repo
expect "first minor cut" "0.1.0 0.1.0" cut minor
expect "first major cut" "1.0.0 1.0.0" cut major
expect "nightly before any release" "0.1.0-nightly.7 0.1.0.7" nightly 7
expect "no previous release" "" previous 0.1.0
expect "no latest release" "" latest

# Stray tags never count, and 0.10 sorts above 0.9.
fresh_repo
git tag v0.8.2; commit a; git tag v0.9.0; commit b; git tag v0.10.0
git tag v0.11.0-rc1; git tag v1.0; git tag nightly; git tag v2.0.0-beta
commit c
expect "latest ignores stray tags" "0.10.0" latest
expect "minor cut after 0.10.0" "0.11.0 0.11.0" cut minor
expect "major cut after 0.10.0" "1.0.0 1.0.0" cut major
expect "nightly after 0.10.0" "0.11.0-nightly.42 0.11.0.42" nightly 42
expect "previous of a new minor" "v0.10.0" previous 0.11.0
expect "previous skips the version itself" "v0.9.0" previous 0.10.0
expect "previous across a major" "v0.10.0" previous 1.0.0

# Refuses to cut the same commit twice.
git tag v0.11.0
expect_error "cut on an already-released head" "already v0.11.0" cut minor

# Patches count only their own line.
fresh_repo
git tag v0.9.0; commit fix1; git tag v0.9.1; commit b; git tag v0.10.0; git checkout -q -b v0.9.x v0.9.1; commit fix2
expect "patch after two releases on the line" "0.9.2 0.9.2" patch v0.9.x
expect "previous of that patch" "v0.9.1" previous 0.9.2
expect "nightly ignores the patch line" "0.11.0-nightly.3 0.11.0.3" nightly 3
git tag v0.9.2
expect_error "patch with nothing new on the branch" "already v0.9.2" patch v0.9.x
expect_error "patch of a line never cut" "no v0.12.* tag" patch v0.12.x
expect_error "patch of a non-release branch" "release branch like v0.9.x" patch main
expect_error "nightly without a run number" "usage" nightly
expect_error "nightly with a non-numeric run" "usage" nightly abc
expect_error "cut with a bad level" "usage" cut patch

if [ "$failures" -ne 0 ]; then echo "$failures next-version test(s) failed"; exit 1; fi
echo "all next-version tests passed"
