#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
cat "$MOCK_STATE"
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=example/repo MOCK_STATE="$tmp/state"

printf 'success\n' > "$MOCK_STATE"
"$root/scripts/require-tested.sh" abc

for state in pending missing failure; do
    printf '%s\n' "$state" > "$MOCK_STATE"
    if "$root/scripts/require-tested.sh" abc > "$tmp/output" 2>&1; then
        echo "$state test check was accepted" >&2
        exit 1
    fi
    grep -q "is $state" "$tmp/output"
done
