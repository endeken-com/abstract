#!/bin/zsh
# Runs the app in demo mode and saves a PNG of every screen in each theme:
#   scripts/demo-snapshot.sh <Abstract.app> <dir>
# The run's log goes to <dir>/demo.log. Fails only when the run hangs past
# SNAPSHOT_TIMEOUT seconds (default 900) or a theme comes out with no screens;
# what the screens look like is for a person to judge.
# It sets the app's theme as it goes and leaves it on Graphite.
set -euo pipefail
app=${1:?usage: scripts/demo-snapshot.sh <Abstract.app> <dir>}
dir=${2:?usage: scripts/demo-snapshot.sh <Abstract.app> <dir>}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
app=$(cd "$app" && pwd)

# Launched through `open`, the app comes forward with a window; run as a plain
# process from a script it often has none. The directory goes in the
# environment: a path on the command line reads to AppKit as a document to open.
open -n -W --env "ABSTRACT_DEMO_SNAPSHOT=$dir" --stderr "$dir/demo.log" "$app" --args --demo &
opener=$!
( sleep "${SNAPSHOT_TIMEOUT:-900}" && echo "demo-snapshot: timed out" >> "$dir/demo.log" &&
  pkill -f "$app/Contents/MacOS/Abstract" ) > /dev/null 2>&1 &
watchdog=$!
wait "$opener" || true
kill "$watchdog" 2>/dev/null || true

failed=0
for theme in graphite paper ink; do
  count=$(find "$dir" -maxdepth 1 -name "$theme-*.png" | wc -l | tr -d ' ')
  echo "$theme: $count screens"
  if [ "$count" -eq 0 ]; then failed=1; fi
done
if [ "$failed" -ne 0 ] || grep -q "^demo-snapshot: timed out" "$dir/demo.log"; then
  echo "demo-snapshot: screens are missing; the end of the app's log:" >&2
  tail -40 "$dir/demo.log" >&2
  exit 1
fi
