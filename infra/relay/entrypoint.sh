#!/bin/sh
set -eu

# Fail closed even when someone runs the image outside the deployment workflow.
: "${IROH_RELAY_ACCESS_TOKEN:?Set IROH_RELAY_ACCESS_TOKEN before starting the relay.}"
if [ "${#IROH_RELAY_ACCESS_TOKEN}" -lt 64 ]; then
    echo 'IROH_RELAY_ACCESS_TOKEN must contain at least 64 hexadecimal characters.' >&2
    exit 1
fi
case "$IROH_RELAY_ACCESS_TOKEN" in
    *[!a-fA-F0-9]*)
        echo 'IROH_RELAY_ACCESS_TOKEN must be hexadecimal.' >&2
        exit 1
        ;;
esac
exec python3 /usr/local/bin/relay-gateway.py
