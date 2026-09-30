# Internet relay on Lightsail

The **Deploy relay** GitHub workflow builds and tests an Iroh 1.3.0 container,
then deploys that exact image to **Lightsail Container Service, Micro, one node**.
Deployment is manual; pull requests only run checks. This is infrastructure for a
private beta. The desktop/mobile clients do not use Iroh yet: deploying this
container alone does not enable internet connections in Abstract.

Lightsail terminates HTTPS and forwards HTTP to the relay on port 8080. QUIC
address discovery is disabled because the managed public endpoint does not
expose UDP. Iroh's signed-challenge authentication supports TLS termination at
a proxy. We still need real cross-network app tests for NAT traversal, mobile
network changes, reconnection, and capacity before calling this production-ready.

## GitHub environment

Create **Settings → Environments → `lightsail-relay`**, following the existing
`release` environment's pattern. Restrict deployments to trusted branches.
Configure these **environment variables**:

| Variable | Value |
| --- | --- |
| `AWS_REGION` | Required; the AWS region in which to run the service. |
| `LIGHTSAIL_SERVICE_NAME` | Optional; defaults to `abstract-relay`. |
| `AWS_ROLE_ARN` | Optional; assume this IAM role using GitHub OIDC. |
| `RELAY_DOMAIN` | Set to `relay.useabstract.app` once DNS and the certificate are ready; omit `https://`. |
| `LIGHTSAIL_CERTIFICATE_NAME` | Set to `abstract-relay` after creating an issued Lightsail certificate with that name in the same region. Required when `RELAY_DOMAIN` is set. |

Configure these **environment secrets**, never plain variables:

| Secret | Value |
| --- | --- |
| `IROH_RELAY_ACCESS_TOKEN` | Required; generate with `openssl rand -hex 32`. |
| `AWS_ACCESS_KEY_ID` | Required when `AWS_ROLE_ARN` is not set. |
| `AWS_SECRET_ACCESS_KEY` | Required when `AWS_ROLE_ARN` is not set. |
| `AWS_SESSION_TOKEN` | Optional, for temporary AWS access keys. |

The workflow also accepts `AWS_ROLE_ARN` as an environment secret; a variable
takes precedence if both are set. OIDC takes precedence when a role is configured. Its trust policy must permit
this repository's `lightsail-relay` environment, with audience
`sts.amazonaws.com`. Use the repository's actual OIDC subject format; newer
repositories can include immutable organization/repository IDs. See
[AWS's credentials action](https://github.com/aws-actions/configure-aws-credentials#oidc-configuration-details).

The AWS identity needs the following Lightsail actions (scope to the intended
account/region and service where each action supports resource scoping):

```text
lightsail:GetContainerServices
lightsail:CreateContainerService
lightsail:CreateContainerServiceRegistryLogin
lightsail:RegisterContainerImage
lightsail:CreateContainerServiceDeployment
lightsail:GetCertificates             # only for a custom domain
lightsail:UpdateContainerService      # only for a custom domain
```

No ECR repository, Docker Hub account, or registry credentials are needed: the
workflow uploads to Lightsail's own image registry using `lightsailctl`.

## First deployment

1. Set the environment values and credentials above. Leave both domain variables
   empty until the domain and certificate are ready.
2. Run **Actions → Deploy relay → Run workflow** on the intended branch.
3. The workflow checks that a missing token prevents startup and that missing or
   wrong credentials cannot use the relay. It tests bidirectional forwarding
   between two authenticated clients before uploading the image.
4. It creates the service if absent, waits for the exact new deployment version
   to become active, and repeats the protocol test through the public HTTPS
   endpoint. The Actions summary includes the URL, image, and deployment version.

An existing service must already be Micro with one node and enabled; the workflow
does not resize or enable it silently. Concurrent manual deployments are queued.
An AWS failure is not treated as a missing service. Deployment request files
contain secrets, are created with mode `0600`, and are deleted after the call;
raw AWS responses are not printed or uploaded.

The protocol smoke test verifies WebSocket upgrade, endpoint authentication,
relay authorization, and byte forwarding. It is intentionally small and tied to
Iroh 1.3.0's wire protocol. It does not prove Abstract pairing, end-to-end app
encryption, long-lived connectivity, or direct-connection success.

## Configure relay.useabstract.app

The registered domain is `useabstract.app`; the relay will use
`https://relay.useabstract.app`. The AWS-generated HTTPS URL works while DNS and
the certificate are being configured:

1. Create a **Lightsail SSL/TLS certificate** named `abstract-relay` in the
   service's region for `relay.useabstract.app`. This is separate from the Apple signing
   certificate. Follow Lightsail's DNS validation instructions until it is issued.
2. In the `useabstract.app` DNS zone, add a **CNAME** named `relay` pointing to the
   hostname of the service's default URL (omit `https://`). The exact target is
   available after the first deployment. Use DNS-only mode if the DNS provider also offers an HTTP
   proxy; another proxy adds untested behavior.
3. Set `RELAY_DOMAIN=relay.useabstract.app` and
   `LIGHTSAIL_CERTIFICATE_NAME=abstract-relay` in the `lightsail-relay` GitHub
   environment, then rerun the workflow. It attaches the certificate/domain and checks both
   the AWS URL and custom HTTPS URL. Keep the certificate-validation DNS records
   for automatic renewal.

Domain registration and DNS records stay under your control. An empty domain
configuration preserves existing custom domains; remove unwanted mappings in
the Lightsail console explicitly.

## Access and operations

The shared access token is for a controlled beta and the deployment probe.
**Do not compile it into a publicly distributed desktop or mobile app.** Before
public rollout, add device enrollment and per-device relay authorization; Iroh
also supports an HTTP access-check service. Abstract's existing device pairing
must remain the authority for accessing a host, independently of relay access.

The relay runs as an unprivileged user. It exposes no metrics port and applies a
1 MiB/s ingress limit per connection with a 2 MiB burst. That is not a spending
cap: multiple clients can consume more. Set AWS billing/transfer alerts and watch
CPU, memory, connections, and transfer usage. One node has no redundancy.

Update the GitHub token secret and redeploy to rotate relay access. Clients using
the old token need the new credential. Lightsail administrators who can read
deployment configuration can read the token; restrict those permissions. Keep
`RUST_LOG=info`: upstream debug configuration logs can include secrets.

Lightsail health checks use `/ping`. A failed protocol smoke test marks the
workflow failed but **does not automatically roll back an active deployment**.
Inspect Lightsail deployment/container logs and redeploy a known-good image using
the Lightsail console if needed. Re-running an older workflow builds its checked-out
revision. Rollback may restore an older token: confirm credentials as well as code.
Retained Lightsail deployment versions can contain old tokens.

## Local verification

Requires Docker and Python 3.11+:

```sh
python3 -m venv /tmp/abstract-relay-venv
/tmp/abstract-relay-venv/bin/pip install -r infra/relay/requirements.txt
docker build -t abstract-relay:ci infra/relay
PYTHON=/tmp/abstract-relay-venv/bin/python3 bash infra/relay/test-container.sh
python3 -m unittest discover -s scripts/tests -p test_relay_deploy.py -v
```

The local check generates a temporary credential, binds only to loopback, and
removes its container on exit. CI builds Linux/AMD64 for Lightsail; the Dockerfile
also supports ARM64 for local Apple Silicon development. Iroh release downloads
and the workflow's `lightsailctl` download are checksum-verified. When upgrading,
review both the upstream release and its published asset digests; update the
smoke test if the relay protocol changes.

References:

- [Lightsail container networking](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-container-services.html)
- [Lightsail custom domains](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-enabling-container-services-custom-domains.html)
- [Iroh relay 1.3.0](https://github.com/n0-computer/iroh/tree/v1.3.0/iroh-relay)
- [Iroh relay authentication](https://github.com/n0-computer/iroh/blob/v1.3.0/iroh-relay/src/protos/handshake.rs)
