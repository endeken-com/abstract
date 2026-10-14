#!/bin/sh
# Fails unless test.yml's `test` check passed on a commit.
# Usage: scripts/require-tested.sh <sha> [wait-seconds]
# Releases only ship commits CI tested; test.yml runs on every push to main and v*.x.
# Needs GH_TOKEN with checks: read, and GITHUB_REPOSITORY (both set in Actions).
set -eu
sha=${1:?usage: require-tested.sh <sha>}
remaining=${2:-0}
case "$remaining" in ''|*[!0-9]*) echo 'usage: require-tested.sh <sha> [wait-seconds]' >&2; exit 64 ;; esac

while :; do
    # Re-runs create another check run. Use the newest result for this commit.
    state=$(gh api "repos/$GITHUB_REPOSITORY/commits/$sha/check-runs?check_name=test" \
        --jq 'if .check_runs | length == 0 then "missing" else (.check_runs | max_by(.id).conclusion // "pending") end')
    case "$state" in
        success) exit 0 ;;
        pending|missing)
            if [ "$remaining" -eq 0 ]; then
                echo "::error::The test check on $sha is $state; release it once test.yml has passed on it" >&2
                exit 1
            fi
            delay=30
            [ "$remaining" -ge "$delay" ] || delay=$remaining
            echo "The test check on $sha is $state; checking again in ${delay}s"
            sleep "$delay"
            remaining=$((remaining - delay))
            ;;
        *)
            echo "::error::The test check on $sha is $state; release it once test.yml has passed on it" >&2
            exit 1
            ;;
    esac
done
