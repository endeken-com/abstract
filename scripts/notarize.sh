#!/bin/zsh
# Notarizes and staples a signed .app or .dmg: scripts/notarize.sh <path>
# Needs NOTARY_KEY (path to the App Store Connect API key, .p8), NOTARY_KEY_ID and NOTARY_ISSUER_ID.
set -euo pipefail

TARGET=$1
: "${NOTARY_KEY:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"
AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

SUBMIT=$TARGET
if [[ $TARGET == *.app ]]; then
  # notarytool takes archives, not bundles.
  SUBMIT=$(mktemp -d)/${TARGET:t:r}.zip
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

RESULT=$(xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --output-format json)
read -r ID STATUS <<< "$(python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["id"], d["status"])' <<< "$RESULT")"
if [[ $STATUS != Accepted ]]; then
  echo "::error::Notarizing ${TARGET:t} ended $STATUS" >&2
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
