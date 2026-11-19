#!/bin/zsh
# Runs demo mode's transcript width probe (ABS-212) and saves the window after
# each of its steps:
#   scripts/demo-width-check.sh <Abstract.app> <dir>
# A chat streams while another shows, then the side panel is dragged to each
# end. Fails when a row was built at another width than the chat column's, or
# the probe doesn't finish within WIDTH_TIMEOUT seconds (default 300).
set -euo pipefail
app=${1:?usage: scripts/demo-width-check.sh <Abstract.app> <dir>}
dir=${2:?usage: scripts/demo-width-check.sh <Abstract.app> <dir>}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
app=$(cd "$app" && pwd)
log="$dir/width.log"

open -n --env "ABSTRACT_DEMO_WIDTH=8" --env "ABSTRACT_DEMO_WIDTH_SHOT=$dir" --stderr "$log" "$app" --args --demo
deadline=$(( SECONDS + ${WIDTH_TIMEOUT:-300} ))
until grep -qE "^width probe: (PASS|FAIL)" "$log" 2>/dev/null || (( SECONDS > deadline )); do sleep 5; done
pkill -f "$app/Contents/MacOS/Abstract" || true

grep "^width probe" "$log" || true
if ! grep -q "^width probe: PASS" "$log"; then
  echo "demo-width-check: rows at the wrong width, or the probe didn't finish; the end of the app's log:" >&2
  tail -40 "$log" >&2
  exit 1
fi
