# Internet connections

On the host Mac, turn on **Settings → Devices → Let paired devices use this Mac**,
then **Connect over the internet**. Keep Abstract open and the Mac awake.

Devices paired locally learn the host's internet address through their next
encrypted local connection. They try the local network first (three seconds on
desktop, five on mobile), then fall back to Iroh. Reconnection uses the saved
identity and resumes chat history.

To pair across networks, choose **Copy invitation** on the host. Paste it into
**Devices → Connect over the internet** on mobile, or the invitation field on
another Mac. Compare the six-digit codes and approve on the host. Invitations
expire in ten minutes and allow one attempt; create another after a failed attempt.
No VPN, port forwarding, separate app or relay credential is needed on a device.

Turning internet connections off closes internet sessions; local sharing continues.
Turning sharing off closes all hosted sessions. Unpairing removes the pinned identity
and closes that device's session. Local pairings are preserved when upgrading.

## Build and rollout

1. Run `scripts/prepare-iroh.sh apple`, or set `ANDROID_NDK_HOME` and run
   `scripts/prepare-iroh.sh android`. See [native build details](../Packages/Iroh/README.md).
2. Manually deploy the updated relay through **Deploy relay**. Complete DNS and the
   Lightsail certificate for `relay.useabstract.app`; apps use this fixed origin.
3. Install updated desktop and mobile builds. Deploying the relay does not update apps;
   merging this change does not cut a release.
4. Verify two physical networks, cellular, Wi-Fi changes, host sleep/wake, relay
   redeployment, unpairing, terminal access and command execution. Monitor Micro's
   memory and transfer usage.

Local checks include relay admission/forwarding, pairing protocol tests, mobile
fallback tests, and `scripts/test-internet.sh` using the actual Swift Iroh bindings
and encrypted Abstract messages against Docker. Same-machine testing cannot prove
behavior across every NAT/firewall or a phone's background lifecycle.

The [relay runbook](../infra/relay/README.md) explains account-free registration and
capacity limits. Registration does not authorize access to a Mac; host-approved
pairing does. Billing alerts and operational monitoring are still needed.
