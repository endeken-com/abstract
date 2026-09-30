#!/usr/bin/env python3
"""Deploy a tested image to one Lightsail container node.

AWS CLI and lightsailctl must be installed and AWS credentials configured.
AWS responses contain container secrets: capture them, never print them.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit


def configuration(env):
    service = env.get("LIGHTSAIL_SERVICE_NAME") or "abstract-relay"
    region = env.get("AWS_REGION", "")
    token = env.get("IROH_RELAY_ACCESS_TOKEN", "")
    domain = env.get("RELAY_DOMAIN", "")
    certificate = env.get("LIGHTSAIL_CERTIFICATE_NAME", "")
    if not re.fullmatch(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", service) or len(service) > 63:
        raise ValueError("LIGHTSAIL_SERVICE_NAME must be a lowercase Lightsail service name.")
    if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-\d+", region):
        raise ValueError("Set AWS_REGION in the lightsail-relay GitHub environment.")
    if not re.fullmatch(r"[a-fA-F0-9]{64,}", token):
        raise ValueError("Set IROH_RELAY_ACCESS_TOKEN to at least 64 hexadecimal characters.")
    if bool(domain) != bool(certificate):
        raise ValueError("Set both RELAY_DOMAIN and LIGHTSAIL_CERTIFICATE_NAME, or neither.")
    if domain and (len(domain) > 253 or not re.fullmatch(
            r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", domain)):
        raise ValueError("RELAY_DOMAIN must be a lowercase hostname, without a scheme or path.")
    return dict(service=service, region=region, token=token, domain=domain, certificate=certificate)


def deployment_request(config, image):
    return {
        "serviceName": config["service"],
        "containers": {"relay": {
            "image": image,
            "environment": {"IROH_RELAY_ACCESS_TOKEN": config["token"], "RUST_LOG": "info"},
            "ports": {"8080": "HTTP"},
        }},
        "publicEndpoint": {
            "containerName": "relay", "containerPort": 8080,
            "healthCheck": {"path": "/ping", "successCodes": "200", "intervalSeconds": 15,
                            "timeoutSeconds": 5, "healthyThreshold": 2, "unhealthyThreshold": 3},
        },
    }


def check_service(service):
    if service.get("scale") != 1:
        raise RuntimeError("The existing service must have one node; refusing to resize it.")
    if service.get("isDisabled"):
        raise RuntimeError("The existing service is disabled; enable it in Lightsail first.")


def deployment_state(service, version, observed=False):
    """Do not mistake an older healthy deployment for the one we just submitted."""
    for key in ("currentDeployment", "nextDeployment"):
        deployment = service.get(key) or {}
        if deployment.get("version") == version:
            if deployment.get("state") == "FAILED":
                raise RuntimeError(f"Lightsail deployment {version} failed; inspect its container logs.")
            if key == "currentDeployment" and deployment.get("state") == "ACTIVE":
                return True
    if observed and service.get("state") == "RUNNING" and not service.get("nextDeployment"):
        raise RuntimeError("Lightsail returned to an older deployment; the new deployment did not activate.")
    return False


def pushed_image(output, service, label):
    # lightsailctl can write progress text before the AWS JSON result.
    decoder = json.JSONDecoder()
    for match in re.finditer(r"\{", output):
        try:
            result, _ = decoder.raw_decode(output[match.start():])
        except ValueError:
            continue
        if isinstance(result, dict):
            image = result.get("containerImage", {}).get("image", "")
            if re.fullmatch(rf":{re.escape(service)}\.{re.escape(label)}\.\d+", image):
                return image
    raise RuntimeError("AWS did not return the exact registered image; refusing to deploy a latest tag.")


class Lightsail:
    def __init__(self, config):
        self.config = config

    def command(self, action, *args):
        result = subprocess.run(
            ["aws", "lightsail", action, "--region", self.config["region"],
             "--output", "json", "--no-cli-pager", *args],
            capture_output=True, text=True, timeout=600, check=False,
        )
        if result.returncode:
            # AWS validation errors may repeat inputs, so redact the credential.
            detail = result.stderr.replace(self.config["token"], "[redacted]")
            raise RuntimeError(f"AWS {action} failed: {detail.strip()}")
        return result.stdout

    def json(self, action, *args):
        return json.loads(self.command(action, *args))

    def request(self, action, payload):
        with tempfile.TemporaryDirectory(prefix="abstract-relay-") as directory:
            path = Path(directory) / "request.json"
            path.touch(mode=0o600)
            path.write_text(json.dumps(payload))
            return self.json(action, "--cli-input-json", f"file://{path}")

    def services(self):
        # Listing distinguishes absence from access/network errors without parsing stderr.
        return self.json("get-container-services")["containerServices"]

    def service(self):
        return next((s for s in self.services() if s["containerServiceName"] == self.config["service"]), None)

    def wait(self, ready, description):
        deadline = time.monotonic() + 1200
        print(description, flush=True)
        while time.monotonic() < deadline:
            service = self.service()
            if service:
                if service.get("state") in {"DELETING", "DISABLED"}:
                    raise RuntimeError("The Lightsail service is unavailable.")
                if ready(service):
                    return service
            time.sleep(10)
        raise RuntimeError(f"Timed out: {description}")


def verify_certificate(aws, config):
    if not config["domain"]:
        return
    entries = aws.json("get-certificates", "--certificate-name", config["certificate"],
                       "--include-certificate-details")["certificates"]
    details = [entry.get("certificateDetail", {}) for entry in entries]
    for cert in details:
        names = [cert.get("domainName", ""), *cert.get("subjectAlternativeNames", [])]
        covered = any(name == config["domain"] or (
            name.startswith("*.") and config["domain"].split(".", 1)[1] == name[2:]
        ) for name in names)
        if cert.get("status") == "ISSUED" and covered:
            return
    raise RuntimeError("The Lightsail certificate must be ISSUED and cover RELAY_DOMAIN in AWS_REGION.")


def deploy(config, image, label):
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,49}", label):
        raise ValueError("Use a short lowercase image label, such as relay-123456-1.")
    aws = Lightsail(config)
    verify_certificate(aws, config)
    services = aws.services()
    service = next((s for s in services if s["containerServiceName"] == config["service"]), None)
    if service:
        check_service(service)
    else:
        if services:
            names = ", ".join(sorted(s["containerServiceName"] for s in services))
            raise RuntimeError(
                f"No Lightsail container service named {config['service']} in {config['region']}. "
                f"Existing services: {names}. Set LIGHTSAIL_SERVICE_NAME to the service you created."
            )
        print("Creating one Lightsail Micro node.", flush=True)
        aws.json("create-container-service", "--service-name", config["service"],
                 "--power", "micro", "--scale", "1")
    service = aws.wait(lambda s: s["state"] in {"READY", "RUNNING"}, "Waiting for the service to be ready…")
    check_service(service)

    if config["domain"]:
        # Preserve any other domain mappings already attached to the service.
        domains = service.get("publicDomainNames", {})
        desired = domains.setdefault(config["certificate"], [])
        if config["domain"] not in desired:
            desired.append(config["domain"])
            aws.request("update-container-service", {"serviceName": config["service"], "publicDomainNames": domains})
            service = aws.wait(lambda s: s["state"] in {"READY", "RUNNING"}, "Waiting for the domain update…")

    print("Uploading the tested container image…", flush=True)
    uploaded = pushed_image(aws.command("push-container-image", "--service-name", config["service"],
                                       "--label", label, "--image", image), config["service"], label)
    result = aws.request("create-container-service-deployment", deployment_request(config, uploaded))
    submitted = result["containerService"].get("nextDeployment")
    if not submitted or "version" not in submitted:
        raise RuntimeError("AWS did not return a deployment version; inspect the service before retrying.")
    version = submitted["version"]
    observed = False

    def active(service):
        nonlocal observed
        ready = deployment_state(service, version, observed)
        observed |= any((service.get(key) or {}).get("version") == version
                        for key in ("currentDeployment", "nextDeployment"))
        return ready

    # The first read may still show the old service state after the write.
    service = aws.wait(active, f"Waiting for deployment {version} to activate…")
    urls = [service["url"].rstrip("/")]
    if config["domain"]:
        urls.append(f'https://{config["domain"]}')
        print(f'DNS: CNAME {config["domain"]} → {urlsplit(urls[0]).hostname}', flush=True)
    # Check AWS's frontend too, even when a custom domain is configured.
    for url in urls:
        subprocess.run([sys.executable, str(Path(__file__).with_name("smoke.py")), url], check=True, timeout=120)
    print(f"Deployed and verified: {urls[-1]}", flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as file:
            file.write(f"Relay deployed to **{config['service']}** ({service['power'].title()}, one node).\n\n"
                       f"- Endpoint: {urls[-1]}\n- Lightsail endpoint: {urls[0]}\n"
                       f"- Image: `{uploaded}`\n- Deployment: {version}\n"
                       "- Verified authorization and bidirectional relay forwarding over HTTPS.\n"
                       "- App integration and cross-network device tests remain separate.\n")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as file:
            file.write(f"url={urls[-1]}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--image", default="abstract-relay:ci")
    parser.add_argument("--label", default="relay")
    args = parser.parse_args()
    try:
        config = configuration(os.environ)
        if args.validate_only:
            print("Relay environment configuration is valid.")
        else:
            deploy(config, args.image, args.label)
    except (ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Relay deployment failed: {error}", file=sys.stderr)
        sys.exit(1)
