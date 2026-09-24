#!/bin/sh
# Tests scripts/notarize.sh with a stand-in xcrun: sh scripts/tests/notarize-test.sh
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
mkdir -p "$work/bin"
touch "$work/Abstract.dmg" "$work/key.p8"
# notarytool rejects the upload and exits non-zero, as it does for an Invalid submission.
cat > "$work/bin/xcrun" <<'FAKE'
#!/bin/sh
echo "$*" >> "$CALLS"
case "$1 $2" in
    "notarytool submit") echo '{"id":"abc-123","status":"Invalid","message":"Processing complete"}'; exit 1 ;;
    "notarytool log") echo "The binary is not signed with a valid Developer ID certificate." ;;
esac
FAKE
chmod +x "$work/bin/xcrun"

export CALLS="$work/calls" NOTARY_KEY="$work/key.p8" NOTARY_KEY_ID=KEY NOTARY_ISSUER_ID=ISSUER
if PATH="$work/bin:$PATH" zsh "$root/scripts/notarize.sh" "$work/Abstract.dmg" > "$work/out" 2>&1; then
    echo "FAIL a rejected submission exited 0"; exit 1
fi
grep -q "notarytool log abc-123" "$work/calls" || { echo "FAIL the rejection's log wasn't fetched"; cat "$work/out"; exit 1; }
grep -q "not signed with a valid Developer ID" "$work/out" || { echo "FAIL the log wasn't printed"; exit 1; }
if grep -q "stapler" "$work/calls"; then echo "FAIL stapled a rejected submission"; exit 1; fi

# An accepted submission is stapled and validated.
cat > "$work/bin/xcrun" <<'FAKE'
#!/bin/sh
echo "$*" >> "$CALLS"
case "$1 $2" in
    "notarytool submit") echo '{"id":"def-456","status":"Accepted","message":"Processing complete"}' ;;
esac
FAKE
: > "$CALLS"
PATH="$work/bin:$PATH" zsh "$root/scripts/notarize.sh" "$work/Abstract.dmg" > "$work/out" 2>&1 || { echo "FAIL an accepted submission failed"; cat "$work/out"; exit 1; }
grep -q "stapler staple $work/Abstract.dmg" "$work/calls" || { echo "FAIL an accepted submission wasn't stapled"; exit 1; }
grep -q "stapler validate $work/Abstract.dmg" "$work/calls" || { echo "FAIL the staple wasn't validated"; exit 1; }
if grep -q "notarytool log" "$work/calls"; then echo "FAIL fetched a log for an accepted submission"; exit 1; fi
echo "all notarize tests passed"
