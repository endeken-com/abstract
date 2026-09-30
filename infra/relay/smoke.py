#!/usr/bin/env python3
"""Exercise the pinned Iroh 1.3.0 relay protocol through its public WebSocket.

This deliberately uses the signed-challenge handshake, which also works when
Lightsail terminates TLS. It tests relay authorization and bidirectional byte
forwarding, not Abstract pairing, QUIC/NAT traversal, or app reconnection.
Protocol: https://github.com/n0-computer/iroh/tree/v1.3.0/iroh-relay/src/protos
"""

import argparse
import asyncio
import os
import secrets
from contextlib import asynccontextmanager
from urllib.parse import urlsplit, urlunsplit

from blake3 import blake3
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from websockets.asyncio.client import connect


def websocket_url(url):
    parts = urlsplit(url)
    local = parts.hostname in {"localhost", "127.0.0.1", "::1"}
    if (parts.scheme != "https" and not (local and parts.scheme == "http")) or not parts.hostname:
        raise ValueError("Use HTTPS, or HTTP on loopback for the local container test.")
    if parts.username or parts.password or parts.query or parts.fragment or parts.path not in {"", "/"}:
        raise ValueError("Supply only the relay origin; credentials come from the environment.")
    return urlunsplit(("wss" if parts.scheme == "https" else "ws", parts.netloc, "/relay", "", ""))


@asynccontextmanager
async def client(url, token, allowed=True):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    async with connect(url, additional_headers=headers, subprotocols=["iroh-relay-v2"],
                       open_timeout=15, close_timeout=3, max_size=128 * 1024) as socket:
        if socket.subprotocol != "iroh-relay-v2":
            raise RuntimeError("The endpoint did not negotiate the Iroh relay protocol.")
        challenge = await asyncio.wait_for(socket.recv(), 10)
        if not isinstance(challenge, bytes) or len(challenge) != 17 or challenge[0] != 0:
            raise RuntimeError("Expected the Iroh signed authentication challenge.")
        key = Ed25519PrivateKey.generate()
        public = key.public_key().public_bytes_raw()
        message = blake3(challenge[1:], derive_key_context="iroh-relay handshake v1 challenge signature").digest()
        # Frame tag + 32-byte public key + postcard byte-string length + signature.
        await socket.send(b"\x01" + public + b"\x40" + key.sign(message))
        reply = await asyncio.wait_for(socket.recv(), 10)
        if not isinstance(reply, bytes) or not reply or reply[0] != (2 if allowed else 3):
            raise RuntimeError("Relay access control did not return the expected decision.")
        yield socket, public


async def receive_datagram(socket, sender, payload):
    async with asyncio.timeout(15):
        while True:
            frame = await socket.recv()
            if not isinstance(frame, bytes) or not frame:
                raise RuntimeError("Expected a binary relay frame.")
            if frame[0] == 9:  # Relay ping; keep the authenticated connection alive.
                await socket.send(b"\x0a" + frame[1:])
            elif frame == b"\x0d\x00":  # Healthy status.
                continue
            elif frame == b"\x06" + sender + b"\x00" + payload:
                return
            else:
                raise RuntimeError("Relay returned an unexpected frame or changed the payload.")


async def check(url, token):
    # A reachable web server or an open relay must not pass this check.
    for rejected_token in (None, secrets.token_hex(32)):
        async with client(url, rejected_token, allowed=False):
            pass
    async with client(url, token) as (first, first_id), client(url, token) as (second, second_id):
        payload = secrets.token_bytes(1024)
        await first.send(b"\x04" + second_id + b"\x00" + payload)
        await receive_datagram(second, first_id, payload)
        await second.send(b"\x04" + first_id + b"\x00" + payload)
        await receive_datagram(first, second_id, payload)
    print("Relay smoke test passed: unauthorized clients rejected; authenticated traffic forwarded both ways.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    args = parser.parse_args()
    token = os.environ.get("IROH_RELAY_ACCESS_TOKEN", "")
    if not token:
        parser.error("Set IROH_RELAY_ACCESS_TOKEN in the environment.")
    asyncio.run(check(websocket_url(args.url), token))
