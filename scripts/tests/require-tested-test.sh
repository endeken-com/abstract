#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
head -n 1 "$MOCK_STATES"
sed '1d' "$MOCK_STATES" > "$MOCK_STATES.next"
mv "$MOCK_STATES.next" "$MOCK_STATES"
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/bin/sh
echo "$1" >> "$MOCK_SLEEPS"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"
export PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=example/repo
export MOCK_STATES="$tmp/states" MOCK_SLEEPS="$tmp/sleeps"

printf 'missing\npending\nsuccess\n' > "$MOCK_STATES"
: > "$MOCK_SLEEPS"
"$root/scripts/require-tested.sh" abc 60 > "$tmp/output"
[ "$(cat "$MOCK_SLEEPS")" = "$(printf '30\n30')" ]

printf 'failure\nsuccess\n' > "$MOCK_STATES"
: > "$MOCK_SLEEPS"
if "$root/scripts/require-tested.sh" abc 60 > "$tmp/output" 2>&1; then
    echo 'failed test check was accepted' >&2
    exit 1
fi
grep -q 'is failure' "$tmp/output"
[ ! -s "$MOCK_SLEEPS" ]

printf 'pending\npending\n' > "$MOCK_STATES"
: > "$MOCK_SLEEPS"
if "$root/scripts/require-tested.sh" abc 5 > "$tmp/output" 2>&1; then
    echo 'timed-out test check was accepted' >&2
    exit 1
fi
grep -q 'is pending' "$tmp/output"
[ "$(cat "$MOCK_SLEEPS")" = 5 ]
