#!/usr/bin/env bash
set -euo pipefail

IMAGE=${1:-abstract-relay:ci}
PYTHON=${PYTHON:-python3}
RELAY_DIR=$(cd "$(dirname "$0")" && pwd)
CONTAINER=
trap 'if [ -n "$CONTAINER" ]; then docker rm -f "$CONTAINER" >/dev/null; fi' EXIT

# The image must not accidentally become a public relay without configuration.
if docker run --rm "$IMAGE" >/dev/null 2>&1; then
  echo 'The relay started without an access token.' >&2
  exit 1
fi
docker run --rm --entrypoint python3 -v "$RELAY_DIR:/tests:ro" "$IMAGE" /tests/test_gateway.py

export IROH_RELAY_ACCESS_TOKEN
IROH_RELAY_ACCESS_TOKEN=$("$PYTHON" -c 'import secrets; print(secrets.token_hex(32))')
CONTAINER=$(docker run -d -p 127.0.0.1::8080 -e IROH_RELAY_ACCESS_TOKEN "$IMAGE")
PORT=$(docker port "$CONTAINER" 8080/tcp | cut -d: -f2)
URL="http://127.0.0.1:$PORT"
curl --fail --silent --show-error --retry 20 --retry-all-errors --retry-delay 1 \
  --max-time 3 "$URL/ping" >/dev/null
"$PYTHON" "$RELAY_DIR/smoke.py" "$URL"
