#!/usr/bin/env bash
# Actual Apple Iroh bindings + encrypted Abstract protocol against the local relay.
set -euo pipefail
cd "$(dirname "$0")/.."
image=${1:-abstract-relay:internet}
container=
trap 'if test -n "$container"; then docker rm -f "$container" >/dev/null; fi' EXIT
export IROH_RELAY_ACCESS_TOKEN
IROH_RELAY_ACCESS_TOKEN=$(openssl rand -hex 32)
container=$(docker run -d -p 127.0.0.1::8080 -e IROH_RELAY_ACCESS_TOKEN "$image")
port=$(docker port "$container" 8080/tcp | cut -d: -f2)
export ABSTRACT_TEST_RELAY_URL="http://127.0.0.1:$port"
curl --fail --silent --show-error --retry 20 --retry-all-errors --retry-delay 1 \
  --max-time 3 "$ABSTRACT_TEST_RELAY_URL/ping" >/dev/null
swift test --package-path Packages/AbstractInternet --jobs 2 --filter InternetIntegrationTests
