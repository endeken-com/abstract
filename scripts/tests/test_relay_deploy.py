"""Failure-path coverage for relay deployments; Docker tests the real protocol."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

RELAY = Path(__file__).resolve().parents[2] / "infra" / "relay"
spec = importlib.util.spec_from_file_location("relay_deploy", RELAY / "deploy.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class RelayDeployTests(unittest.TestCase):
    def setUp(self):
        self.env = {"AWS_REGION": "us-east-1", "IROH_RELAY_ACCESS_TOKEN": "a" * 64}
        self.config = deploy.configuration(self.env)

    def test_configuration_requires_secret_and_region_before_aws(self):
        for key in self.env:
            with self.subTest(missing=key), self.assertRaises(ValueError):
                deploy.configuration({k: v for k, v in self.env.items() if k != key})
        for token in ["", "a" * 63, "x" * 64, "a" * 64 + "\n"]:
            with self.subTest(token_length=len(token)), self.assertRaises(ValueError):
                deploy.configuration({**self.env, "IROH_RELAY_ACCESS_TOKEN": token})

    def test_custom_domain_needs_certificate_and_plain_hostname(self):
        with self.assertRaises(ValueError):
            deploy.configuration({**self.env, "RELAY_DOMAIN": "relay.example.com"})
        for domain in ["https://relay.example.com", "relay.example.com/path", "relay.example.com\n"]:
            with self.subTest(domain=domain), self.assertRaises(ValueError):
                deploy.configuration({**self.env, "RELAY_DOMAIN": domain, "LIGHTSAIL_CERTIFICATE_NAME": "relay"})

    def test_refuses_to_resize_or_enable_an_existing_service(self):
        for service in [{"power": "micro", "scale": 2},
                        {"power": "micro", "scale": 1, "isDisabled": True}]:
            with self.subTest(service=service), self.assertRaises(RuntimeError):
                deploy.check_service(service)
        deploy.check_service({"power": "nano", "scale": 1, "isDisabled": False})

    def test_old_active_version_does_not_pass_pending_new_deployment(self):
        service = {"state": "DEPLOYING", "currentDeployment": {"version": 1, "state": "ACTIVE"},
                   "nextDeployment": {"version": 2, "state": "ACTIVATING"}}
        self.assertFalse(deploy.deployment_state(service, 2))
        service["nextDeployment"]["state"] = "FAILED"
        with self.assertRaises(RuntimeError):
            deploy.deployment_state(service, 2)
        service.pop("nextDeployment")
        service["state"] = "RUNNING"
        self.assertFalse(deploy.deployment_state(service, 2))  # An eventually consistent first read.
        with self.assertRaises(RuntimeError):
            deploy.deployment_state(service, 2, observed=True)
        service["currentDeployment"] = {"version": 2, "state": "ACTIVE"}
        self.assertTrue(deploy.deployment_state(service, 2))

    def test_image_registration_must_match_this_service_and_run(self):
        response = 'Uploading layers…\n' + json.dumps({"containerImage": {"image": ":abstract-relay.relay-42-1.7"}})
        self.assertEqual(deploy.pushed_image(response, "abstract-relay", "relay-42-1"),
                         ":abstract-relay.relay-42-1.7")
        for output in [response.replace("relay-42-1", "relay-41-1"), response.replace("abstract-relay", "other"),
                       "Upload failed", '{"containerImage":{"image":":abstract-relay.relay-42-1.latest"}}']:
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                deploy.pushed_image(output, "abstract-relay", "relay-42-1")

    def test_certificate_must_be_issued_and_cover_exactly_one_wildcard_label(self):
        config = {**self.config, "domain": "relay.example.com", "certificate": "relay-cert"}
        aws = Mock()
        def certificate(status, name):
            aws.json.return_value = {"certificates": [{"certificateDetail": {"status": status, "domainName": name}}]}
        certificate("PENDING_VALIDATION", "relay.example.com")
        with self.assertRaises(RuntimeError):
            deploy.verify_certificate(aws, config)
        certificate("ISSUED", "other.example.com")
        with self.assertRaises(RuntimeError):
            deploy.verify_certificate(aws, config)
        certificate("ISSUED", "*.example.com")
        deploy.verify_certificate(aws, config)
        with self.assertRaises(RuntimeError):
            deploy.verify_certificate(aws, {**config, "domain": "nested.relay.example.com"})

    def test_secret_payload_is_private_and_removed_even_on_aws_failure(self):
        aws = deploy.Lightsail(self.config)
        paths = []
        def failed_call(action, option, url):
            path = Path(url.removeprefix("file://"))
            paths.append(path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text())["containers"]["relay"]["environment"]["IROH_RELAY_ACCESS_TOKEN"],
                             self.config["token"])
            raise RuntimeError("AWS unavailable")
        with patch.object(aws, "json", side_effect=failed_call), self.assertRaises(RuntimeError):
            aws.request("create-container-service-deployment", deploy.deployment_request(self.config, ":test.relay.1"))
        self.assertFalse(paths[0].exists())

    def test_aws_failure_redacts_access_token(self):
        result = subprocess.CompletedProcess([], 1, "", f"Invalid input: {self.config['token']}")
        with patch.object(deploy.subprocess, "run", return_value=result), self.assertRaises(RuntimeError) as error:
            deploy.Lightsail(self.config).command("create-container-service-deployment")
        self.assertNotIn(self.config["token"], str(error.exception))

    def test_failed_smoke_never_publishes_success(self):
        service = {"power": "micro", "scale": 1, "state": "RUNNING", "url": "https://relay.example.com"}
        aws = Mock()
        aws.services.return_value = [{**service, "containerServiceName": self.config["service"]}]
        aws.wait.return_value = service
        aws.command.return_value = json.dumps({"containerImage": {"image": ":abstract-relay.relay-42-1.1"}})
        aws.request.return_value = {"containerService": {"nextDeployment": {"version": 2}}}
        with tempfile.TemporaryDirectory() as directory:
            summary, output = Path(directory) / "summary", Path(directory) / "output"
            with patch.object(deploy, "Lightsail", return_value=aws), \
                 patch.object(deploy.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "smoke")), \
                 patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary), "GITHUB_OUTPUT": str(output)}), \
                 self.assertRaises(subprocess.CalledProcessError):
                deploy.deploy(self.config, "abstract-relay:ci", "relay-42-1")
            self.assertFalse(summary.exists())
            self.assertFalse(output.exists())

    def test_existing_service_with_another_name_does_not_trigger_creation(self):
        aws = Mock()
        aws.services.return_value = [{"containerServiceName": "my-relay"}]
        with patch.object(deploy, "Lightsail", return_value=aws), self.assertRaisesRegex(
                RuntimeError, "Set LIGHTSAIL_SERVICE_NAME to the service you created"):
            deploy.deploy(self.config, "abstract-relay:ci", "relay-42-1")
        aws.json.assert_not_called()
        aws.request.assert_not_called()

    def test_creates_service_only_when_region_has_none(self):
        aws = Mock()
        aws.services.return_value = []
        aws.wait.side_effect = RuntimeError("stop after creation")
        with patch.object(deploy, "Lightsail", return_value=aws), self.assertRaisesRegex(
                RuntimeError, "stop after creation"):
            deploy.deploy(self.config, "abstract-relay:ci", "relay-42-1")
        aws.json.assert_called_once_with("create-container-service", "--service-name", "abstract-relay",
                                         "--power", "micro", "--scale", "1")

    def test_aws_read_failure_does_not_trigger_service_creation(self):
        aws = Mock()
        aws.services.side_effect = RuntimeError("Access denied")
        with patch.object(deploy, "Lightsail", return_value=aws), self.assertRaises(RuntimeError):
            deploy.deploy(self.config, "abstract-relay:ci", "relay-42-1")
        aws.json.assert_not_called()
        aws.request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
