#!/bin/sh
# Fails unless test.yml's `test` check passed on a commit: scripts/require-tested.sh <sha>
# Releases only ship commits CI tested; test.yml runs on every push to main and v*.x.
# Needs GH_TOKEN with checks: read, and GITHUB_REPOSITORY (both set in Actions).
set -eu
sha=${1:?usage: require-tested.sh <sha>}
state=$(gh api "repos/$GITHUB_REPOSITORY/commits/$sha/check-runs?check_name=test" \
    --jq '[.check_runs[] | .conclusion // "pending"] | first // "missing"')
[ "$state" = success ] && exit 0
echo "::error::The test check on $sha is $state; release it once test.yml has passed on it" >&2
exit 1
