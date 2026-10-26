#!/usr/bin/env python3
"""Bounded, account-free device admission and WebSocket proxy for the Iroh relay.

Registration proves possession of a device key; it is NOT an account entitlement.
Host pairing is the authorization boundary. No shared service secret goes to apps.
"""
import asyncio
import base64
import hmac
import json
import os
import signal
import time
from collections import OrderedDict

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

LEASE_SECONDS = 24 * 3600
MAX_DEVICES = 4096
MAX_CONNECTIONS = 64


class Admission:
    def __init__(self, clock=time.time):
        self.clock = clock
        self.devices = {}
        self.rates = OrderedDict()

    def register(self, body, address):
        now = self.clock()
        key, timestamp = body.get("key"), body.get("timestamp")
        if not isinstance(key, str) or len(key) != 64 or key.lower() != key:
            raise ValueError("Invalid device key")
        if not isinstance(timestamp, int) or abs(timestamp - now) > 120:
            raise ValueError("Device clock is incorrect")
        public = bytes.fromhex(key)
        signature = base64.b64decode(body.get("signature", ""), validate=True)
        Ed25519PublicKey.from_public_bytes(public).verify(
            signature, f"abstract-relay-register-v1\n{timestamp}".encode())
        self.devices = {key: expiry for key, expiry in self.devices.items() if expiry > now}
        if key not in self.devices:
            if len(self.devices) >= MAX_DEVICES:
                raise OverflowError("Relay device capacity reached")
            # Bound both the registry and rate-limit bookkeeping. A proxy appends
            # its observed client address, so use the last forwarded address only.
            for bucket, limit in ((address, 32), ("*", 512)):
                start, count = self.rates.get(bucket, (now, 0))
                if now - start >= 3600:
                    start, count = now, 0
                if count >= limit:
                    raise OverflowError("Registration rate exceeded")
                self.rates[bucket] = (start, count + 1)
                self.rates.move_to_end(bucket)
            while len(self.rates) > MAX_DEVICES:
                self.rates.popitem(last=False)
        self.devices[key] = now + LEASE_SECONDS

    def allows(self, key):
        return self.devices.get(key, 0) > self.clock()


async def serve():
    token = os.environ["IROH_RELAY_ACCESS_TOKEN"]
    child_env = dict(os.environ)
    # The original env var would override HTTP admission with shared-token auth.
    child_env.pop("IROH_RELAY_ACCESS_TOKEN")
    child_env["IROH_RELAY_HTTP_BEARER_TOKEN"] = token
    relay = await asyncio.create_subprocess_exec(
        "/usr/local/bin/iroh-relay", "--config-path", "/etc/iroh-relay/relay.toml", env=child_env)
    admission = Admission()
    active = 0
    session = ClientSession(timeout=ClientTimeout(total=5))

    async def register(request):
        try:
            body = await request.json()
            if not isinstance(body, dict):
                raise ValueError("Expected an object")
            address = request.headers.get("X-Forwarded-For", request.remote or "unknown").split(",")[-1].strip()
            admission.register(body, address)
        except OverflowError:
            raise web.HTTPTooManyRequests(text="Relay registration capacity reached")
        except Exception:
            raise web.HTTPForbidden(text="Invalid device proof")
        return web.json_response({"expiresIn": LEASE_SECONDS})

    async def access(request):
        supplied = request.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, "Bearer " + token):
            raise web.HTTPForbidden()
        # v1.3.0 calls this header X-Iroh-NodeId (despite its config docs).
        return web.Response(text="true" if admission.allows(request.headers.get("X-Iroh-NodeId", "")) else "false")

    async def ping(_request):
        try:
            async with session.get("http://127.0.0.1:8081/ping") as response:
                return web.Response(status=response.status, text="ok")
        except Exception:
            raise web.HTTPServiceUnavailable()

    async def proxy(request):
        nonlocal active
        if active >= MAX_CONNECTIONS:
            raise web.HTTPServiceUnavailable(text="Relay connection capacity reached")
        if "iroh-relay-v2" not in request.headers.get("Sec-WebSocket-Protocol", "").split(","):
            raise web.HTTPBadRequest()
        active += 1
        try:
            async with session.ws_connect("http://127.0.0.1:8081/relay", protocols=["iroh-relay-v2"],
                                          max_msg_size=128 * 1024, autoping=True) as upstream:
                downstream = web.WebSocketResponse(protocols=["iroh-relay-v2"], max_msg_size=128 * 1024,
                                                   heartbeat=30, receive_timeout=90)
                await downstream.prepare(request)

                async def pump(source, destination):
                    async for message in source:
                        if message.type == WSMsgType.BINARY:
                            await destination.send_bytes(message.data)
                        else:
                            break

                pumps = [asyncio.create_task(pump(downstream, upstream)), asyncio.create_task(pump(upstream, downstream))]
                try:
                    await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
                finally:
                    for task in pumps:
                        task.cancel()
                    await asyncio.gather(*pumps, return_exceptions=True)
                    await downstream.close()
                return downstream
        finally:
            active -= 1

    public = web.Application(client_max_size=4096)
    public.add_routes([web.get("/ping", ping), web.post("/v1/register", register), web.get("/relay", proxy)])
    private = web.Application(client_max_size=4096)
    private.add_routes([web.post("/access", access)])
    runners = []
    for app, host, port in ((public, "0.0.0.0", 8080), (private, "127.0.0.1", 8082)):
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        await web.TCPSite(runner, host, port).start()
        runners.append(runner)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stopped.set)
    relay_exit = asyncio.create_task(relay.wait())
    stop = asyncio.create_task(stopped.wait())
    await asyncio.wait([relay_exit, stop], return_when=asyncio.FIRST_COMPLETED)
    stop.cancel()
    if relay.returncode is None:
        relay.send_signal(signal.SIGINT)
    await asyncio.gather(*(runner.cleanup() for runner in runners))
    await session.close()
    await relay_exit
    if not stopped.is_set():
        raise RuntimeError("Iroh relay stopped unexpectedly")


if __name__ == "__main__":
    asyncio.run(serve())
